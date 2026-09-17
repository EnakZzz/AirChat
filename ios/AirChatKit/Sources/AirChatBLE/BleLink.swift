import AirChatProtocol
import Foundation

// CBPeripheralManager is iOS-only, so this whole transport is compiled for iOS and replaced by a
// stub elsewhere. That is what lets `swift test` build the package on macOS.
#if os(iOS)
import CoreBluetooth

/// One BLE GATT connection, exposed to the protocol layer as a `Link`.
///
/// Apple platform constraints this class encodes:
/// - **Nothing may be written before the link is usable.** The node calls `send` as soon as a link
///   is announced; CoreBluetooth will silently drop `updateValue` until the central subscribes, so
///   outbound frames queue until `readyForTraffic` flips.
/// - **Notification flow control is cooperative.** `updateValue` returns false when the peripheral
///   manager is not ready; `peripheralManagerIsReady(toUpdateSubscribers:)` resumes the queue.
/// - **Early inbound bytes must survive.** A peer can write to CH_RX before our handler is
///   registered; those bytes are buffered in `pendingInbound`.
///
/// Every method runs on the transport's serial queue, which is what lets `LinkSession` stay
/// free of locking.
internal final class BleLink: Link {

    let linkId: String
    let isCentral: Bool
    let peerLabel: String?

    private(set) var mtu: Int = AirChatProtocol.defaultMtu
    private let logger: AirChatLogger
    private let onTerminated: (BleLink, String) -> Void

    private var inbound: ((Data) -> Void)?
    private var pendingInbound: [Data] = []

    private struct Chunk {
        let control: Bool
        let bytes: Data
    }

    private var outbound: [Chunk] = []
    private var inFlight = false

    private(set) var closed = false
    private(set) var readyForTraffic = false

    // Central role
    private(set) var central: CBCentral?
    private(set) var peripheral: CBPeripheral?
    private var ctrlCharacteristic: CBCharacteristic?
    private var txCharacteristic: CBCharacteristic?
    private var rxCharacteristic: CBCharacteristic?

    // Peripheral role
    private(set) var server: CBPeripheralManager?
    private(set) var serverCharacteristicCtrl: CBMutableCharacteristic?
    private(set) var serverCharacteristicTx: CBMutableCharacteristic?

    private var ctrlSubscribed = false
    private var txSubscribed = false

    private static let maxQueuedChunks = 512

    init(
        linkId: String,
        isCentral: Bool,
        peerLabel: String?,
        logger: AirChatLogger,
        onTerminated: @escaping (BleLink, String) -> Void
    ) {
        self.linkId = linkId
        self.isCentral = isCentral
        self.peerLabel = peerLabel
        self.logger = logger
        self.onTerminated = onTerminated
    }

    // ------------------------------------------------------------------ Link

    func setInboundHandler(_ handler: @escaping (Data) -> Void) {
        inbound = handler
        if !pendingInbound.isEmpty {
            let flush = pendingInbound
            pendingInbound.removeAll()
            for bytes in flush { handler(bytes) }
        }
    }

    func send(_ bytes: Data, control: Bool) -> Bool {
        guard !closed else { return false }
        guard outbound.count < Self.maxQueuedChunks else {
            logger.log("BleLink", "outbound queue full on \(linkId); refusing chunk")
            return false
        }
        outbound.append(Chunk(control: control, bytes: bytes))
        drainOutbound()
        return true
    }

    func close() {
        guard !closed else { return }
        closed = true
        // Actual GATT teardown belongs to the transport: cancelling a central-side link needs the
        // CBCentralManager and a peripheral-side link needs the CBPeripheralManager.
        onTerminated(self, "closed locally")
    }

    // ---------------------------------------------------- peripheral wiring

    func bindPeripheral(
        server: CBPeripheralManager,
        central: CBCentral,
        ctrl: CBMutableCharacteristic,
        tx: CBMutableCharacteristic,
        mtu: Int
    ) {
        self.server = server
        self.central = central
        self.serverCharacteristicCtrl = ctrl
        self.serverCharacteristicTx = tx
        if mtu > 0 { self.mtu = mtu }
        evaluatePeripheralReadiness()
    }

    /// Replaces the remote central behind this link.
    ///
    /// CoreBluetooth hands out a **new** `CBCentral` object every time a peer reconnects, even
    /// though its identifier is unchanged. Because links are keyed by identifier, a reconnect reuses
    /// this link - so without refreshing `central`, `updateValue(_:for:onSubscribedCentrals:)` keeps
    /// addressing the previous, now-disconnected object. The notification is then dropped with no
    /// error and no deferred callback, which is exactly how the peer ended up receiving nothing:
    /// verified by `inbound notification` never appearing in the Android log while iOS reported no
    /// send failure at all.
    func updateCentral(_ newCentral: CBCentral) {
        guard !closed else { return }
        central = newCentral
    }

    // -------------------------------------------------------- central wiring

    func bindCentral(peripheral: CBPeripheral, characteristics: [CBCharacteristic]) {
        self.peripheral = peripheral
        for characteristic in characteristics {
            if characteristic.uuid == BleUuids.ctrl {
                ctrlCharacteristic = characteristic
            } else if characteristic.uuid == BleUuids.tx {
                txCharacteristic = characteristic
            } else if characteristic.uuid == BleUuids.rx {
                rxCharacteristic = characteristic
            }
        }
    }

    /// Called once service discovery and channel subscription are complete.
    func markCentralReady() {
        guard isCentral, !readyForTraffic, !closed else { return }
        refreshCentralMtu()
        readyForTraffic = true
        logger.log("BleLink", "central \(linkId) ready (mtu=\(mtu))")
        drainOutbound()
    }

    /// iOS chooses the ATT MTU; `maximumWriteValueLength` is the authoritative usable payload.
    func refreshCentralMtu() {
        guard let peripheral else { return }
        let writeLength = peripheral.maximumWriteValueLength(for: .withResponse)
        if writeLength > 0 {
            // `maximumWriteValueLength` is MTU - 3.
            mtu = writeLength + 3
        }
    }

    func onSubscriptionChanged(characteristic: CBCharacteristic, enabled: Bool) {
        if characteristic.uuid == BleUuids.ctrl {
            ctrlSubscribed = enabled
        } else if characteristic.uuid == BleUuids.tx {
            txSubscribed = enabled
        } else {
            return
        }
        evaluatePeripheralReadiness()
    }

    private func evaluatePeripheralReadiness() {
        guard !isCentral, !closed else { return }
        guard ctrlSubscribed && txSubscribed else {
            // A reconnect unsubscribes and re-subscribes, so readiness must be re-armable rather
            // than latching on for the lifetime of the link.
            readyForTraffic = false
            return
        }
        guard !readyForTraffic else { return }
        readyForTraffic = true
        logger.log("BleLink", "peripheral \(linkId) ready (central subscribed to CTRL and TX)")
        drainOutbound()
    }

    /// A remote central subscribed or unsubscribed at the CoreBluetooth level.
    func notePeripheralSubscription(characteristic: CBCharacteristic, enabled: Bool) {
        if characteristic.uuid == BleUuids.ctrl {
            ctrlSubscribed = enabled
        } else if characteristic.uuid == BleUuids.tx {
            txSubscribed = enabled
        } else {
            return
        }
        evaluatePeripheralReadiness()
    }

    // -------------------------------------------------------------- inbound

    func onInbound(_ value: Data?) {
        guard !closed, let value, !value.isEmpty else { return }
        if let inbound {
            inbound(value)
        } else {
            pendingInbound.append(value)
        }
    }

    // ------------------------------------------------------------- outbound

    private func drainOutbound() {
        guard !closed, !inFlight, !outbound.isEmpty, readyForTraffic else { return }
        let chunk = outbound[0]
        let written = isCentral ? writeAsCentral(chunk) : notifyAsPeripheral(chunk)
        if written {
            outbound.removeFirst()
            inFlight = true
        } else {
            // Leave it at the head and retry from the next callback instead of corrupting the
            // frame stream by skipping a chunk.
            logger.log("BleLink", "write to \(linkId) deferred")
        }
    }

    private func writeAsCentral(_ chunk: Chunk) -> Bool {
        guard let peripheral else { return false }
        guard let characteristic = chunk.control ? ctrlCharacteristic : rxCharacteristic else { return false }
        // write-with-response gives ATT-level flow control; see docs/protocol.md section 6.3.
        peripheral.writeValue(chunk.bytes, for: characteristic, type: .withResponse)
        return true
    }

    private func notifyAsPeripheral(_ chunk: Chunk) -> Bool {
        guard let server, central != nil else { return false }
        guard let characteristic = chunk.control ? serverCharacteristicCtrl : serverCharacteristicTx else {
            return false
        }
        // `onSubscribedCentrals: nil` sends to every subscribed central. This link has exactly one
        // peer, so naming a specific CBCentral adds no information but does add a failure mode:
        // CoreBluetooth hands over a new CBCentral object on every reconnect, and addressing a
        // stale one drops the notification with no error and no deferred callback.
        // updateValue returns false when the peripheral manager cannot accept more data right now.
        return server.updateValue(chunk.bytes, for: characteristic, onSubscribedCentrals: nil)
    }

    /// Central role: our write completed.
    func onCharacteristicWritten(error: Error?) {
        inFlight = false
        if let error {
            logger.log("BleLink", "write to \(linkId) failed: \(error)")
        }
        drainOutbound()
    }

    /// Peripheral role: the transmit queue has room again.
    func onPeripheralManagerReady() {
        drainOutbound()
    }

    // ------------------------------------------------------------ teardown

    func onDisconnected(status: String) {
        guard !closed else { return }
        closed = true
        onTerminated(self, status)
    }
}

#endif // os(iOS)
