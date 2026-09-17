import Foundation

/// A peer currently visible in the advertising channel, connected or not.
public struct NearbyPeer: Equatable {
    public let label: String
    public let protocolVersion: Int
    public let capabilities: Int
    public let rssi: Int?
    public let firstSeenMs: Int64
    public let lastSeenMs: Int64

    public init(
        label: String,
        protocolVersion: Int,
        capabilities: Int,
        rssi: Int?,
        firstSeenMs: Int64,
        lastSeenMs: Int64
    ) {
        self.label = label
        self.protocolVersion = protocolVersion
        self.capabilities = capabilities
        self.rssi = rssi
        self.firstSeenMs = firstSeenMs
        self.lastSeenMs = lastSeenMs
    }
}

/// One live link, as shown in the UI.
public struct LinkInfo: Equatable {
    public let linkId: String
    public let peerIdHex: String?
    public let nickname: String?
    public let isCentral: Bool
    public let mtu: Int
    public let ready: Bool
    public let safetyCode: String?
    public let trustState: Int
    public let peerConfirmedTheCode: Bool

    public init(
        linkId: String,
        peerIdHex: String?,
        nickname: String?,
        isCentral: Bool,
        mtu: Int,
        ready: Bool,
        safetyCode: String?,
        trustState: Int,
        peerConfirmedTheCode: Bool
    ) {
        self.linkId = linkId
        self.peerIdHex = peerIdHex
        self.nickname = nickname
        self.isCentral = isCentral
        self.mtu = mtu
        self.ready = ready
        self.safetyCode = safetyCode
        self.trustState = trustState
        self.peerConfirmedTheCode = peerConfirmedTheCode
    }
}

public struct NodeState: Equatable {
    public var status: ChatStatus
    public var statusMessage: String
    public var deviceIdHex: String
    public var nickname: String
    public var nearby: [NearbyPeer]
    public var links: [LinkInfo]

    public init(
        status: ChatStatus = .stopped,
        statusMessage: String = "",
        deviceIdHex: String = "",
        nickname: String = "",
        nearby: [NearbyPeer] = [],
        links: [LinkInfo] = []
    ) {
        self.status = status
        self.statusMessage = statusMessage
        self.deviceIdHex = deviceIdHex
        self.nickname = nickname
        self.nearby = nearby
        self.links = links
    }

    public static let empty = NodeState()

    public var linkCount: Int { links.count }
    public var readyLinkCount: Int { links.filter { $0.ready }.count }
}

public enum NodeEvent {
    case messageStored(MessageRecord)
    case messageStatusChanged(msgIdHex: String, status: Int)
    case trustChanged(peerIdHex: String, trustState: Int)
    case peerCodeConfirmed(peerIdHex: String)
    case notice(String)
    case failure(String)
}

/// Result of a send attempt, so the UI can report a precise reason.
public enum SendResult {
    case sent(MessageRecord)
    case rejected(String)
}

/// Manages every link on one device: handshakes, link deduplication, message fan-out and dedupe,
/// trust state, keep-alive and idle detection.
///
/// Concurrency: all mutation happens on a private serial queue, which is also where transport
/// events and session callbacks are funnelled. `state` is additionally guarded by a lock so the
/// UI can read it from any thread without blocking on the queue.
///
/// The store contract is synchronous, so user intents use `queue.sync`. That is safe because no
/// node method is ever called from inside the node's own queue.
public final class AirChatNode: LinkSessionListener {

    private let store: ChatStore
    private let transport: Transport
    private let logger: AirChatLogger
    private let clock: () -> Int64
    private let capabilities: Int

    private let queue = DispatchQueue(label: "app.airchat.node")
    private let stateLock = NSLock()
    private var storedState = NodeState.empty

    private var sessions: [String: LinkSession] = [:]
    private var nearby: [String: NearbyPeer] = [:]
    private var peerConfirmedCode: Set<String> = []

    private var identity: LocalIdentity?
    private var nickname: String = AirChatProtocol.defaultNickname
    private var maintenanceTimer: DispatchSourceTimer?
    private var running = false

    /// Latest state snapshot. Thread-safe.
    public var state: NodeState {
        stateLock.lock()
        defer { stateLock.unlock() }
        return storedState
    }

    /// Called on the node's serial queue whenever the state changes.
    public var onStateChanged: ((NodeState) -> Void)?

    /// Called on the node's serial queue for every noteworthy event.
    public var onEvent: ((NodeEvent) -> Void)?

    public var deviceIdHex: String { identity?.deviceIdHex ?? "" }

    public var localNickname: String { queue.sync { nickname } }

    public init(
        store: ChatStore,
        transport: Transport,
        logger: AirChatLogger = NoopLogger(),
        clock: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) },
        capabilities: Int = Capabilities.all
    ) {
        self.store = store
        self.transport = transport
        self.logger = logger
        self.clock = clock
        self.capabilities = capabilities
    }

    // ---------------------------------------------------------------- lifecycle

    /// Loads or creates the persisted identity, then brings the transport up. Calling it again
    /// while running is a no-op.
    public func start() {
        queue.sync {
            guard !running else { return }
            running = true

            do {
                if let stored = try store.loadIdentity() {
                    let loaded = try LocalIdentity.from(record: stored)
                    identity = loaded
                    nickname = stored.nickname.isEmpty ? AirChatProtocol.defaultNickname : stored.nickname
                } else {
                    let created = LocalIdentity.generate()
                    try store.saveIdentity(created.toRecord(nickname: AirChatProtocol.defaultNickname))
                    identity = created
                    nickname = AirChatProtocol.defaultNickname
                }
            } catch {
                logger.log("AirChatNode", "identity load failed: \(error)")
                running = false
                emitEvent(.failure("无法初始化本机身份：\(error)"))
                return
            }

            logger.log("AirChatNode", "identity \(deviceIdHex) (\(nickname))")
            try? store.pruneChannel(
                retainCount: AirChatProtocol.channelRetainCount,
                retainDays: AirChatProtocol.channelRetainDays
            )
            publishState()

            transport.setEventHandler { [weak self] event in
                guard let self else { return }
                self.queue.async { self.handleTransportEvent(event) }
            }
            transport.updatePresence(protocolVersion: AirChatProtocol.version, capabilities: capabilities)
            startMaintenanceTimer()
            transport.start()
        }
    }

    public func stop() {
        queue.sync {
            guard running else { return }
            running = false
            maintenanceTimer?.cancel()
            maintenanceTimer = nil
            transport.stop()
            for session in sessions.values {
                session.link.close()
                session.markClosed()
            }
            sessions.removeAll()
            nearby.removeAll()
            publishState()
        }
    }

    public func setNickname(_ newNickname: String) {
        queue.sync {
            let trimmed = newNickname.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            guard Data(trimmed.utf8).count <= AirChatProtocol.maxNicknameBytes else { return }
            guard let identity else { return }
            nickname = trimmed
            try? store.saveIdentity(identity.toRecord(nickname: trimmed))
            publishState()
        }
    }

    // ---------------------------------------------------------------- outbound

    /// Sends a public channel message to every ready link.
    public func postChannelMessage(_ text: String) -> SendResult {
        queue.sync {
            let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if let rejection = validateOutgoingText(body) { return .rejected(rejection) }
            guard let me = identity else { return .rejected("身份尚未就绪") }

            let now = clock()
            let record = MessageRecord(
                msgId: AirChatCrypto.randomMessageId(),
                conversationId: AirChatProtocol.channelConversationId,
                kind: MessageKind.channel,
                direction: MessageDirection.outgoing,
                senderId: me.deviceId,
                recipientId: nil,
                text: body,
                timestampMs: now,
                receivedMs: now,
                status: MessageStatus.local
            )
            // Store first so a crash mid-send cannot lose the message.
            _ = try? store.insertMessage(record)
            emitEvent(.messageStored(record))

            let post = try? ChannelPost(
                msgId: record.msgId,
                timestampMillis: now,
                senderId: me.deviceId,
                senderNickname: nickname,
                text: body
            )
            var delivered = 0
            if let post {
                for session in readySessions() {
                    if session.sendChannelPost(post) { delivered += 1 }
                }
            }
            let status = delivered > 0 ? MessageStatus.sent : MessageStatus.failed
            _ = try? store.updateMessageStatus(record.msgId, status: status)
            if status != MessageStatus.local {
                emitEvent(.messageStatusChanged(msgIdHex: ByteOps.toHex(record.msgId), status: status))
            }
            publishState()
            return .sent(record.withStatus(status))
        }
    }

    /// Sends an encrypted 1:1 message to a specific peer.
    public func sendPrivateMessage(peerIdHex: String, text: String) -> SendResult {
        queue.sync {
            let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if let rejection = validateOutgoingText(body) { return .rejected(rejection) }
            guard let me = identity else { return .rejected("身份尚未就绪") }

            guard let peerId = ByteOps.fromHexOrNil(peerIdHex) else { return .rejected("设备标识无效") }
            guard peerId != me.deviceId else { return .rejected("无法给自己发消息") }

            if let peerRecord = try? store.getPeer(peerId),
               peerRecord.trustState == TrustState.rejected {
                return .rejected("安全码已被标记为不匹配，已阻止发送")
            }

            guard let session = readySessions().first(where: { $0.peerDeviceIdHex == peerIdHex }) else {
                return .rejected("对方不在附近")
            }

            let now = clock()
            guard let message = session.sendPrivateMessage(
                msgId: AirChatCrypto.randomMessageId(),
                timestampMillis: now,
                recipientId: peerId,
                plaintext: body
            ) else {
                return .rejected("会话未就绪")
            }

            let record = MessageRecord(
                msgId: message.msgId,
                conversationId: peerIdHex,
                kind: MessageKind.`private`,
                direction: MessageDirection.outgoing,
                senderId: me.deviceId,
                recipientId: peerId,
                text: body,
                timestampMs: now,
                receivedMs: now,
                status: MessageStatus.sent
            )
            _ = try? store.insertMessage(record)
            emitEvent(.messageStored(record))
            publishState()
            return .sent(record)
        }
    }

    /// Records the user's verdict on the safety code and tells the peer.
    public func confirmSafetyCode(peerIdHex: String, accepted: Bool) {
        queue.sync {
            guard let peerId = ByteOps.fromHexOrNil(peerIdHex) else { return }
            let trustState = accepted ? TrustState.trusted : TrustState.rejected
            try? store.setTrustState(peerId, trustState: trustState)
            for session in sessions.values where session.peerDeviceIdHex == peerIdHex {
                session.verifiedLocally = accepted
                session.sendKeyVerifyRequest()
            }
            emitEvent(.trustChanged(peerIdHex: peerIdHex, trustState: trustState))
            publishState()
        }
    }

    public func sendTyping(peerIdHex: String?, active: Bool) {
        queue.sync {
            if let peerIdHex {
                guard let peerId = ByteOps.fromHexOrNil(peerIdHex) else { return }
                // first(where:) already returns an Optional; no extra chaining is needed.
                if let session = sessions.values.first(where: {
                    $0.peerDeviceIdHex == peerIdHex && $0.isReady
                }) {
                    session.sendTyping(scope: .`private`, active: active, recipientId: peerId)
                }
            } else {
                let empty = Data(count: AirChatProtocol.deviceIdBytes)
                for session in readySessions() {
                    session.sendTyping(scope: .channel, active: active, recipientId: empty)
                }
            }
        }
    }

    /// Requests channel history from every ready peer that supports it.
    public func requestChannelSync() {
        queue.sync {
            for session in readySessions() where session.peer?.supportsSync == true {
                session.sendSyncRequest()
            }
        }
    }

    // ---------------------------------------------------------------- inbound

    private func handleTransportEvent(_ event: TransportEvent) {
        switch event {
        case .linkOpened(let link):
            guard let identity else { return }
            let session = LinkSession(
                link: link,
                localIdentity: identity,
                nicknameProvider: { [weak self] in self?.nickname ?? AirChatProtocol.defaultNickname },
                capabilities: capabilities,
                listener: self,
                clock: clock,
                logger: logger
            )
            // Register the consumer before starting the handshake: the peer may already be
            // writing HELLO, and the transport must not drop those bytes.
            link.setInboundHandler { [weak session] bytes in session?.onBytes(bytes) }
            sessions[link.linkId] = session
            logger.log("AirChatNode", "link opened \(link.linkId) (central=\(link.isCentral))")
            session.start()
            publishState()

        case .linkClosed(let linkId, let reason):
            if let session = sessions.removeValue(forKey: linkId) {
                session.markClosed()
                logger.log("AirChatNode", "link \(linkId) closed: \(reason)")
            }
            publishState()

        case .peerSeen(let label, let protocolVersion, let capabilities, _, let rssi):
            let now = clock()
            let existing = nearby[label]
            nearby[label] = NearbyPeer(
                label: label,
                protocolVersion: protocolVersion,
                capabilities: capabilities,
                rssi: rssi,
                firstSeenMs: existing?.firstSeenMs ?? now,
                lastSeenMs: now
            )
            publishState()

        case .peerLost(let label):
            nearby.removeValue(forKey: label)
            publishState()

        case .status(let status, let message):
            var next = state
            next.status = status
            next.statusMessage = message
            setState(next)
        }
    }

    // ------------------------------------------------------- session callbacks

    public func onReady(session: LinkSession, peer: Hello) {
        queue.async { [weak self] in self?.handleReady(session: session, peer: peer) }
    }

    public func onChannelPost(session: LinkSession, post: ChannelPost) {
        queue.async { [weak self] in self?.handleChannelPost(post: post, session: session) }
    }

    public func onPrivateMessage(session: LinkSession, received: ReceivedPrivateMessage) {
        queue.async { [weak self] in self?.handlePrivateMessage(received: received, session: session) }
    }

    public func onDeliveryAck(session: LinkSession, ack: DeliveryAck) {
        queue.async { [weak self] in self?.handleDeliveryAck(ack) }
    }

    public func onTyping(session: LinkSession, typing: Typing) {
        // Typing indicators are ephemeral and not persisted.
        queue.async { [weak self] in
            guard let self else { return }
            let peer = session.peerDeviceIdHex ?? "?"
            self.emitEvent(.notice("typing:\(peer):\(typing.scope.rawValue):\(typing.active)"))
        }
    }

    public func onSyncRequest(session: LinkSession, request: SyncRequest) {
        queue.async { [weak self] in self?.handleSyncRequest(session: session, request: request) }
    }

    public func onSyncResponse(session: LinkSession, response: SyncResponse) {
        queue.async { [weak self] in self?.handleSyncResponse(session: session, response: response) }
    }

    public func onKeyVerifyRequest(session: LinkSession) {
        queue.async { [weak self] in
            guard let self, let peerId = session.peerDeviceIdHex else { return }
            self.peerConfirmedCode.insert(peerId)
            self.emitEvent(.peerCodeConfirmed(peerIdHex: peerId))
            self.publishState()
        }
    }

    public func onKeyVerifyResponse(session: LinkSession, accepted: Bool) {
        queue.async { [weak self] in
            guard let self, let peerId = session.peerDeviceIdHex else { return }
            if accepted {
                self.peerConfirmedCode.insert(peerId)
                self.emitEvent(.peerCodeConfirmed(peerIdHex: peerId))
            }
            self.publishState()
        }
    }

    public func onFailed(session: LinkSession, reason: String) {
        queue.async { [weak self] in
            guard let self else { return }
            self.emitEvent(.failure("链路 \(session.link.linkId) 握手失败：\(reason)"))
            session.link.close()
            self.sessions.removeValue(forKey: session.link.linkId)?.markClosed()
            self.publishState()
        }
    }

    // ------------------------------------------------------------- handlers

    private func handleReady(session: LinkSession, peer: Hello) {
        rememberPeer(peer)

        // Protocol 5.4: keep the link whose central deviceId is smaller, drop the other.
        let peerHex = peer.deviceIdHex
        let duplicates = sessions.values.filter {
            $0 !== session && !$0.isTerminal && $0.peerDeviceIdHex == peerHex
        }
        for other in duplicates {
            let keep = chooseLinkToKeep(session, other)
            let drop = keep === session ? other : session
            logger.log("AirChatNode", "duplicate link with \(peerHex); dropping \(drop.link.linkId)")
            drop.link.close()
            drop.markClosed()
            sessions.removeValue(forKey: drop.link.linkId)
            emitEvent(.notice("检测到重复连接，已保留一条链路"))
        }
        guard session.state != .closed else {
            publishState()
            return
        }

        let now = clock()
        if let key = session.sessionKey {
            let existingTrust = (try? store.getPeer(peer.deviceId))?.trustState
            try? store.saveSession(
                SessionRecord(
                    peerDeviceId: peer.deviceId,
                    sessionKey: key,
                    peerPublicKey: peer.publicKey,
                    verified: existingTrust == TrustState.trusted,
                    createdMs: now,
                    lastUsedMs: now
                )
            )
        }
        session.verifiedLocally = (try? store.getPeer(peer.deviceId))?.trustState == TrustState.trusted

        if peer.supportsSync {
            session.sendSyncRequest()
        }
        publishState()
    }

    private func handleChannelPost(post: ChannelPost, session: LinkSession) {
        rememberPeerFromChannelPost(post, session: session)
        let record = MessageRecord(
            msgId: post.msgId,
            conversationId: AirChatProtocol.channelConversationId,
            kind: MessageKind.channel,
            direction: MessageDirection.incoming,
            senderId: post.senderId,
            recipientId: nil,
            text: post.text,
            timestampMs: post.timestampMillis,
            receivedMs: clock(),
            status: MessageStatus.delivered
        )
        if (try? store.insertMessage(record)) == true {
            emitEvent(.messageStored(record))
            publishState()
        }
    }

    private func handlePrivateMessage(received: ReceivedPrivateMessage, session: LinkSession) {
        let message = received.message
        var stored = false

        if let plaintext = received.plaintext {
            rememberPeerFromPrivateMessage(message)
            let record = MessageRecord(
                msgId: message.msgId,
                conversationId: ByteOps.toHex(message.senderId),
                kind: MessageKind.`private`,
                direction: MessageDirection.incoming,
                senderId: message.senderId,
                recipientId: message.recipientId,
                text: plaintext,
                timestampMs: message.timestampMillis,
                receivedMs: clock(),
                status: MessageStatus.delivered
            )
            stored = (try? store.insertMessage(record)) == true
            if stored { emitEvent(.messageStored(record)) }
        }

        // Always acknowledge, even for duplicates or failures: that is what stops peer retries.
        session.sendDeliveryAck(
            msgId: message.msgId,
            status: received.decrypted ? .delivered : .undecryptable
        )
        if stored { publishState() }
    }

    private func handleDeliveryAck(_ ack: DeliveryAck) {
        let status = ack.status == .delivered ? MessageStatus.delivered : MessageStatus.failed
        // A single conditional update doubles as the existence check: an ACK for an unknown msgId
        // (e.g. one we never sent) must be ignored.
        guard (try? store.updateMessageStatus(ack.msgId, status: status)) == true else { return }
        emitEvent(.messageStatusChanged(msgIdHex: ByteOps.toHex(ack.msgId), status: status))
        publishState()
    }

    private func handleSyncRequest(session: LinkSession, request: SyncRequest) {
        let windowMs = Int64(max(0, min(request.sinceMinutesAgo, 24 * 60))) * 60_000
        let since = clock() - windowMs
        let limit = max(1, min(request.maxCount, AirChatProtocol.syncMaxCount))
        let history = (try? store.historySince(since, limit: limit)) ?? []

        var posts: [ChannelPost] = []
        for record in history where record.kind == MessageKind.channel {
            guard let post = try? ChannelPost(
                msgId: record.msgId,
                timestampMillis: record.timestampMs,
                senderId: record.senderId,
                senderNickname: (try? store.getPeer(record.senderId))?.nickname ?? "",
                text: record.text
            ) else { continue }
            posts.append(post)
        }
        session.sendSyncResponse(posts: posts)
    }

    private func handleSyncResponse(session: LinkSession, response: SyncResponse) {
        var added = 0
        for post in response.posts {
            rememberPeerFromChannelPost(post, session: session)
            let record = MessageRecord(
                msgId: post.msgId,
                conversationId: AirChatProtocol.channelConversationId,
                kind: MessageKind.channel,
                direction: MessageDirection.incoming,
                senderId: post.senderId,
                recipientId: nil,
                text: post.text,
                timestampMs: post.timestampMillis,
                receivedMs: clock(),
                status: MessageStatus.delivered
            )
            if (try? store.insertMessage(record)) == true { added += 1 }
        }
        if added > 0 { emitEvent(.notice("已同步 \(added) 条历史消息")) }
        publishState()
    }

    // -------------------------------------------------------------- helpers

    private func rememberPeer(_ hello: Hello) {
        let now = clock()
        let existing = try? store.getPeer(hello.deviceId)
        let keyChanged = existing != nil && existing?.publicKey != hello.publicKey
        if keyChanged {
            emitEvent(.notice("\(hello.nickname) 的公钥已变化，请重新核对安全码"))
        }
        let trustState: Int
        if existing == nil || keyChanged {
            // Protocol 10.3 rule 5: a changed public key must fall back to UNVERIFIED.
            trustState = TrustState.unverified
        } else {
            trustState = existing?.trustState ?? TrustState.unverified
        }
        try? store.upsertPeer(
            PeerRecord(
                deviceId: hello.deviceId,
                nickname: hello.nickname,
                publicKey: hello.publicKey,
                trustState: trustState,
                lastSeenMs: now,
                createdMs: existing?.createdMs ?? now
            )
        )
    }

    /// Channel posts carry a nickname snapshot but no public key; keep any known key.
    private func rememberPeerFromChannelPost(_ post: ChannelPost, session: LinkSession) {
        let now = clock()
        let existing = try? store.getPeer(post.senderId)
        guard let knownKey = existing?.publicKey ?? session.peer?.publicKey else { return }
        let nickname = post.senderNickname.isEmpty
            ? (existing?.nickname ?? "")
            : post.senderNickname
        try? store.upsertPeer(
            PeerRecord(
                deviceId: post.senderId,
                nickname: nickname,
                publicKey: knownKey,
                trustState: existing?.trustState ?? TrustState.unverified,
                lastSeenMs: now,
                createdMs: existing?.createdMs ?? now
            )
        )
    }

    private func rememberPeerFromPrivateMessage(_ message: PrivateMessage) {
        guard let existing = try? store.getPeer(message.senderId) else { return }
        try? store.upsertPeer(
            PeerRecord(
                deviceId: existing.deviceId,
                nickname: existing.nickname,
                publicKey: existing.publicKey,
                trustState: existing.trustState,
                lastSeenMs: clock(),
                createdMs: existing.createdMs
            )
        )
    }

    /// Protocol 5.4: prefer the link whose central has the smaller deviceId. Both peers evaluate
    /// the same predicate over the same two deviceIds, so both converge on the same survivor.
    private func chooseLinkToKeep(_ a: LinkSession, _ b: LinkSession) -> LinkSession {
        guard let centralA = centralDeviceId(a) else { return a }
        guard let centralB = centralDeviceId(b) else { return b }
        return ByteOps.compareUnsigned(centralA, centralB) <= 0 ? a : b
    }

    private func centralDeviceId(_ session: LinkSession) -> Data? {
        if session.link.isCentral {
            return identity?.deviceId
        }
        return session.peer?.deviceId
    }

    private func readySessions() -> [LinkSession] {
        sessions.values.filter { $0.isReady }
    }

    private func validateOutgoingText(_ text: String) -> String? {
        if text.isEmpty { return "消息不能为空" }
        if text.count > AirChatProtocol.maxTextChars {
            return "消息超过 \(AirChatProtocol.maxTextChars) 字"
        }
        if Data(text.utf8).count > AirChatProtocol.maxTextBytes {
            return "消息超过 \(AirChatProtocol.maxTextBytes) 字节"
        }
        return nil
    }

    // ---------------------------------------------------------------- state

    private func emitEvent(_ event: NodeEvent) {
        onEvent?(event)
    }

    private func setState(_ next: NodeState) {
        stateLock.lock()
        storedState = next
        stateLock.unlock()
        onStateChanged?(next)
    }

    private func publishState() {
        let now = clock()
        // Nearby entries that stopped advertising are pruned here.
        nearby = nearby.filter { now - $0.value.lastSeenMs <= Self.nearbyTtlMs }

        var links: [LinkInfo] = []
        links.reserveCapacity(sessions.count)
        for session in sessions.values {
            let peerHex = session.peerDeviceIdHex
            let trustState: Int
            if let peerId = session.peer?.deviceId, let record = try? store.getPeer(peerId) {
                trustState = record.trustState
            } else {
                trustState = TrustState.unverified
            }
            links.append(
                LinkInfo(
                    linkId: session.link.linkId,
                    peerIdHex: peerHex,
                    nickname: session.peer?.nickname,
                    isCentral: session.link.isCentral,
                    mtu: session.link.mtu,
                    ready: session.isReady,
                    safetyCode: session.safetyCode,
                    trustState: trustState,
                    peerConfirmedTheCode: peerHex.map { peerConfirmedCode.contains($0) } ?? false
                )
            )
        }

        var next = state
        next.deviceIdHex = identity?.deviceIdHex ?? ""
        next.nickname = nickname
        next.nearby = nearby.values.sorted { $0.lastSeenMs > $1.lastSeenMs }
        next.links = links
        setState(next)
    }

    // ----------------------------------------------------------- maintenance

    private func startMaintenanceTimer() {
        maintenanceTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .seconds(5), repeating: .seconds(5))
        timer.setEventHandler { [weak self] in self?.maintenanceTick() }
        timer.resume()
        maintenanceTimer = timer
    }

    private func maintenanceTick() {
        guard running else { return }
        let now = clock()

        for session in sessions.values where session.isReady {
            if now - session.lastInboundAtMs > AirChatProtocol.linkIdleTimeoutMs {
                logger.log("AirChatNode", "idle timeout on \(session.link.linkId)")
                session.link.close()
                session.markClosed()
                sessions.removeValue(forKey: session.link.linkId)
            } else if now - session.lastOutboundAtMs >= AirChatProtocol.pingIntervalMs {
                session.ping()
            }
        }
        publishState()
    }

    private static let nearbyTtlMs: Int64 = 15_000
}
