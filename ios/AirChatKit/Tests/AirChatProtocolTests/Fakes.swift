import Foundation
@testable import AirChatProtocol

/// In-memory `Link` pair used to exercise the full session and node pipelines without hardware.
///
/// `send` hands the raw chunk straight to the peer's inbound handler, which is exactly what a BLE
/// write or notification looks like from the application's point of view. Setting a small MTU
/// therefore exercises real fragmentation and reassembly.
final class FakeLink: Link {
    let linkId: String
    let isCentral: Bool
    let peerLabel: String?
    var mtu: Int

    weak var peer: FakeLink?

    /// Invoked once when this link closes; wired to the owning transport so a disconnect surfaces
    /// as a real `linkClosed` event, exactly like a CoreBluetooth disconnect.
    var onClosed: (() -> Void)?

    /// When true, `send` reports failure, simulating a saturated or dropped link.
    var failSend = false

    private var handler: ((Data) -> Void)?
    private var earlyBytes: [Data] = []

    /// Stands in for the transport's single serial queue; see `closeFromPeer`.
    private let lock = NSLock()

    /// Every chunk handed to the transport, in order, tagged with the channel it used.
    private(set) var sentChunks: [(control: Bool, bytes: Data)] = []

    private(set) var closed = false

    init(linkId: String, isCentral: Bool, mtu: Int = 185, peerLabel: String? = nil) {
        self.linkId = linkId
        self.isCentral = isCentral
        self.mtu = mtu
        self.peerLabel = peerLabel
    }

    func setInboundHandler(_ handler: @escaping (Data) -> Void) {
        let pending: [Data]
        lock.lock()
        self.handler = handler
        pending = earlyBytes
        earlyBytes.removeAll()
        lock.unlock()
        // Honour the transport contract: bytes that arrived before registration are flushed.
        // Outside the lock, because the flush runs peer code that may send straight back.
        for bytes in pending { handler(bytes) }
    }

    func send(_ bytes: Data, control: Bool) -> Bool {
        let target: FakeLink?
        lock.lock()
        if closed || failSend {
            lock.unlock()
            return false
        }
        sentChunks.append((control: control, bytes: bytes))
        target = peer
        lock.unlock()
        // Delivered outside the lock: the peer's handler runs protocol code that writes straight
        // back through this same pair, and holding a lock across it would deadlock.
        target?.deliver(bytes)
        return true
    }

    func close() {
        let notify: (() -> Void)?
        lock.lock()
        if closed {
            lock.unlock()
            return
        }
        closed = true
        notify = onClosed
        lock.unlock()
        notify?()
        // A BLE disconnect is observed by both ends, so the peer's transport must also report it.
        peer?.closeFromPeer()
    }

    /// Marks this link closed on behalf of the peer that closed.
    ///
    /// The real transports deliver every callback on one serial queue per link, so a byte that
    /// arrives before `setInboundHandler` is either seen by the flush or by the handler itself - it
    /// cannot fall between them. The fake had no such serialisation and the two nodes run on their
    /// own queues, so a HELLO could be appended to `earlyBytes` after the flush had already read
    /// them: the link then existed on both sides with no bytes ever crossing it, which is far more
    /// confusing to debug than a crash. This lock restores the serial-queue contract.
    private func closeFromPeer() {
        let notify: (() -> Void)?
        lock.lock()
        if closed {
            lock.unlock()
            return
        }
        closed = true
        notify = onClosed
        lock.unlock()
        notify?()
    }

    /// Injects raw bytes as if they had been received from the peer. Used to simulate a hostile or
    /// buggy peer (spoofed sender ids, unknown frame types, malformed payloads).
    func inject(_ bytes: Data) {
        deliver(bytes)
    }

    /// Number of frames the local side wrote, derived from the raw chunk stream.
    func framesSentToPeer() -> [Frame] {
        let framer = StreamFramer()
        var frames: [Frame] = []
        for chunk in sentChunks {
            switch framer.push(chunk.bytes) {
            case .frames(let parsed): frames.append(contentsOf: parsed)
            case .fatal: break
            }
        }
        return frames
    }

    private func deliver(_ bytes: Data) {
        let target: ((Data) -> Void)?
        lock.lock()
        if closed {
            lock.unlock()
            return
        }
        if let handler {
            target = handler
            lock.unlock()
        } else {
            earlyBytes.append(bytes)
            lock.unlock()
            return
        }
        target?(bytes)
    }
}

/// Test double for `Transport`; links are opened and closed explicitly by the harness.
final class FakeTransport: Transport {
    let ticket: Int

    private var handler: ((TransportEvent) -> Void)?

    private(set) var started = false
    private(set) var lastPresence: (Int, Int)?

    init(ticket: Int = 1000) {
        self.ticket = ticket
    }

    func setEventHandler(_ handler: @escaping (TransportEvent) -> Void) {
        self.handler = handler
    }

    func start() { started = true }
    func stop() { started = false }

    func updatePresence(protocolVersion: Int, capabilities: Int) {
        lastPresence = (protocolVersion, capabilities)
    }

    /// Handles the node asked to connect to, in order, so a tap can be asserted end to end.
    private(set) var connectRequests: [String] = []

    func connectTo(peerLabel: String) {
        connectRequests.append(peerLabel)
    }

    func open(_ link: Link) {
        handler?(.linkOpened(link))
    }

    func closeLink(linkId: String, reason: String) {
        handler?(.linkClosed(linkId: linkId, reason: reason))
    }

    func reportSeen(
        label: String,
        protocolVersion: Int = AirChatProtocol.version,
        capabilities: Int = Capabilities.all,
        ticket: Int = 2000,
        rssi: Int? = -60
    ) {
        handler?(.peerSeen(
            peerLabel: label,
            protocolVersion: protocolVersion,
            capabilities: capabilities,
            ticket: ticket,
            rssi: rssi
        ))
    }

    func reportStatus(_ status: ChatStatus, _ message: String) {
        handler?(.status(status, message))
    }
}

/// Creates a cross-wired link pair between two fake transports.
enum FakeBle {
    @discardableResult
    static func connect(
        _ a: FakeTransport,
        _ b: FakeTransport,
        mtu: Int = 185,
        aIsCentral: Bool = true,
        labelPrefix: String = "link",
        // The platform handle each side sees. Tests that assert nearby-list attribution set these
        // to the label the owning transport reports through `reportSeen`.
        labelA: String = "peer-of-a",
        labelB: String = "peer-of-b"
    ) -> (FakeLink, FakeLink) {
        let stamp = UUID().uuidString.prefix(8)
        let linkA = FakeLink(linkId: "\(labelPrefix)-a-\(stamp)", isCentral: aIsCentral, mtu: mtu, peerLabel: labelA)
        let linkB = FakeLink(linkId: "\(labelPrefix)-b-\(stamp)", isCentral: !aIsCentral, mtu: mtu, peerLabel: labelB)
        linkA.peer = linkB
        linkB.peer = linkA
        linkA.onClosed = { a.closeLink(linkId: linkA.linkId, reason: "disconnected") }
        linkB.onClosed = { b.closeLink(linkId: linkB.linkId, reason: "disconnected") }
        a.open(linkA)
        b.open(linkB)
        return (linkA, linkB)
    }
}

/// Minimal in-memory `ChatStore` with the same ordering guarantees as the SQLite implementation.
///
/// Every access is guarded by a recursive lock: the node writes from its own serial queue while
/// the test reads from the test thread, and an unsynchronised Swift Dictionary read during a write
/// is a genuine crash risk.
final class InMemoryChatStore: ChatStore {
    private let lock = NSRecursiveLock()
    private var identity: IdentityRecord?
    private var peers: [String: PeerRecord] = [:]
    private var messages: [String: MessageRecord] = [:]
    private var sessions: [String: SessionRecord] = [:]

    /// Ordered log of stored message ids, used to assert insertion order and count.
    private var order: [String] = []
    private var calls = 0

    init(identity: IdentityRecord? = nil) {
        self.identity = identity
    }

    var messageOrder: [String] {
        lock.lock(); defer { lock.unlock() }
        return order
    }

    var insertCalls: Int {
        lock.lock(); defer { lock.unlock() }
        return calls
    }

    func loadIdentity() throws -> IdentityRecord? {
        lock.lock(); defer { lock.unlock() }
        return identity
    }

    func saveIdentity(_ record: IdentityRecord) throws {
        lock.lock(); defer { lock.unlock() }
        identity = record
    }

    func upsertPeer(_ record: PeerRecord) throws {
        lock.lock(); defer { lock.unlock() }
        peers[ByteOps.toHex(record.deviceId)] = record
    }

    func getPeer(_ deviceId: Data) throws -> PeerRecord? {
        lock.lock(); defer { lock.unlock() }
        return peers[ByteOps.toHex(deviceId)]
    }

    func listPeers() throws -> [PeerRecord] {
        lock.lock(); defer { lock.unlock() }
        return Array(peers.values)
    }

    func setTrustState(_ deviceId: Data, trustState: Int) throws {
        lock.lock(); defer { lock.unlock() }
        let key = ByteOps.toHex(deviceId)
        guard let existing = peers[key] else { return }
        peers[key] = PeerRecord(
            deviceId: existing.deviceId,
            nickname: existing.nickname,
            publicKey: existing.publicKey,
            trustState: trustState,
            lastSeenMs: existing.lastSeenMs,
            createdMs: existing.createdMs
        )
    }

    func insertMessage(_ record: MessageRecord) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        calls += 1
        let key = ByteOps.toHex(record.msgId)
        guard messages[key] == nil else { return false }
        messages[key] = record
        order.append(key)
        return true
    }

    func getMessage(_ msgId: Data) throws -> MessageRecord? {
        lock.lock(); defer { lock.unlock() }
        return messages[ByteOps.toHex(msgId)]
    }

    func updateMessageStatus(_ msgId: Data, status: Int) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        let key = ByteOps.toHex(msgId)
        guard let existing = messages[key] else { return false }
        messages[key] = existing.withStatus(status)
        return true
    }

    func listMessages(conversationId: String, limit: Int) throws -> [MessageRecord] {
        lock.lock(); defer { lock.unlock() }
        return messages.values
            .filter { $0.conversationId == conversationId }
            .sorted(by: Self.chronological)
            .suffix(limit)
            .map { $0 }
    }

    func historySince(_ sinceMs: Int64, limit: Int) throws -> [MessageRecord] {
        lock.lock(); defer { lock.unlock() }
        return messages.values
            .filter { $0.kind == MessageKind.channel && $0.receivedMs >= sinceMs }
            .sorted(by: Self.chronological)
            .prefix(limit)
            .map { $0 }
    }

    /// The sort key from `docs/protocol.md`: the sender's timestamp first, then the local receive
    /// time, then the message id. Ordering on the receive time alone also made this fake
    /// non-deterministic, because `sorted` is not stable and the input is a Dictionary whose order
    /// depends on the per-process hash seed - and a batch of history backfilled by SYNC shares one
    /// receive millisecond, so the whole batch would come back in a random order.
    private static func chronological(_ lhs: MessageRecord, _ rhs: MessageRecord) -> Bool {
        if lhs.timestampMs != rhs.timestampMs { return lhs.timestampMs < rhs.timestampMs }
        if lhs.receivedMs != rhs.receivedMs { return lhs.receivedMs < rhs.receivedMs }
        return ByteOps.toHex(lhs.msgId) < ByteOps.toHex(rhs.msgId)
    }

    func saveSession(_ record: SessionRecord) throws {
        lock.lock(); defer { lock.unlock() }
        sessions[ByteOps.toHex(record.peerDeviceId)] = record
    }

    func getSession(_ peerDeviceId: Data) throws -> SessionRecord? {
        lock.lock(); defer { lock.unlock() }
        return sessions[ByteOps.toHex(peerDeviceId)]
    }

    func pruneChannel(retainCount: Int, retainDays: Int) throws {}
}
