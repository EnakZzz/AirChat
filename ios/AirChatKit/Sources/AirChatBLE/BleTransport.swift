import AirChatProtocol
import CoreBluetooth
import Foundation

/// iOS BLE transport: advertises, scans, hosts a GATT server and opens GATT client connections,
/// implementing the discovery and connect-direction rules of `docs/protocol.md` sections 4 and 5.
///
/// Concurrency model: every CoreBluetooth delegate callback arrives on the main queue, so the
/// transport re-dispatches onto its own serial queue. `BleLink` and the protocol's `LinkSession`
/// are therefore only ever touched from one thread.
///
/// iOS-specific behaviour that shapes this class:
/// - **Both roles run at once.** Every device advertises *and* scans, which is what makes the
///   cross-platform handshake symmetric.
/// - **MTU is chosen by the system.** There is no request API; the usable payload comes from
///   `CBPeripheral.maximumWriteValueLength` (central) and `CBCentral.maximumUpdateValueLength`
///   (peripheral).
/// - **Background advertising is degraded.** iOS drops the local name and moves the 128-bit
///   service UUID into the overflow area, so only foreground scanners reliably see it. This is
///   why the presence block carries no meaningful payload and why everything authoritative is
///   exchanged in HELLO (protocol section 11.3).
/// - **CCCD writes never reach the delegate.** Subscription is observed through
///   `peripheralManager(_:central:didSubscribeTo:)` / `didUnsubscribeFrom:`.
///
/// Requires `NSBluetoothAlwaysUsageDescription` and the `bluetooth-central` +
/// `bluetooth-peripheral` background modes.
public final class BleTransport: NSObject, Transport {

    private let queue = DispatchQueue(label: "app.airchat.ble")
    private let logger: AirChatLogger
    private let clock: () -> Int64

    private var centralManager: CBCentralManager?
    private var peripheralManager: CBPeripheralManager?
    private var eventHandler: ((TransportEvent) -> Void)?

    public let ticket: Int = AirChatCrypto.randomTicket()

    private var advertisedProtocolVersion = AirChatProtocol.version
    private var advertisedCapabilities = Capabilities.all

    private var running = false
    private var scanning = false
    private var advertising = false
    /// True when the platform rejected the presence block and we fell back to UUID-only adverts.
    private var presenceUnavailable = false

    private var links: [String: BleLink] = [:]
    /// Live links keyed by role-scoped peer handle, so delegate callbacks can find them.
    private var linksByKey: [String: BleLink] = [:]
    private var connecting: Set<String> = []
    private var pendingPeripheral: [String: CBPeripheral] = [:]

    private struct SeenPeer {
        let ticket: Int
        let firstSeenMs: Int64
        var lastSeenMs: Int64
        var rssi: Int?
    }

    private var seen: [String: SeenPeer] = [:]
    private var backoffUntil: [String: Int64] = [:]

    // Server-side characteristics are created once and reused across centrals.
    private var service: CBMutableService?
    private var ctrlCharacteristic: CBMutableCharacteristic?
    private var txCharacteristic: CBMutableCharacteristic?
    private var rxCharacteristic: CBMutableCharacteristic?

    /// Central-side state restoration identifier so iOS can resume scanning after relaunch.
    private static let restoreIdentifier = "app.airchat.central"

    public init(
        logger: AirChatLogger = NoopLogger(),
        clock: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }
    ) {
        self.logger = logger
        self.clock = clock
        super.init()
    }

    public func setEventHandler(_ handler: @escaping (TransportEvent) -> Void) {
        queue.sync { eventHandler = handler }
    }

    // ------------------------------------------------------------- lifecycle

    public func start() {
        queue.sync {
            guard !running else { return }
            running = true
            // Creating the managers triggers the first state callback; advertising and scanning
            // only begin once the managers report .poweredOn.
            if centralManager == nil {
                centralManager = CBCentralManager(
                    delegate: self,
                    queue: .main,
                    options: [
                        CBCentralManagerOptionRestoreIdentifierKey: Self.restoreIdentifier,
                        CBCentralManagerOptionShowPowerAlertKey: false,
                    ]
                )
            }
            if peripheralManager == nil {
                peripheralManager = CBPeripheralManager(
                    delegate: self,
                    queue: .main,
                    options: [CBPeripheralManagerOptionShowPowerAlertKey: false]
                )
            }
        }
    }

    public func stop() {
        queue.sync {
            guard running else { return }
            running = false
            stopScanning()
            stopAdvertising()
            for link in links.values { link.close() }
            links.removeAll()
            linksByKey.removeAll()
            connecting.removeAll()
            pendingPeripheral.removeAll()
            if let peripheralManager, peripheralManager.isAdvertising {
                peripheralManager.stopAdvertising()
            }
            if let centralManager, centralManager.isScanning {
                centralManager.stopScan()
            }
            emit(.status(.stopped, "已停止"))
        }
    }

    public func updatePresence(protocolVersion: Int, capabilities: Int) {
        queue.sync {
            advertisedProtocolVersion = protocolVersion
            advertisedCapabilities = capabilities
            if advertising {
                stopAdvertising()
                startAdvertising()
            }
        }
    }

    // ----------------------------------------------------------- advertising

    private func buildService() -> CBMutableService {
        let service = CBMutableService(type: BleUuids.service, primary: true)

        let ctrl = CBMutableCharacteristic(
            type: BleUuids.ctrl,
            properties: [.notify, .write],
            value: nil,
            permissions: [.writeable]
        )
        let tx = CBMutableCharacteristic(
            type: BleUuids.tx,
            properties: [.notify],
            value: nil,
            permissions: []
        )
        let rx = CBMutableCharacteristic(
            type: BleUuids.rx,
            properties: [.write, .writeWithoutResponse],
            value: nil,
            permissions: [.writeable]
        )
        service.characteristics = [ctrl, tx, rx]

        ctrlCharacteristic = ctrl
        txCharacteristic = tx
        rxCharacteristic = rx
        self.service = service
        return service
    }

    private func startAdvertising() {
        guard running, let peripheralManager, peripheralManager.state == .poweredOn else { return }

        var data: [String: Any] = [CBAdvertisementDataServiceUUIDsKey: [BleUuids.service]]
        if !presenceUnavailable {
            data[CBAdvertisementDataServiceDataKey] = [
                BleUuids.presence: BleUuids.encodePresence(
                    protocolVersion: advertisedProtocolVersion,
                    capabilities: advertisedCapabilities,
                    ticket: ticket
                ),
            ]
        }
        peripheralManager.startAdvertising(data)
    }

    private func stopAdvertising() {
        guard let peripheralManager, peripheralManager.isAdvertising else {
            advertising = false
            return
        }
        peripheralManager.stopAdvertising()
        advertising = false
    }

    /// Presence block never reaches a meaningful size limit under normal conditions, but the
    /// platform can still reject it; falling back to the bare service UUID keeps discovery
    /// working because the peer then connects on the retry path.
    private func handleAdvertisingFailure(_ error: Error) {
        advertising = false
        guard !presenceUnavailable else {
            emit(.status(.bluetoothUnavailable, "蓝牙广播失败：\(error.localizedDescription)"))
            return
        }
        logger.log("BleTransport", "advertising with presence block failed (\(error)); retrying without it")
        presenceUnavailable = true
        startAdvertising()
    }

    // -------------------------------------------------------------- scanning

    private func startScanning() {
        guard running, !scanning else { return }
        guard let centralManager, centralManager.state == .poweredOn else { return }
        guard links.count < AirChatProtocol.maxLinks else {
            emit(.status(.nearbyFull, "附近人数已满（上限 \(AirChatProtocol.maxLinks)）"))
            return
        }
        // Duplicates are allowed so RSSI stays fresh and the connect-retry timer can fire.
        centralManager.scanForPeripherals(
            withServices: [BleUuids.service],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
        )
        scanning = true
        if links.isEmpty {
            emit(.status(.scanning, "正在寻找附近的人…"))
        }
    }

    private func stopScanning() {
        guard let centralManager, centralManager.isScanning else {
            scanning = false
            return
        }
        centralManager.stopScan()
        scanning = false
    }

    private func handleDiscovery(_ peripheral: CBPeripheral, advertisementData: [String: Any], rssi: Int) {
        guard running else { return }
        let key = peripheral.identifier.uuidString

        let rawPresence = (advertisementData[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data])?[BleUuids.presence]
        let presence = BleUuids.decodePresence(rawPresence)
        // Without a presence block the ticket is unknown; derive a stable pseudo-ticket from the
        // peer handle so the direction decision stays deterministic between the two devices.
        let peerTicket = presence?.ticket ?? (abs(key.hashValue) % 65536)

        let now = clock()
        if var entry = seen[key] {
            entry.lastSeenMs = now
            entry.rssi = rssi
            seen[key] = entry
        } else {
            seen[key] = SeenPeer(ticket: peerTicket, firstSeenMs: now, lastSeenMs: now, rssi: rssi)
        }

        emit(.peerSeen(
            peerLabel: key,
            protocolVersion: presence?.protocolVersion ?? 0,
            capabilities: presence?.capabilities ?? 0,
            ticket: peerTicket,
            rssi: rssi
        ))

        considerConnecting(peripheral, identifier: key, peerTicket: peerTicket, now: now)
    }

    /// Protocol 5.3: connect only when our ticket is smaller, unless the peer has been visible for
    /// longer than the fallback window without connecting to us (e.g. it is already at its cap).
    private func considerConnecting(
        _ peripheral: CBPeripheral,
        identifier: String,
        peerTicket: Int,
        now: Int64
    ) {
        guard running else { return }
        guard linksByKey[centralKey(identifier)] == nil else { return }
        guard linksByKey[peripheralKey(identifier)] == nil else { return }
        guard !connecting.contains(identifier) else { return }
        guard links.count + connecting.count < AirChatProtocol.maxLinks else { return }
        if let until = backoffUntil[identifier], now < until { return }

        let firstSeen = seen[identifier]?.firstSeenMs ?? now
        let weAreSmaller = ticket < peerTicket
        let peerNeverCame = now - firstSeen >= AirChatProtocol.scanRetryAfterMs
        guard weAreSmaller || peerNeverCame else { return }

        guard let centralManager, centralManager.state == .poweredOn else { return }

        connecting.insert(identifier)
        pendingPeripheral[identifier] = peripheral
        logger.log("BleTransport", "connecting to \(identifier) (our ticket=\(ticket), theirs=\(peerTicket))")
        centralManager.connect(peripheral, options: nil)
    }

    // ---------------------------------------------------------------- helpers

    private func centralKey(_ identifier: String) -> String { "central:\(identifier)" }
    private func peripheralKey(_ identifier: String) -> String { "peripheral:\(identifier)" }

    private func emit(_ event: TransportEvent) {
        eventHandler?(event)
    }
}

// ---------------------------------------------------------------- central role

extension BleTransport: CBCentralManagerDelegate {

    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        queue.async { [weak self] in
            guard let self else { return }
            switch central.state {
            case .poweredOn:
                // Advertising is owned by the peripheral manager's state callback, which runs
                // independently; the central side only needs to start scanning.
                self.startScanning()
            case .poweredOff:
                self.emit(.status(.bluetoothUnavailable, "请打开蓝牙"))
                self.emitSubscriptionsStopped(central)
            case .unauthorized:
                self.emit(.status(.permissionMissing, "AirChat 需要蓝牙权限才能发现附近的人"))
            case .unsupported:
                self.emit(.status(.bluetoothUnavailable, "此设备不支持蓝牙 LE"))
            default:
                break
            }
        }
    }

    public func centralManager(
        _ central: CBCentralManager,
        willRestoreState dict: [String: Any]
    ) {
        queue.async { [weak self] in
            guard let self else { return }
            let restored = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] ?? []
            for peripheral in restored {
                let key = self.centralKey(peripheral.identifier.uuidString)
                self.pendingPeripheral[peripheral.identifier.uuidString] = peripheral
                self.connecting.insert(peripheral.identifier.uuidString)
                self.logger.log("BleTransport", "restoring connection to \(key)")
            }
        }
    }

    public func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let rssiValue = RSSI.intValue
        queue.async { [weak self] in
            self?.handleDiscovery(peripheral, advertisementData: advertisementData, rssi: rssiValue)
        }
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        queue.async { [weak self] in
            guard let self else { return }
            let identifier = peripheral.identifier.uuidString
            self.connecting.remove(identifier)
            self.pendingPeripheral.removeValue(forKey: identifier)

            guard self.links.count < AirChatProtocol.maxLinks else {
                central.cancelPeripheralConnection(peripheral)
                self.emit(.status(.nearbyFull, "附近人数已满（上限 \(AirChatProtocol.maxLinks)）"))
                return
            }
            guard self.linksByKey[self.centralKey(identifier)] == nil else {
                central.cancelPeripheralConnection(peripheral)
                return
            }

            let link = BleLink(
                linkId: self.centralKey(identifier),
                isCentral: true,
                peerLabel: identifier,
                logger: self.logger,
                onTerminated: { [weak self] closedLink, reason in
                    self?.handleLinkClosed(closedLink, reason: reason, central: central)
                }
            )
            self.links[link.linkId] = link
            self.linksByKey[link.linkId] = link
            peripheral.delegate = self
            self.logger.log("BleTransport", "central link up with \(identifier)")
            self.emit(.linkOpened(link))
            self.updateScanningForCapacity()
            peripheral.discoverServices([BleUuids.service])
        }
    }

    public func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        queue.async { [weak self] in
            guard let self else { return }
            let identifier = peripheral.identifier.uuidString
            self.connecting.remove(identifier)
            self.pendingPeripheral.removeValue(forKey: identifier)
            self.backoffUntil[identifier] = self.clock() + AirChatProtocol.reconnectBackoffMs
            self.logger.log("BleTransport", "connect to \(identifier) failed: \(error.map(String.init(describing:)) ?? "unknown")")
            self.startScanning()
        }
    }

    public func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        queue.async { [weak self] in
            guard let self else { return }
            let identifier = peripheral.identifier.uuidString
            self.connecting.remove(identifier)
            self.pendingPeripheral.removeValue(forKey: identifier)
            self.backoffUntil[identifier] = self.clock() + AirChatProtocol.reconnectBackoffMs
            if let link = self.linksByKey[self.centralKey(identifier)] {
                link.onDisconnected(status: "disconnected")
            }
        }
    }

    private func emitSubscriptionsStopped(_ central: CBCentralManager) {
        for link in links.values { link.onDisconnected(status: "adapter off") }
    }

    private func handleLinkClosed(_ link: BleLink, reason: String, central: CBCentralManager? = nil) {
        guard links.removeValue(forKey: link.linkId) != nil else { return }
        linksByKey.removeValue(forKey: link.linkId)
        if link.isCentral, let peripheral = link.peripheral, let central {
            central.cancelPeripheralConnection(peripheral)
        }
        logger.log("BleTransport", "link \(link.linkId) gone: \(reason)")
        emit(.linkClosed(linkId: link.linkId, reason: reason))
        updateScanningForCapacity()
    }

    /// Protocol 5.5: stop scanning at the link cap, resume as soon as capacity frees up.
    private func updateScanningForCapacity() {
        guard running else { return }
        if links.count >= AirChatProtocol.maxLinks {
            stopScanning()
            emit(.status(.nearbyFull, "附近人数已满（上限 \(AirChatProtocol.maxLinks)）"))
        } else {
            startScanning()
        }
    }
}

// ------------------------------------------------------------- peripheral role

extension BleTransport: CBPeripheralManagerDelegate {

    public func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        queue.async { [weak self] in
            guard let self else { return }
            switch peripheral.state {
            case .poweredOn:
                if self.service == nil {
                    let service = self.buildService()
                    peripheral.add(service)
                } else {
                    self.startAdvertising()
                }
            case .unauthorized:
                self.emit(.status(.permissionMissing, "AirChat 需要蓝牙权限才能被附近的人发现"))
            case .unsupported:
                self.emit(.status(.bluetoothUnavailable, "此设备不支持蓝牙外设模式"))
            default:
                break
            }
        }
    }

    public func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        queue.async { [weak self] in
            guard let self else { return }
            if let error {
                self.emit(.status(.failed, "无法注册蓝牙服务：\(error.localizedDescription)"))
                return
            }
            self.startAdvertising()
        }
    }

    public func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        queue.async { [weak self] in
            guard let self else { return }
            if let error {
                self.handleAdvertisingFailure(error)
                return
            }
            self.advertising = true
            self.logger.log("BleTransport", "advertising as ticket=\(self.ticket)")
        }
    }

    public func peripheralManager(
        _ peripheral: CBPeripheralManager,
        central: CBCentral,
        didSubscribeTo characteristic: CBCharacteristic
    ) {
        queue.async { [weak self] in
            guard let self else { return }
            let identifier = central.identifier.uuidString
            self.ensurePeripheralLink(central: central)
            self.linksByKey[self.peripheralKey(identifier)]?.notePeripheralSubscription(
                characteristic: characteristic,
                enabled: true
            )
        }
    }

    public func peripheralManager(
        _ peripheral: CBPeripheralManager,
        central: CBCentral,
        didUnsubscribeFrom characteristic: CBCharacteristic
    ) {
        queue.async { [weak self] in
            guard let self else { return }
            let identifier = central.identifier.uuidString
            self.linksByKey[self.peripheralKey(identifier)]?.notePeripheralSubscription(
                characteristic: characteristic,
                enabled: false
            )
        }
    }

    public func peripheralManager(
        _ peripheral: CBPeripheralManager,
        didReceiveWrite requests: [CBATTRequest]
    ) {
        queue.async { [weak self] in
            guard let self else { return }
            var needsResponse = false
            for request in requests {
                let identifier = request.central.identifier.uuidString
                self.ensurePeripheralLink(central: request.central)
                if request.characteristic.uuid == BleUuids.rx {
                    self.linksByKey[self.peripheralKey(identifier)]?.onInbound(request.value)
                }
                // write-with-response requires an explicit reply; write-without-response must not
                // be answered (protocol section 6.3).
                if request.characteristic.properties.contains(.write) {
                    needsResponse = true
                }
            }
            if needsResponse, let first = requests.first {
                peripheral.respond(to: first, withResult: .success)
            }
        }
    }

    public func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
        queue.async { [weak self] in
            guard let self else { return }
            for link in self.links.values where !link.isCentral {
                link.onPeripheralManagerReady()
            }
        }
    }

    /// Creates the peripheral-side link on first contact with a central.
    private func ensurePeripheralLink(central: CBCentral) {
        let identifier = central.identifier.uuidString
        let key = peripheralKey(identifier)
        guard linksByKey[key] == nil else { return }
        guard let peripheralManager, let ctrl = ctrlCharacteristic, let tx = txCharacteristic else { return }
        guard links.count < AirChatProtocol.maxLinks else {
            emit(.status(.nearbyFull, "附近人数已满（上限 \(AirChatProtocol.maxLinks)）"))
            return
        }

        // The peripheral's usable notification payload is defined by the central.
        let mtu = central.maximumUpdateValueLength + 3
        let link = BleLink(
            linkId: key,
            isCentral: false,
            peerLabel: identifier,
            logger: logger,
            onTerminated: { [weak self] closedLink, reason in
                self?.links.removeValue(forKey: closedLink.linkId)
                self?.linksByKey.removeValue(forKey: closedLink.linkId)
                self?.emit(.linkClosed(linkId: closedLink.linkId, reason: reason))
                self?.updateScanningForCapacity()
            }
        )
        link.bindPeripheral(
            server: peripheralManager,
            central: central,
            ctrl: ctrl,
            tx: tx,
            mtu: mtu
        )
        links[key] = link
        linksByKey[key] = link
        logger.log("BleTransport", "peripheral link up with \(identifier)")
        emit(.linkOpened(link))
        updateScanningForCapacity()
    }
}

// --------------------------------------------------------------- central delegate

extension BleTransport: CBPeripheralDelegate {

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        queue.async { [weak self] in
            guard let self else { return }
            let identifier = peripheral.identifier.uuidString
            guard let link = self.linksByKey[self.centralKey(identifier)] else { return }
            if let error {
                self.logger.log("BleTransport", "service discovery failed on \(identifier): \(error)")
                link.onDisconnected(status: "discovery failed")
                return
            }
            guard let service = peripheral.services?.first(where: { $0.uuid == BleUuids.service }) else {
                self.logger.log("BleTransport", "peer \(identifier) does not expose the AirChat service")
                link.onDisconnected(status: "missing service")
                return
            }
            peripheral.discoverCharacteristics(
                [BleUuids.ctrl, BleUuids.tx, BleUuids.rx],
                for: service
            )
        }
    }

    public func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        queue.async { [weak self] in
            guard let self else { return }
            let identifier = peripheral.identifier.uuidString
            guard let link = self.linksByKey[self.centralKey(identifier)] else { return }
            if let error {
                self.logger.log("BleTransport", "characteristic discovery failed on \(identifier): \(error)")
                link.onDisconnected(status: "discovery failed")
                return
            }
            let characteristics = service.characteristics ?? []
            guard characteristics.contains(where: { $0.uuid == BleUuids.ctrl }),
                  characteristics.contains(where: { $0.uuid == BleUuids.tx }),
                  characteristics.contains(where: { $0.uuid == BleUuids.rx }) else {
                self.logger.log("BleTransport", "peer \(identifier) is missing a required characteristic")
                link.onDisconnected(status: "missing characteristic")
                return
            }

            link.bindCentral(peripheral: peripheral, characteristics: characteristics)
            for characteristic in characteristics where characteristic.uuid == BleUuids.ctrl || characteristic.uuid == BleUuids.tx {
                peripheral.setNotifyValue(true, for: characteristic)
            }
            // CoreBluetooth negotiates the ATT MTU on its own; read the resulting usable length.
            link.refreshCentralMtu()
            link.markCentralReady()
        }
    }

    public func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        queue.async { [weak self] in
            guard let self else { return }
            guard error == nil else {
                self.logger.log("BleTransport", "read/notify error: \(String(describing: error))")
                return
            }
            let identifier = peripheral.identifier.uuidString
            self.linksByKey[self.centralKey(identifier)]?.onInbound(characteristic.value)
        }
    }

    public func peripheral(
        _ peripheral: CBPeripheral,
        didWriteValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        queue.async { [weak self] in
            guard let self else { return }
            let identifier = peripheral.identifier.uuidString
            guard let link = self.linksByKey[self.centralKey(identifier)] else { return }
            // The MTU can grow after the first exchange; pick up the newest value.
            link.refreshCentralMtu()
            link.onCharacteristicWritten(error: error)
        }
    }
}
