import AirChatProtocol
import Foundation

// See BleLink: the peripheral role is iOS-only.
#if os(iOS)
import CoreBluetooth

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
    /// Peripherals seen while scanning, kept so a tap can connect without waiting for the next
    /// advertisement to arrive with a fresh CBPeripheral object.
    private var discovered: [String: CBPeripheral] = [:]

    // Server-side characteristics are created once and reused across centrals.
    private var service: CBMutableService?
    private var ctrlCharacteristic: CBMutableCharacteristic?
    private var txCharacteristic: CBMutableCharacteristic?
    private var rxCharacteristic: CBMutableCharacteristic?


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
                // Deliberately NO CBCentralManagerOptionRestoreIdentifierKey.
                //
                // State restoration makes iOS automatically reconnect to every peripheral the
                // process ever connected to, which bypasses the connection-direction policy in
                // section 5.3.1 and re-creates the symmetric-connection storm: measured with
                // tools/cross_device_test.py as a link being created and dropped every second, with
                // no session ever reaching READY. Re-discovery on launch is cheap and predictable,
                // so restoration is not worth that.
                centralManager = CBCentralManager(
                    delegate: self,
                    queue: .main,
                    options: [CBCentralManagerOptionShowPowerAlertKey: false]
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
            discovered.removeAll()
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
            // The values are recorded for diagnostics only: iOS cannot advertise them (see
            // startAdvertising), so nothing needs re-advertising when they change.
            logger.log(
                "BleTransport",
                "presence updated (protocol v\(protocolVersion), caps \(capabilities)); iOS advertises the service UUID only"
            )
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

    /// Advertises the AirChat service UUID and nothing else.
    ///
    /// iOS cannot carry the presence block: a `CBAdvertisementDataServiceDataKey` dictionary is
    /// keyed by `CBUUID`, and CoreBluetooth aborts while encoding it for the Bluetooth daemon.
    /// Measured on iOS 27 with a symbolicated crash report:
    ///
    ///   CBXpcCreateXPCDictionaryWithNSDictionary -> -[CBUUID UTF8String]
    ///   -> NSInvalidArgumentException: unrecognized selector sent to instance
    ///   <- -[CBPeripheralManager startAdvertising:] <- BleTransport.startAdvertising()
    ///
    /// So the ticket/version hint is Android-only. That is acceptable because the block is
    /// non-authoritative by design (`docs/protocol.md` section 4): a peer advertising without it
    /// falls back to the SCAN_RETRY_AFTER_MS rule, and a redundant connection is resolved by the
    /// post-handshake link dedupe in section 5.4.
    private func startAdvertising() {
        guard running, let peripheralManager, peripheralManager.state == .poweredOn else { return }
        peripheralManager.startAdvertising([CBAdvertisementDataServiceUUIDsKey: [BleUuids.service]])
    }

    private func stopAdvertising() {
        guard let peripheralManager, peripheralManager.isAdvertising else {
            advertising = false
            return
        }
        peripheralManager.stopAdvertising()
        advertising = false
    }

    private func handleAdvertisingFailure(_ error: Error) {
        advertising = false
        logger.log("BleTransport", "advertising failed: \(error)")
        emit(.status(.bluetoothUnavailable, "蓝牙广播失败：\(error.localizedDescription)"))
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
        // Retained for `connectTo`: a tap must not have to wait for the next advertisement.
        discovered[key] = peripheral
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

        // Connection-direction policy, see docs/protocol.md section 5.3.1.
        //
        // iOS cannot advertise a presence block (see startAdvertising), so a ticket comparison
        // between iOS and Android can never be a decision both sides agree on: Android compares
        // against a pseudo-ticket it invents, iOS compares against a real one. Racing on that
        // produced a connect/disconnect storm - links died before HELLO_ACK could come back, so
        // no session ever reached READY.
        //
        // So iOS simply never races: it waits out the fallback window and only initiates when the
        // peer has not connected us, which covers "the peer is at its link cap" and iOS<->iOS (both
        // wait, both fall back, and the post-handshake dedupe keeps one link).
        // Never initiate while we are already talking to somebody.
        //
        // The identifier of a peer differs between the role that scanned it and the role it
        // connected in - measured on device - so the per-identifier guards above cannot tell that
        // this advertisement is a phone we already have a link with. iOS therefore kept opening a
        // new connection to a peer it was already connected to, and the duplicate sessions that
        // produced showed *different safety codes for the same peer*: the session key comes from the
        // two identities alone, but the code also commits to the handshake nonces, so two handshakes
        // disagree. That is a security-critical thing to put in front of a user, which is why this is
        // a policy rather than a rate limit.
        //
        // Cost: with several peers in range, iOS reaches whoever initiates towards it plus the first
        // peer the fallback found, and no further. Tapping a person in the list still connects
        // explicitly (see connectTo), which is a first-class action since the nearby page redesign.
        guard !links.values.contains(where: { $0.readyForTraffic }) else { return }

        let peerNeverCame = now - (seen[identifier]?.firstSeenMs ?? now) >= AirChatProtocol.scanRetryAfterMs
        guard peerNeverCame else { return }
        _ = peerTicket

        beginConnect(peripheral, identifier: identifier, reason: "our ticket=\(ticket), theirs=\(peerTicket)")
    }

    /// Connection the user asked for by tapping a nearby row.
    ///
    /// Deliberately skips the direction policy (protocol section 5.3) - the user outranks a ticket
    /// comparison - while still honouring the link cap and the reconnect backoff. A simultaneous
    /// tap on both sides produces two links, which the post-handshake dedupe in section 5.4 keeps
    /// to one exactly as it does for automatic connections.
    public func connectTo(peerLabel: String) {
        queue.sync {
            guard running else { return }
            guard
                linksByKey[centralKey(peerLabel)] == nil,
                linksByKey[peripheralKey(peerLabel)] == nil,
                !connecting.contains(peerLabel)
            else {
                logger.log("BleTransport", "explicit connect to \(peerLabel) skipped: already linked")
                return
            }
            guard links.count + connecting.count < AirChatProtocol.maxLinks else {
                logger.log("BleTransport", "explicit connect to \(peerLabel) refused: at the link cap")
                return
            }
            if let until = backoffUntil[peerLabel], clock() < until {
                logger.log("BleTransport", "explicit connect to \(peerLabel) refused: backing off")
                return
            }
            guard let peripheral = discovered[peerLabel] else {
                logger.log("BleTransport", "explicit connect to \(peerLabel) refused: not seen scanning")
                return
            }
            beginConnect(peripheral, identifier: peerLabel, reason: "user requested")
        }
    }

    /// Starts one connection attempt and records it.
    ///
    /// Shared by the direction policy and by the user-initiated path so both get identical
    /// bookkeeping: the in-flight set, the peripheral needed to close a connection that never
    /// completes, and the role-scoped link keys the delegate callbacks look up.
    private func beginConnect(_ peripheral: CBPeripheral, identifier: String, reason: String) {
        guard let centralManager, centralManager.state == .poweredOn else { return }
        connecting.insert(identifier)
        pendingPeripheral[identifier] = peripheral
        logger.log("BleTransport", "connecting to \(identifier) (\(reason))")
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
            var pendingResponses: [CBATTRequest] = []
            for request in requests {
                let identifier = request.central.identifier.uuidString
                self.ensurePeripheralLink(central: request.central)
                // Inbound frames arrive on CH_RX (data) *and* CH_CTRL (signalling), because
                // docs/protocol.md section 5.1 declares CH_CTRL bidirectional: the handshake and
                // PING/PONG/KEY_VERIFY frames the peer sends travel on it.
                //
                // Accepting only CH_RX silently discarded every HELLO a peer wrote to CH_CTRL,
                // which meant a link could never finish its handshake while this device was the
                // peripheral. Verified by tools/cross_device_test.py.
                let inboundCharacteristic = request.characteristic.uuid
                // Logged here rather than only in LinkSession: a write that never reaches the link
                // (because the characteristic is not one we accept) is otherwise indistinguishable
                // from a frame the session parsed and rejected.
                self.logger.log(
                    "BleTransport",
                    "peripheral write \(request.value?.count ?? 0) byte(s) on "
                        + "\(inboundCharacteristic.uuidString) from \(identifier)"
                )
                if inboundCharacteristic == BleUuids.rx || inboundCharacteristic == BleUuids.ctrl {
                    self.linksByKey[self.peripheralKey(identifier)]?.onInbound(request.value)
                }
                // write-with-response requires an explicit reply; write-without-response must not
                // be answered (protocol section 6.3).
                if request.characteristic.properties.contains(.write) {
                    // Only the request that actually asked for a reply may be answered, so remember
                    // it instead of assuming it is the first one in the batch.
                    pendingResponses.append(request)
                }
            }
            for request in pendingResponses {
                peripheral.respond(to: request, withResult: .success)
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

    /// Creates the peripheral-side link on first contact with a central, and refreshes the stored
    /// central on every later contact (a reconnect produces a new CBCentral for the same
    /// identifier - see BleLink.updateCentral).
    private func ensurePeripheralLink(central: CBCentral) {
        let identifier = central.identifier.uuidString
        let key = peripheralKey(identifier)
        if let existing = linksByKey[key] {
            existing.updateCentral(central)
            return
        }
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


#else

/// Non-iOS stub.
///
/// `CBPeripheralManager` does not exist on macOS, so the real transport cannot be built there.
/// Providing a stub keeps the package buildable on every declared platform, which is what allows
/// `swift test` (and therefore the protocol verification) to run without an iOS device or a
/// simulator.
public final class BleTransport: Transport {

    public let ticket: Int = AirChatCrypto.randomTicket()

    public init(logger: AirChatLogger = NoopLogger(), clock: @escaping () -> Int64 = { 0 }) {}

    public func setEventHandler(_ handler: @escaping (TransportEvent) -> Void) {
        handler(.status(.bluetoothUnavailable, "此平台不支持蓝牙 LE（AirChat 仅支持 iOS 与 Android）"))
    }

    public func start() {}

    public func stop() {}

    public func updatePresence(protocolVersion: Int, capabilities: Int) {}

    public func connectTo(peerLabel: String) {}
}

#endif // os(iOS)
