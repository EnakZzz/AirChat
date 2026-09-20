import Foundation

/// Why a link session stopped being usable.
public enum SessionState: Equatable {
    case new
    case handshaking
    case ready
    case failed
    case closed
}

/// A decrypted (or undecryptable) private message handed to the node layer.
public struct ReceivedPrivateMessage {
    public let message: PrivateMessage
    public let plaintext: String?

    public init(message: PrivateMessage, plaintext: String?) {
        self.message = message
        self.plaintext = plaintext
    }

    public var decrypted: Bool { plaintext != nil }
}

/// Per-link callbacks. All are invoked synchronously on the caller's queue.
public protocol LinkSessionListener: AnyObject {
    func onReady(session: LinkSession, peer: Hello)
    func onChannelPost(session: LinkSession, post: ChannelPost)
    func onPrivateMessage(session: LinkSession, received: ReceivedPrivateMessage)
    func onDeliveryAck(session: LinkSession, ack: DeliveryAck)
    func onTyping(session: LinkSession, typing: Typing)
    func onSyncRequest(session: LinkSession, request: SyncRequest)
    func onSyncResponse(session: LinkSession, response: SyncResponse)
    func onKeyVerifyRequest(session: LinkSession)
    func onKeyVerifyResponse(session: LinkSession, accepted: Bool)
    func onFailed(session: LinkSession, reason: String)
}

/// The per-link protocol state machine: handshake, session-key derivation, safety number and
/// validation of every inbound frame.
///
/// Deliberately synchronous and free of concurrency primitives. CoreBluetooth callbacks are
/// funnelled onto a single serial queue by the transport, and the node layer performs any
/// persistence work from inside the callbacks. Sends are non-blocking and return false when the
/// link is gone.
///
/// Validation rules come from `docs/protocol.md` section 9. A frame that fails validation is
/// dropped without disturbing the link; only framing errors or a handshake failure tear the link
/// down.
public final class LinkSession {

    public let link: Link
    private let localIdentity: LocalIdentity
    private let nicknameProvider: () -> String
    private let capabilities: Int
    private weak var listener: LinkSessionListener?
    private let clock: () -> Int64
    private let logger: AirChatLogger
    private let framer = StreamFramer()
    private let chunker = StreamChunker()
    private let myHelloNonce: Data

    public private(set) var state: SessionState = .new
    public private(set) var peer: Hello?
    public private(set) var sessionKey: Data?
    public private(set) var safetyCode: String?
    public private(set) var lastInboundAtMs: Int64 = 0
    public private(set) var lastOutboundAtMs: Int64 = 0

    /// Whether the local user has confirmed this peer's safety code. Supplied by the node layer so
    /// a KEY_VERIFY_REQ from the peer can be answered with our own real state.
    public var verifiedLocally: Bool = false

    public var isReady: Bool { state == .ready }

    public var isTerminal: Bool { state == .failed || state == .closed }

    public var peerDeviceIdHex: String? { peer.map { ByteOps.toHex($0.deviceId) } }

    /// Initiator = the GATT central, which is the side that speaks first (protocol section 8.1).
    public var isInitiator: Bool { link.isCentral }

    public init(
        link: Link,
        localIdentity: LocalIdentity,
        nicknameProvider: @escaping () -> String,
        capabilities: Int,
        listener: LinkSessionListener,
        clock: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) },
        logger: AirChatLogger = NoopLogger()
    ) {
        self.link = link
        self.localIdentity = localIdentity
        self.nicknameProvider = nicknameProvider
        self.capabilities = capabilities
        self.listener = listener
        self.clock = clock
        self.logger = logger
        self.myHelloNonce = AirChatCrypto.randomData(AirChatProtocol.helloNonceBytes)
    }

    // -------------------------------------------------------------- lifecycle

    /// Starts the handshake. Only the initiator acts; a peripheral waits for the inbound HELLO
    /// before replying with HELLO_ACK.
    public func start() {
        guard state == .new else { return }
        state = .handshaking
        if link.isCentral {
            sendHello(frameType: FrameType.hello)
        }
    }

    // --------------------------------------------------------------- inbound

    public func onBytes(_ bytes: Data) {
        guard !isTerminal else { return }
        lastInboundAtMs = clock()
        logger.log("LinkSession", "inbound \(bytes.count) byte(s) on link \(link.linkId)")

        switch framer.push(bytes) {
        case .fatal(_, let message):
            fail("framing error: \(message)")
            listener?.onFailed(session: self, reason: message)

        case .frames(let frames):
            for frame in frames {
                if isTerminal { return }
                handle(frame)
            }
        }
    }

    private func handle(_ frame: Frame) {
        // One line per decoded frame: without it a received-but-rejected frame and a frame that
        // never arrived produce the same silence on the peer.
        logger.log("LinkSession", "frame \(FrameType.name(frame.type)) \(frame.payload.count) byte(s)")
        switch frame.type {
        case FrameType.hello, FrameType.helloAck:
            guard let hello = MessageCodec.decodeHello(frame.payload) else {
                logger.log("LinkSession", "dropping malformed HELLO from \(link.peerLabel ?? "?")")
                return
            }
            if frame.type == FrameType.hello {
                sendHello(frameType: FrameType.helloAck)
            }
            completeHandshake(with: hello)

        case FrameType.ping:
            _ = sendFrame(type: FrameType.pong, payload: Data())

        case FrameType.pong:
            break

        case FrameType.channelPost:
            guard let post = MessageCodec.decodeChannelPost(frame.payload) else {
                logger.log("LinkSession", "dropping malformed CHANNEL_POST")
                return
            }
            // Protocol section 9 rule 4: single hop, so the sender must be the connected peer.
            guard matchesPeer(post.senderId) else {
                logger.log("LinkSession", "dropping CHANNEL_POST with spoofed senderId")
                return
            }
            listener?.onChannelPost(session: self, post: post)

        case FrameType.privateMsg:
            guard let message = MessageCodec.decodePrivateMessage(frame.payload) else {
                logger.log("LinkSession", "dropping malformed PRIVATE_MSG")
                return
            }
            guard matchesPeer(message.senderId), message.recipientId == localIdentity.deviceId else {
                logger.log("LinkSession", "dropping PRIVATE_MSG addressed elsewhere")
                return
            }
            let plaintext = decrypt(message)
            if plaintext == nil {
                // Distinguishes "the frame never arrived" from "it arrived but authentication failed",
                // which is otherwise completely silent: the peer is acknowledged either way.
                logger.log(
                    "LinkSession",
                    "private message \(ByteOps.toHex(message.msgId)) failed to decrypt"
                )
            }
            listener?.onPrivateMessage(
                session: self,
                received: ReceivedPrivateMessage(message: message, plaintext: plaintext)
            )

        case FrameType.deliveryAck:
            guard let ack = MessageCodec.decodeDeliveryAck(frame.payload) else {
                logger.log("LinkSession", "dropping malformed DELIVERY_ACK")
                return
            }
            listener?.onDeliveryAck(session: self, ack: ack)

        case FrameType.typing:
            guard let typing = MessageCodec.decodeTyping(frame.payload) else {
                logger.log("LinkSession", "dropping malformed TYPING")
                return
            }
            listener?.onTyping(session: self, typing: typing)

        case FrameType.syncReq:
            guard let request = MessageCodec.decodeSyncRequest(frame.payload), matchesPeer(request.requesterId) else {
                logger.log("LinkSession", "dropping SYNC_REQ with spoofed requesterId")
                return
            }
            listener?.onSyncRequest(session: self, request: request)

        case FrameType.syncResp:
            guard let response = MessageCodec.decodeSyncResponse(frame.payload) else {
                logger.log("LinkSession", "dropping malformed SYNC_RESP")
                return
            }
            // Entries must originate from the connected peer; anything else is dropped.
            let filtered = response.posts.filter { matchesPeer($0.senderId) }
            listener?.onSyncResponse(session: self, response: SyncResponse(posts: filtered))

        case FrameType.keyVerifyReq:
            // The peer confirmed the safety code locally. We record their claim, answer with our
            // own state, and never trust ourselves on their behalf (protocol section 10.3).
            listener?.onKeyVerifyRequest(session: self)
            _ = sendKeyVerifyResponse(accepted: verifiedLocally)

        case FrameType.keyVerifyResp:
            guard let response = MessageCodec.decodeKeyVerifyResponse(frame.payload) else {
                logger.log("LinkSession", "dropping malformed KEY_VERIFY_RESP")
                return
            }
            listener?.onKeyVerifyResponse(session: self, accepted: response.accepted)

        default:
            // Layering contract: the framer surfaces unknown types, the session drops them.
            logger.log("LinkSession", String(format: "ignoring unknown frame type 0x%02x", frame.type))
        }
    }

    private func matchesPeer(_ deviceId: Data) -> Bool {
        guard let peer else { return false }
        return peer.deviceId == deviceId
    }

    private func decrypt(_ message: PrivateMessage) -> String? {
        guard isReady, let key = sessionKey else { return nil }
        guard let plaintext = AirChatCrypto.open(
            key: key,
            nonce: message.nonce,
            ciphertextAndTag: message.ciphertext,
            aad: AirChatCrypto.privateMessageAad(
                msgId: message.msgId,
                senderId: message.senderId,
                recipientId: message.recipientId
            )
        ) else { return nil }
        return String(decoding: plaintext, as: UTF8.self)
    }

    // ------------------------------------------------------------- handshake

    private func sendHello(frameType: Int) {
        guard let payload = MessageCodec.encodeHello(
            try! Hello(
                protocolVersion: AirChatProtocol.version,
                deviceId: localIdentity.deviceId,
                nickname: nicknameProvider(),
                publicKey: localIdentity.publicKeyBytes,
                capabilities: capabilities,
                helloNonce: myHelloNonce
            )
        ) else {
            logger.log("LinkSession", "could not encode HELLO")
            return
        }
        _ = sendFrame(type: frameType, payload: payload)
    }

    private func completeHandshake(with hello: Hello) {
        guard state != .ready else { return }
        guard hello.protocolVersion == AirChatProtocol.version else {
            let reason = "peer speaks protocol v\(hello.protocolVersion), we speak v\(AirChatProtocol.version)"
            fail(reason)
            listener?.onFailed(session: self, reason: reason)
            return
        }
        guard let peerKey = try? AirChatCrypto.publicKey(fromRaw: hello.publicKey) else {
            let reason = "peer sent an invalid public key"
            fail(reason)
            listener?.onFailed(session: self, reason: reason)
            return
        }

        peer = hello
        guard let sharedSecret = try? AirChatCrypto.ecdh(
            privateKey: localIdentity.privateKey,
            peerPublicKey: peerKey
        ) else {
            let reason = "ECDH failed"
            fail(reason)
            listener?.onFailed(session: self, reason: reason)
            return
        }

        sessionKey = AirChatCrypto.deriveSessionKey(
            sharedSecret: sharedSecret,
            deviceIdA: localIdentity.deviceId,
            deviceIdB: hello.deviceId,
            publicKeyA: localIdentity.publicKeyBytes,
            publicKeyB: hello.publicKey
        )
        // Identity-only on purpose: two concurrent handshakes with the same peer must not produce two
        // different codes. See AirChatCrypto.safetyNumber.
        safetyCode = AirChatCrypto.safetyNumber(
            deviceIdA: localIdentity.deviceId,
            deviceIdB: hello.deviceId,
            publicKeyA: localIdentity.publicKeyBytes,
            publicKeyB: hello.publicKey
        )
        state = .ready
        // The handshake nonces are logged so a session can be identified in the logs; they no longer
        // take part in the safety code.
        let initiatorNonce = isInitiator ? myHelloNonce : hello.helloNonce
        let responderNonce = isInitiator ? hello.helloNonce : myHelloNonce
        logger.log(
            "LinkSession",
            "handshake complete with \(hello.nickname) (\(hello.deviceIdHex)) "
                + "initiator=\(isInitiator) code=\(safetyCode ?? "nil") "
                + "init=\(ByteOps.toHex(initiatorNonce)) resp=\(ByteOps.toHex(responderNonce))"
        )
        listener?.onReady(session: self, peer: hello)
    }

    // -------------------------------------------------------------- outbound

    @discardableResult
    private func sendFrame(type: Int, payload: Data) -> Bool {
        guard !isTerminal else { return false }
        let encoded = FrameCodec.encode(type: type, payload: payload)
        var queued = true
        for chunk in chunker.chunk(encoded, mtu: link.mtu) {
            if !link.send(chunk, control: FrameType.isControl(type)) {
                queued = false
                break
            }
        }
        if queued { lastOutboundAtMs = clock() }
        return queued
    }

    /// Sends a public channel post. Requires a completed handshake.
    @discardableResult
    public func sendChannelPost(_ post: ChannelPost) -> Bool {
        guard isReady, let payload = MessageCodec.encodeChannelPost(post) else { return false }
        return sendFrame(type: FrameType.channelPost, payload: payload)
    }

    /// Encrypts and sends a private message. Returns the transmitted message or nil when the
    /// session is not ready.
    public func sendPrivateMessage(
        msgId: Data,
        timestampMillis: Int64,
        recipientId: Data,
        plaintext: String
    ) -> PrivateMessage? {
        guard isReady, let key = sessionKey else { return nil }
        let textBytes = Data(plaintext.utf8)
        guard textBytes.count <= AirChatProtocol.maxTextBytes else { return nil }

        let nonce = AirChatCrypto.randomNonce()
        let aad = AirChatCrypto.privateMessageAad(
            msgId: msgId,
            senderId: localIdentity.deviceId,
            recipientId: recipientId
        )
        guard let ciphertext = AirChatCrypto.seal(key: key, nonce: nonce, plaintext: textBytes, aad: aad) else {
            return nil
        }
        guard let message = try? PrivateMessage(
            msgId: msgId,
            timestampMillis: timestampMillis,
            senderId: localIdentity.deviceId,
            recipientId: recipientId,
            nonce: nonce,
            ciphertext: ciphertext
        ) else { return nil }

        guard let payload = MessageCodec.encodePrivateMessage(message) else { return nil }
        return sendFrame(type: FrameType.privateMsg, payload: payload) ? message : nil
    }

    @discardableResult
    public func sendDeliveryAck(msgId: Data, status: AckStatus) -> Bool {
        guard isReady, let ack = try? DeliveryAck(msgId: msgId, status: status) else { return false }
        return sendFrame(type: FrameType.deliveryAck, payload: MessageCodec.encodeDeliveryAck(ack))
    }

    @discardableResult
    public func sendTyping(scope: TypingScope, active: Bool, recipientId: Data) -> Bool {
        guard isReady else { return false }
        return sendFrame(
            type: FrameType.typing,
            payload: MessageCodec.encodeTyping(Typing(scope: scope, active: active, recipientId: recipientId))
        )
    }

    @discardableResult
    public func sendSyncRequest(
        sinceMinutesAgo: Int = AirChatProtocol.syncSinceMinutes,
        maxCount: Int = AirChatProtocol.syncMaxCount
    ) -> Bool {
        guard isReady else { return false }
        let request = SyncRequest(
            requesterId: localIdentity.deviceId,
            sinceMinutesAgo: sinceMinutesAgo,
            maxCount: maxCount
        )
        return sendFrame(type: FrameType.syncReq, payload: MessageCodec.encodeSyncRequest(request))
    }

    @discardableResult
    public func sendSyncResponse(posts: [ChannelPost]) -> Bool {
        guard isReady else { return false }
        guard !posts.isEmpty else { return true }
        return sendFrame(
            type: FrameType.syncResp,
            payload: MessageCodec.encodeSyncResponse(SyncResponse(posts: posts))
        )
    }

    /// Tells the peer that this device confirmed the safety code.
    @discardableResult
    public func sendKeyVerifyRequest() -> Bool {
        guard isReady else { return false }
        return sendFrame(type: FrameType.keyVerifyReq, payload: Data())
    }

    @discardableResult
    public func sendKeyVerifyResponse(accepted: Bool) -> Bool {
        guard isReady else { return false }
        return sendFrame(
            type: FrameType.keyVerifyResp,
            payload: MessageCodec.encodeKeyVerifyResponse(KeyVerifyResponse(accepted: accepted))
        )
    }

    @discardableResult
    public func ping() -> Bool {
        sendFrame(type: FrameType.ping, payload: Data())
    }

    // ----------------------------------------------------------------- state

    private func fail(_ reason: String) {
        state = .failed
        sessionKey = nil
        logger.log("LinkSession", "session failed: \(reason)")
    }

    public func markClosed() {
        state = .closed
        sessionKey = nil
        framer.reset()
    }
}
