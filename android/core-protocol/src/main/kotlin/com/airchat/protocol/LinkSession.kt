package com.airchat.protocol

/** Why a link session stopped being usable. */
enum class SessionState {
    /** Created, handshake not started. */
    NEW,

    /** HELLO sent or awaited. */
    HANDSHAKING,

    /** Session key derived; data frames may flow. */
    READY,

    /** Handshake or framing failed; the link must be closed. */
    FAILED,

    CLOSED,
}

/** A decrypted (or undecryptable) private message handed to the node layer. */
class ReceivedPrivateMessage(val message: PrivateMessage, val plaintext: String?) {
    val decrypted: Boolean get() = plaintext != null
}

/** Per-link callbacks. All are invoked synchronously on the caller's thread. */
interface LinkSessionListener {
    fun onReady(session: LinkSession, peer: Hello)
    fun onChannelPost(session: LinkSession, post: ChannelPost)
    fun onPrivateMessage(session: LinkSession, received: ReceivedPrivateMessage)
    fun onDeliveryAck(session: LinkSession, ack: DeliveryAck)
    fun onTyping(session: LinkSession, typing: Typing)
    fun onSyncRequest(session: LinkSession, request: SyncRequest)
    fun onSyncResponse(session: LinkSession, response: SyncResponse)
    fun onKeyVerifyRequest(session: LinkSession)
    fun onKeyVerifyResponse(session: LinkSession, accepted: Boolean)
    fun onFailed(session: LinkSession, reason: String)
}

/**
 * The per-link protocol state machine: handshake, session-key derivation, safety number and
 * validation of every inbound frame.
 *
 * Deliberately synchronous and free of coroutines. BLE callbacks are funnelled onto a single
 * thread by the transport, and the node layer takes care of any asynchronous work (storage)
 * from inside the callbacks. Sends are non-blocking and return false when the link is gone.
 *
 * Validation rules come from docs/protocol.md section 9. A frame that fails validation is
 * dropped without disturbing the link; only framing errors ([FatalReason]) or a handshake
 * failure tear the link down.
 */
class LinkSession(
    val link: Link,
    private val localIdentity: LocalIdentity,
    private val nicknameProvider: () -> String,
    private val capabilities: Int,
    private val listener: LinkSessionListener,
    private val clock: () -> Long = System::currentTimeMillis,
    private val logger: AirChatLogger = AirChatLogger.NOOP,
) {
    private val framer = StreamFramer()
    private val chunker = StreamChunker()
    private val myHelloNonce = AirChatCrypto.randomBytes(AirChatProtocol.HELLO_NONCE_BYTES)

    var state: SessionState = SessionState.NEW
        private set

    /** Peer identity as announced in HELLO / HELLO_ACK. */
    var peer: Hello? = null
        private set

    /** Derived session key; null until the handshake completes. */
    var sessionKey: ByteArray? = null
        private set

    /** 6-digit safety number that both sides must display identically. */
    var safetyCode: String? = null
        private set

    var lastInboundAtMs: Long = 0L
        private set

    var lastOutboundAtMs: Long = 0L
        private set

    val isReady: Boolean get() = state == SessionState.READY

    val isTerminal: Boolean get() = state == SessionState.FAILED || state == SessionState.CLOSED

    val peerDeviceIdHex: String? get() = peer?.let { ByteOps.toHex(it.deviceId) }

    /** Initiator = the GATT central, which is the side that speaks first (protocol section 8.1). */
    val isInitiator: Boolean get() = link.isCentral

    /**
     * Starts the handshake. Only the initiator acts; a peripheral waits for the inbound HELLO
     * before replying with HELLO_ACK.
     */
    fun start() {
        if (state != SessionState.NEW) return
        state = SessionState.HANDSHAKING
        if (link.isCentral) sendHello(FrameType.HELLO)
    }

    // -------------------------------------------------------------- inbound

    fun onBytes(bytes: ByteArray, offset: Int = 0, length: Int = bytes.size) {
        if (isTerminal) return
        lastInboundAtMs = clock()
        logger.log(TAG, "inbound $length byte(s) on link ${link.linkId}")
        when (val outcome = framer.push(bytes, offset, length)) {
            is FramingOutcome.Fatal -> {
                fail("framing error: ${outcome.message}")
                listener.onFailed(this, outcome.message)
            }

            is FramingOutcome.Frames -> {
                for (frame in outcome.frames) {
                    if (isTerminal) return
                    handleFrame(frame)
                }
            }
        }
    }

    private fun handleFrame(frame: Frame) {
        when (frame.type) {
            FrameType.HELLO, FrameType.HELLO_ACK -> {
                val hello = MessageCodec.decodeHello(frame.payload)
                if (hello == null) {
                    logger.log(TAG, "dropping malformed HELLO from ${link.peerLabel}")
                    return
                }
                if (frame.type == FrameType.HELLO) sendHello(FrameType.HELLO_ACK)
                completeHandshake(hello)
            }

            FrameType.PING -> sendFrame(FrameType.PONG, ByteArray(0))

            FrameType.PONG -> Unit

            FrameType.CHANNEL_POST -> {
                val post = MessageCodec.decodeChannelPost(frame.payload)
                if (post == null) {
                    logger.log(TAG, "dropping malformed CHANNEL_POST")
                    return
                }
                // Protocol section 9 rule 4: single-hop, so the sender must be the connected peer.
                if (!matchesPeer(post.senderId)) {
                    logger.log(TAG, "dropping CHANNEL_POST with spoofed senderId")
                    return
                }
                listener.onChannelPost(this, post)
            }

            FrameType.PRIVATE_MSG -> {
                val message = MessageCodec.decodePrivateMessage(frame.payload)
                if (message == null) {
                    logger.log(TAG, "dropping malformed PRIVATE_MSG")
                    return
                }
                if (!matchesPeer(message.senderId) || !message.recipientId.contentEquals(localIdentity.deviceId)) {
                    logger.log(TAG, "dropping PRIVATE_MSG addressed elsewhere")
                    return
                }
                listener.onPrivateMessage(this, ReceivedPrivateMessage(message, decrypt(message)))
            }

            FrameType.DELIVERY_ACK -> {
                val ack = MessageCodec.decodeDeliveryAck(frame.payload)
                if (ack == null) {
                    logger.log(TAG, "dropping malformed DELIVERY_ACK")
                    return
                }
                listener.onDeliveryAck(this, ack)
            }

            FrameType.TYPING -> {
                val typing = MessageCodec.decodeTyping(frame.payload)
                if (typing == null) {
                    logger.log(TAG, "dropping malformed TYPING")
                    return
                }
                listener.onTyping(this, typing)
            }

            FrameType.SYNC_REQ -> {
                val request = MessageCodec.decodeSyncRequest(frame.payload)
                if (request == null || !matchesPeer(request.requesterId)) {
                    logger.log(TAG, "dropping SYNC_REQ with spoofed requesterId")
                    return
                }
                listener.onSyncRequest(this, request)
            }

            FrameType.SYNC_RESP -> {
                val response = MessageCodec.decodeSyncResponse(frame.payload)
                if (response == null) {
                    logger.log(TAG, "dropping malformed SYNC_RESP")
                    return
                }
                // Entries must originate from the connected peer; anything else is dropped.
                listener.onSyncResponse(this, SyncResponse(response.posts.filter { matchesPeer(it.senderId) }))
            }

            FrameType.KEY_VERIFY_REQ -> {
                // The peer confirmed the safety code locally. We record their claim, answer with
                // our own state, and never trust ourselves on their behalf (protocol section 10.3).
                listener.onKeyVerifyRequest(this)
                sendKeyVerifyResponse(verifiedLocally)
            }

            FrameType.KEY_VERIFY_RESP -> {
                val response = MessageCodec.decodeKeyVerifyResponse(frame.payload)
                if (response == null) {
                    logger.log(TAG, "dropping malformed KEY_VERIFY_RESP")
                    return
                }
                listener.onKeyVerifyResponse(this, response.accepted)
            }

            else -> {
                // Layering contract: the framer surfaces unknown types, the session drops them.
                logger.log(TAG, "ignoring unknown frame type 0x%02x".format(frame.type))
            }
        }
    }

    private fun matchesPeer(deviceId: ByteArray): Boolean =
        peer?.deviceId?.contentEquals(deviceId) ?: false

    private fun decrypt(message: PrivateMessage): String? {
        if (!isReady) return null
        val key = sessionKey ?: return null
        val plaintext = AirChatCrypto.open(
            key,
            message.nonce,
            message.ciphertext,
            AirChatCrypto.privateMessageAad(message.msgId, message.senderId, message.recipientId),
        ) ?: return null
        return plaintext.toString(Charsets.UTF_8)
    }

    // --------------------------------------------------------- handshake

    private fun sendHello(type: Int) {
        val hello = Hello(
            protocolVersion = AirChatProtocol.VERSION,
            deviceId = localIdentity.deviceId,
            nickname = nicknameProvider(),
            publicKey = localIdentity.publicKeyBytes,
            capabilities = capabilities,
            helloNonce = myHelloNonce,
        )
        sendFrame(type, MessageCodec.encodeHello(hello))
    }

    private fun completeHandshake(hello: Hello) {
        if (state == SessionState.READY) return
        if (hello.protocolVersion != AirChatProtocol.VERSION) {
            val reason = "peer speaks protocol v${hello.protocolVersion}, we speak v${AirChatProtocol.VERSION}"
            fail(reason)
            listener.onFailed(this, reason)
            return
        }

        val peerKey = runCatching { AirChatCrypto.decodePublicKey(hello.publicKey) }.getOrNull()
        if (peerKey == null) {
            val reason = "peer sent an invalid public key"
            fail(reason)
            listener.onFailed(this, reason)
            return
        }

        peer = hello
        val sharedSecret = AirChatCrypto.ecdh(localIdentity.privateKey, peerKey)
        sessionKey = AirChatCrypto.deriveSessionKey(
            sharedSecret,
            localIdentity.deviceId,
            hello.deviceId,
            localIdentity.publicKeyBytes,
            hello.publicKey,
        )
        safetyCode = AirChatCrypto.safetyNumber(
            localIdentity.deviceId,
            hello.deviceId,
            localIdentity.publicKeyBytes,
            hello.publicKey,
            // The initiator always contributes the first nonce, whichever side we are.
            initiatorHelloNonce = if (isInitiator) myHelloNonce else hello.helloNonce,
            responderHelloNonce = if (isInitiator) hello.helloNonce else myHelloNonce,
        )
        state = SessionState.READY
        // The nonces are logged because a safety code that disagrees between two devices which
        // otherwise share a session key can only come from the two ends ordering (or holding)
        // different nonces, and nothing else in the logs would show it.
        logger.log(
            TAG,
            "handshake complete with ${hello.nickname} (${ByteOps.toHex(hello.deviceId)}) " +
                "initiator=$isInitiator code=$safetyCode " +
                "init=${ByteOps.toHex(if (isInitiator) myHelloNonce else hello.helloNonce)} " +
                "resp=${ByteOps.toHex(if (isInitiator) hello.helloNonce else myHelloNonce)}",
        )
        listener.onReady(this, hello)
    }

    // ------------------------------------------------------------ outbound

    private fun sendFrame(type: Int, payload: ByteArray): Boolean {
        if (isTerminal) return false
        val encoded = FrameCodec.encode(type, payload)
        var queued = true
        for (chunk in chunker.chunk(encoded, link.mtu)) {
            if (!link.send(chunk, FrameType.isControl(type))) {
                queued = false
                break
            }
        }
        if (queued) lastOutboundAtMs = clock()
        return queued
    }

    /** Sends a public channel post. Requires a completed handshake. */
    fun sendChannelPost(post: ChannelPost): Boolean {
        if (!isReady) return false
        return sendFrame(FrameType.CHANNEL_POST, MessageCodec.encodeChannelPost(post))
    }

    /**
     * Encrypts and sends a private message. Returns the transmitted message (so the caller can
     * record the nonce/ciphertext) or null when the session is not ready.
     */
    fun sendPrivateMessage(
        msgId: ByteArray,
        timestampMillis: Long,
        recipientId: ByteArray,
        plaintext: String,
    ): PrivateMessage? {
        if (!isReady) return null
        val key = sessionKey ?: return null
        val textBytes = plaintext.toByteArray(Charsets.UTF_8)
        if (textBytes.size > AirChatProtocol.MAX_TEXT_BYTES) return null

        val nonce = AirChatCrypto.randomNonce()
        val aad = AirChatCrypto.privateMessageAad(msgId, localIdentity.deviceId, recipientId)
        val ciphertext = AirChatCrypto.seal(key, nonce, textBytes, aad)
        val message = PrivateMessage(
            msgId = msgId,
            timestampMillis = timestampMillis,
            senderId = localIdentity.deviceId,
            recipientId = recipientId,
            nonce = nonce,
            ciphertext = ciphertext,
        )
        return if (sendFrame(FrameType.PRIVATE_MSG, MessageCodec.encodePrivateMessage(message))) message else null
    }

    fun sendDeliveryAck(msgId: ByteArray, status: AckStatus): Boolean {
        if (!isReady) return false
        return sendFrame(FrameType.DELIVERY_ACK, MessageCodec.encodeDeliveryAck(DeliveryAck(msgId, status)))
    }

    fun sendTyping(scope: TypingScope, active: Boolean, recipientId: ByteArray): Boolean {
        if (!isReady) return false
        return sendFrame(FrameType.TYPING, MessageCodec.encodeTyping(Typing(scope, active, recipientId)))
    }

    fun sendSyncRequest(sinceMinutesAgo: Int = AirChatProtocol.SYNC_SINCE_MINUTES, maxCount: Int = AirChatProtocol.SYNC_MAX_COUNT): Boolean {
        if (!isReady) return false
        val request = SyncRequest(localIdentity.deviceId, sinceMinutesAgo, maxCount)
        return sendFrame(FrameType.SYNC_REQ, MessageCodec.encodeSyncRequest(request))
    }

    fun sendSyncResponse(posts: List<ChannelPost>): Boolean {
        if (!isReady) return false
        if (posts.isEmpty()) return true
        return sendFrame(FrameType.SYNC_RESP, MessageCodec.encodeSyncResponse(SyncResponse(posts)))
    }

    /** Tells the peer that this device confirmed the safety code. */
    fun sendKeyVerifyRequest(): Boolean {
        if (!isReady) return false
        return sendFrame(FrameType.KEY_VERIFY_REQ, ByteArray(0))
    }

    fun sendKeyVerifyResponse(accepted: Boolean): Boolean {
        if (!isReady) return false
        return sendFrame(FrameType.KEY_VERIFY_RESP, MessageCodec.encodeKeyVerifyResponse(KeyVerifyResponse(accepted)))
    }

    fun ping(): Boolean = sendFrame(FrameType.PING, ByteArray(0))

    // --------------------------------------------------------------- state

    /**
     * Whether the local user has confirmed this peer's safety code. Supplied by the node layer
     * so a KEY_VERIFY_REQ from the peer can be answered with our own real state.
     */
    var verifiedLocally: Boolean = false

    private fun fail(reason: String) {
        state = SessionState.FAILED
        sessionKey = null
        logger.log(TAG, "session failed: $reason")
    }

    fun markClosed() {
        state = SessionState.CLOSED
        sessionKey = null
        framer.reset()
    }

    private companion object {
        const val TAG = "LinkSession"
    }
}
