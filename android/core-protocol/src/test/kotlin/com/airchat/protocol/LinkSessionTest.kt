package com.airchat.protocol

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Records everything a [LinkSession] reports. */
class RecordingSessionListener : LinkSessionListener {
    val ready = mutableListOf<Pair<String, String>>() // peer deviceId -> safety code
    val channelPosts = mutableListOf<ChannelPost>()
    val privateMessages = mutableListOf<ReceivedPrivateMessage>()
    val acks = mutableListOf<DeliveryAck>()
    val typing = mutableListOf<Typing>()
    val syncRequests = mutableListOf<SyncRequest>()
    val syncResponses = mutableListOf<SyncResponse>()
    var keyVerifyRequests = 0
    val keyVerifyResponses = mutableListOf<Boolean>()
    val failures = mutableListOf<String>()

    override fun onReady(session: LinkSession, peer: Hello) {
        ready += ByteOps.toHex(peer.deviceId) to (session.safetyCode ?: "")
    }

    override fun onChannelPost(session: LinkSession, post: ChannelPost) {
        channelPosts += post
    }

    override fun onPrivateMessage(session: LinkSession, received: ReceivedPrivateMessage) {
        privateMessages += received
    }

    override fun onDeliveryAck(session: LinkSession, ack: DeliveryAck) {
        acks += ack
    }

    override fun onTyping(session: LinkSession, typing: Typing) {
        this.typing += typing
    }

    override fun onSyncRequest(session: LinkSession, request: SyncRequest) {
        syncRequests += request
    }

    override fun onSyncResponse(session: LinkSession, response: SyncResponse) {
        syncResponses += response
    }

    override fun onKeyVerifyRequest(session: LinkSession) {
        keyVerifyRequests++
    }

    override fun onKeyVerifyResponse(session: LinkSession, accepted: Boolean) {
        keyVerifyResponses += accepted
    }

    override fun onFailed(session: LinkSession, reason: String) {
        failures += reason
    }
}

/** Wires two [LinkSession]s back to back over a [FakeLink] pair. */
class SessionPair(mtu: Int = 185, aIsCentral: Boolean = true, nicknameA: String = "小明", nicknameB: String = "Bob") {
    val identityA = LocalIdentity.generate()
    val identityB = LocalIdentity.generate()
    val linkA = FakeLink("link-a", aIsCentral, mtu, "peer-b")
    val linkB = FakeLink("link-b", !aIsCentral, mtu, "peer-a")
    val listenerA = RecordingSessionListener()
    val listenerB = RecordingSessionListener()

    val sessionA = LinkSession(linkA, identityA, { nicknameA }, Capabilities.ALL, listenerA)
    val sessionB = LinkSession(linkB, identityB, { nicknameB }, Capabilities.ALL, listenerB)

    init {
        linkA.peer = linkB
        linkB.peer = linkA
        linkA.setInboundHandler { bytes -> sessionA.onBytes(bytes) }
        linkB.setInboundHandler { bytes -> sessionB.onBytes(bytes) }
    }

    /**
     * Starts the handshake from the initiator, which the protocol defines as the GATT central.
     * Delivery is synchronous, so both sides are READY by the time this returns.
     */
    fun shakeHands() {
        if (sessionA.isInitiator) sessionA.start() else sessionB.start()
    }
}

class LinkSessionTest {

    @Test
    fun `handshake reaches ready on both sides with mtu-23 fragmentation`() {
        // MTU 23 gives 20-byte chunks, so the 129-byte HELLO frame is split across 7 writes.
        val pair = SessionPair(mtu = 23)
        pair.shakeHands()

        assertEquals(SessionState.READY, pair.sessionA.state)
        assertEquals(SessionState.READY, pair.sessionB.state)
        assertTrue("HELLO must have been fragmented", pair.linkA.sentChunks.size > 1)
        assertTrue("chunks must respect the MTU", pair.linkA.sentChunks.all { it.second.size <= 20 })

        val hello = pair.linkA.framesSentToPeer().first()
        assertEquals(FrameType.HELLO, hello.type)
    }

    @Test
    fun `both sides derive the same session key and safety number`() {
        val pair = SessionPair()
        pair.shakeHands()

        assertNotNull(pair.sessionA.sessionKey)
        assertNotNull(pair.sessionB.sessionKey)
        assertArrayEquals(pair.sessionA.sessionKey, pair.sessionB.sessionKey)
        assertEquals(pair.sessionA.safetyCode, pair.sessionB.safetyCode)
        assertEquals(6, pair.sessionA.safetyCode!!.length)
        assertTrue(pair.sessionA.safetyCode!!.all { it.isDigit() })

        // Both listeners must have observed the same peer ids.
        assertEquals(ByteOps.toHex(pair.identityB.deviceId), pair.listenerA.ready.single().first)
        assertEquals(ByteOps.toHex(pair.identityA.deviceId), pair.listenerB.ready.single().first)
    }

    @Test
    fun `the handshake works with either side acting as the GATT central`() {
        // Same protocol, opposite GATT roles: the responder answers the inbound HELLO with
        // HELLO_ACK, and both sides must still derive identical keys and safety numbers.
        val pair = SessionPair(aIsCentral = false)
        pair.shakeHands()

        assertEquals(SessionState.READY, pair.sessionA.state)
        assertEquals(SessionState.READY, pair.sessionB.state)
        assertArrayEquals(pair.sessionA.sessionKey, pair.sessionB.sessionKey)
        assertEquals(pair.sessionA.safetyCode, pair.sessionB.safetyCode)

        // Only the central may open the handshake; a peripheral must wait for the inbound HELLO.
        assertEquals(FrameType.HELLO, pair.linkB.framesSentToPeer().first().type)
    }

    @Test
    fun `a peripheral start is a no-op until the peer speaks`() {
        val pair = SessionPair(aIsCentral = false)
        pair.sessionA.start()

        assertEquals(SessionState.HANDSHAKING, pair.sessionA.state)
        assertTrue("a peripheral must not send anything first", pair.linkA.sentChunks.isEmpty())

        // It must still complete once the peer's HELLO arrives.
        pair.sessionB.start()
        assertEquals(SessionState.READY, pair.sessionA.state)
        assertEquals(SessionState.READY, pair.sessionB.state)
    }

    @Test
    fun `a different peer yields a different session key and safety number`() {
        val first = SessionPair()
        first.shakeHands()
        val second = SessionPair()
        second.shakeHands()

        assertFalse(
            "session keys must be per-peer",
            first.sessionA.sessionKey!!.contentEquals(second.sessionA.sessionKey!!),
        )
        assertNotEquals(first.sessionA.safetyCode, second.sessionA.safetyCode)
    }

    @Test
    fun `channel posts travel with the real sender and nickname`() {
        val pair = SessionPair()
        pair.shakeHands()

        val post = ChannelPost(
            msgId = AirChatCrypto.randomMessageId(),
            timestampMillis = 1_758_000_000_000L,
            senderId = pair.identityA.deviceId,
            senderNickname = "小明",
            text = "大家好 👋",
        )
        assertTrue(pair.sessionA.sendChannelPost(post))

        val received = pair.listenerB.channelPosts.single()
        assertEquals("大家好 👋", received.text)
        assertEquals("小明", received.senderNickname)
        assertEquals(ByteOps.toHex(pair.identityA.deviceId), ByteOps.toHex(received.senderId))
    }

    @Test
    fun `channel posts with a spoofed sender id are dropped`() {
        val pair = SessionPair()
        pair.shakeHands()

        val forged = MessageCodec.encodeChannelPost(
            ChannelPost(
                msgId = AirChatCrypto.randomMessageId(),
                timestampMillis = 1L,
                senderId = AirChatCrypto.randomDeviceId(), // not the connected peer
                senderNickname = "impostor",
                text = "I am someone else",
            ),
        )
        pair.linkB.inject(FrameCodec.encode(FrameType.CHANNEL_POST, forged))

        assertTrue("spoofed post must be dropped", pair.listenerB.channelPosts.isEmpty())
        // The link must remain usable afterwards.
        assertEquals(SessionState.READY, pair.sessionB.state)
        assertTrue(
            pair.sessionB.sendChannelPost(
                ChannelPost(AirChatCrypto.randomMessageId(), 2L, pair.identityB.deviceId, "Bob", "hi"),
            ),
        )
        assertEquals(1, pair.listenerA.channelPosts.size)
    }

    @Test
    fun `private messages round-trip and are bound to ids and aad`() {
        val pair = SessionPair()
        pair.shakeHands()

        val msgId = AirChatCrypto.randomMessageId()
        val sent = pair.sessionA.sendPrivateMessage(
            msgId = msgId,
            timestampMillis = 42L,
            recipientId = pair.identityB.deviceId,
            plaintext = "只有你能看到 🔒",
        )
        assertNotNull(sent)

        val received = pair.listenerB.privateMessages.single()
        assertTrue(received.decrypted)
        assertEquals("只有你能看到 🔒", received.plaintext)
        assertEquals(ByteOps.toHex(msgId), ByteOps.toHex(received.message.msgId))
        // The ciphertext must not contain the plaintext.
        assertFalse(received.message.ciphertext.toString(Charsets.UTF_8).contains("只有你"))

        // AAD binds the ciphertext to the header fields: flipping the recipient must break it.
        val tamperedHeader = MessageCodec.encodePrivateMessage(
            PrivateMessage(
                received.message.msgId,
                received.message.timestampMillis,
                received.message.senderId,
                received.message.senderId, // wrong recipient id, same ciphertext
                received.message.nonce,
                received.message.ciphertext,
            ),
        )
        val listener = RecordingSessionListener()
        val probe = LinkSession(
            FakeLink("probe", true, 185, null),
            pair.identityB,
            { "probe" },
            Capabilities.ALL,
            listener,
        )
        probe.onBytes(FrameCodec.encode(FrameType.PRIVATE_MSG, tamperedHeader))
        assertTrue("message addressed elsewhere must be dropped", listener.privateMessages.isEmpty())
    }

    @Test
    fun `an undecryptable private message is surfaced as such`() {
        val pair = SessionPair()
        pair.shakeHands()

        val corrupted = MessageCodec.encodePrivateMessage(
            PrivateMessage(
                msgId = AirChatCrypto.randomMessageId(),
                timestampMillis = 1L,
                senderId = pair.identityA.deviceId,
                recipientId = pair.identityB.deviceId,
                nonce = AirChatCrypto.randomNonce(),
                ciphertext = ByteArray(32) { 0x5A },
            ),
        )
        pair.linkB.inject(FrameCodec.encode(FrameType.PRIVATE_MSG, corrupted))

        val received = pair.listenerB.privateMessages.single()
        assertFalse(received.decrypted)
        assertNull(received.plaintext)
    }

    @Test
    fun `delivery acks and typing survive the round trip`() {
        val pair = SessionPair()
        pair.shakeHands()

        val msgId = AirChatCrypto.randomMessageId()
        assertTrue(pair.sessionB.sendDeliveryAck(msgId, AckStatus.UNDECRYPTABLE))
        assertEquals(1, pair.listenerA.acks.size)
        assertEquals(AckStatus.UNDECRYPTABLE, pair.listenerA.acks.single().status)

        assertTrue(pair.sessionA.sendTyping(TypingScope.CHANNEL, true, ByteArray(16)))
        assertEquals(TypingScope.CHANNEL, pair.listenerB.typing.single().scope)
        assertTrue(pair.listenerB.typing.single().active)
    }

    @Test
    fun `unknown frame types are ignored without disturbing the link`() {
        val pair = SessionPair()
        pair.shakeHands()

        pair.linkB.inject(FrameCodec.encode(0x66, ByteArray(64) { 0x11 }))
        assertEquals(SessionState.READY, pair.sessionB.state)
        assertTrue(pair.listenerB.failures.isEmpty())

        // A known frame after the unknown one must still be delivered.
        assertTrue(
            pair.sessionA.sendChannelPost(
                ChannelPost(AirChatCrypto.randomMessageId(), 5L, pair.identityA.deviceId, "小明", "after"),
            ),
        )
        assertEquals("after", pair.listenerB.channelPosts.single().text)
    }

    @Test
    fun `sync request and response flow through the session`() {
        val pair = SessionPair()
        pair.shakeHands()

        assertTrue(pair.sessionA.sendSyncRequest(sinceMinutesAgo = 10, maxCount = 50))
        val request = pair.listenerB.syncRequests.single()
        assertEquals(10, request.sinceMinutesAgo)
        assertEquals(ByteOps.toHex(pair.identityA.deviceId), ByteOps.toHex(request.requesterId))

        val posts = listOf(
            ChannelPost(AirChatCrypto.randomMessageId(), 1L, pair.identityA.deviceId, "小明", "历史 1"),
            ChannelPost(AirChatCrypto.randomMessageId(), 2L, pair.identityA.deviceId, "小明", "历史 2"),
        )
        assertTrue(pair.sessionA.sendSyncResponse(posts))
        val response = pair.listenerB.syncResponses.single()
        assertEquals(2, response.posts.size)
        assertEquals("历史 1", response.posts[0].text)
    }

    @Test
    fun `sync response entries from third parties are filtered out`() {
        val pair = SessionPair()
        pair.shakeHands()

        // sessionA's peer is B, so only posts attributed to B may be relayed to A.
        val forgedPayload = MessageCodec.encodeSyncResponse(
            SyncResponse(
                listOf(
                    ChannelPost(AirChatCrypto.randomMessageId(), 1L, pair.identityB.deviceId, "Bob", "legit"),
                    ChannelPost(AirChatCrypto.randomMessageId(), 2L, AirChatCrypto.randomDeviceId(), "ghost", "forged"),
                ),
            ),
        )
        pair.linkA.inject(FrameCodec.encode(FrameType.SYNC_RESP, forgedPayload))

        val response = pair.listenerA.syncResponses.single()
        assertEquals("only the peer's own posts may be relayed", 1, response.posts.size)
        assertEquals("legit", response.posts.single().text)
    }

    @Test
    fun `key verification is exchanged but never auto-trusts the peer`() {
        val pair = SessionPair()
        pair.shakeHands()

        assertTrue(pair.sessionA.sendKeyVerifyRequest())
        assertEquals(1, pair.listenerB.keyVerifyRequests)
        // The responder answers with its own local state, which defaults to unverified.
        assertEquals(listOf(false), pair.listenerA.keyVerifyResponses)
    }

    @Test
    fun `a version mismatch fails the handshake`() {
        val pair = SessionPair()
        val foreignHello = MessageCodec.encodeHello(
            Hello(
                protocolVersion = 2,
                deviceId = pair.identityB.deviceId,
                nickname = "future",
                publicKey = pair.identityB.publicKeyBytes,
                capabilities = Capabilities.ALL,
                helloNonce = AirChatCrypto.randomBytes(8),
            ),
        )
        pair.linkA.inject(FrameCodec.encode(FrameType.HELLO, foreignHello))

        assertEquals(SessionState.FAILED, pair.sessionA.state)
        assertEquals(1, pair.listenerA.failures.size)
        assertNull(pair.sessionA.sessionKey)
    }

    @Test
    fun `a framing error tears the link down`() {
        val pair = SessionPair()
        pair.shakeHands()

        pair.linkA.inject(byteArrayOf(2, FrameType.PING.toByte(), 0, 0))
        assertEquals(SessionState.FAILED, pair.sessionA.state)
        assertTrue(pair.listenerA.failures.single().contains("version"))
    }

    @Test
    fun `data frames are refused before the handshake completes and after it fails`() {
        val pair = SessionPair()
        assertFalse(pair.sessionA.sendChannelPost(
            ChannelPost(AirChatCrypto.randomMessageId(), 1L, pair.identityA.deviceId, "小明", "too early"),
        ))
        assertNull(pair.sessionA.sendPrivateMessage(
            AirChatCrypto.randomMessageId(), 1L, pair.identityB.deviceId, "too early",
        ))

        pair.shakeHands()
        assertTrue(pair.sessionA.isReady)

        pair.linkA.inject(byteArrayOf(2, FrameType.PING.toByte(), 0, 0))
        assertFalse(pair.sessionA.sendChannelPost(
            ChannelPost(AirChatCrypto.randomMessageId(), 1L, pair.identityA.deviceId, "小明", "too late"),
        ))
    }

    @Test
    fun `oversized private messages are refused`() {
        val pair = SessionPair()
        pair.shakeHands()
        val tooLong = "x".repeat(AirChatProtocol.MAX_TEXT_BYTES + 1)
        assertNull(pair.sessionA.sendPrivateMessage(
            AirChatCrypto.randomMessageId(), 1L, pair.identityB.deviceId, tooLong,
        ))
    }

    @Test
    fun `a closed session refuses all sends`() {
        val pair = SessionPair()
        pair.shakeHands()
        pair.sessionA.markClosed()
        assertFalse(pair.sessionA.sendChannelPost(
            ChannelPost(AirChatCrypto.randomMessageId(), 1L, pair.identityA.deviceId, "小明", "after close"),
        ))
        assertFalse(pair.sessionA.ping())
    }

    @Test
    fun `ping is answered with pong`() {
        val pair = SessionPair()
        pair.shakeHands()
        val before = pair.linkA.sentChunks.size
        assertTrue(pair.sessionA.ping())
        // B answers with PONG, which arrives back at A as extra outbound traffic.
        val types = pair.linkB.framesSentToPeer().map { it.type }
        assertTrue("expected a PONG from the responder", types.contains(FrameType.PONG))
        assertTrue(pair.linkA.sentChunks.size > before)
        assertEquals(SessionState.READY, pair.sessionA.state)
    }
}
