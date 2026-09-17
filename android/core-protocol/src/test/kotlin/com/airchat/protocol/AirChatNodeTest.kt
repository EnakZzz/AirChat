package com.airchat.protocol

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

/**
 * End-to-end tests over the fake BLE transport: two (and three) real [AirChatNode] instances
 * exchanging real frames, with real crypto and real framing.
 *
 * These use real dispatchers and real time rather than a virtual clock, because the node runs
 * background collectors and a maintenance loop; polling keeps the assertions independent of
 * scheduling order.
 */
class AirChatNodeTest {

    private suspend fun awaitUntil(description: String, timeoutMs: Long = 5_000, predicate: suspend () -> Boolean) {
        val deadline = System.currentTimeMillis() + timeoutMs
        while (System.currentTimeMillis() < deadline) {
            if (predicate()) return
            delay(10)
        }
        fail("timed out after ${timeoutMs}ms waiting for: $description")
    }

    private class Harness {
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        val storeA = InMemoryChatStore()
        val storeB = InMemoryChatStore()
        val transportA = FakeTransport()
        val transportB = FakeTransport()
        val nodeA = AirChatNode(storeA, transportA, scope)
        val nodeB = AirChatNode(storeB, transportB, scope)
        var links: Pair<FakeLink, FakeLink>? = null

        suspend fun start() {
            nodeA.start()
            nodeB.start()
        }

        fun connect(mtu: Int = 185, aIsCentral: Boolean = true) {
            links = FakeBle.connect(transportA, transportB, mtu, aIsCentral)
        }

        fun shutdown() {
            scope.cancel()
        }
    }

    private fun withHarness(block: suspend (Harness) -> Unit) = runBlocking {
        val harness = Harness()
        try {
            harness.start()
            block(harness)
        } finally {
            harness.shutdown()
        }
    }

    private suspend fun Harness.awaitBothReady() = awaitUntil("both nodes have one ready link") {
        nodeA.state.value.readyLinkCount == 1 && nodeB.state.value.readyLinkCount == 1
    }

    private suspend fun Harness.awaitChannelCount(store: InMemoryChatStore, expected: Int) =
        awaitUntil("store holds $expected channel message(s), currently ${store.messageOrder.size}") {
            store.messageOrder.size == expected
        }

    @Test
    fun `two nodes handshake and exchange a channel message`() = withHarness { h ->
        h.connect(mtu = 23) // force fragmentation across the whole pipeline
        h.awaitBothReady()

        val result = h.nodeA.postChannelMessage("大家好，我是小明 👋")
        assertTrue(result is SendResult.Sent)

        h.awaitChannelCount(h.storeB, 1)
        val received = h.storeB.listMessages(AirChatProtocol.CHANNEL_CONVERSATION_ID, 10).single()
        assertEquals("大家好，我是小明 👋", received.text)
        assertEquals(MessageDirection.INCOMING, received.direction)
        assertEquals(MessageKind.CHANNEL, received.kind)
        assertEquals(h.nodeA.deviceIdHex, ByteOps.toHex(received.senderId))

        // The sender stores its own copy with status SENT (the channel is best effort).
        val mine = h.storeA.listMessages(AirChatProtocol.CHANNEL_CONVERSATION_ID, 10).single()
        assertEquals(MessageStatus.SENT, mine.status)
        assertEquals(MessageDirection.OUTGOING, mine.direction)
    }

    @Test
    fun `a replayed channel post is stored only once`() = withHarness { h ->
        h.connect()
        h.awaitBothReady()
        h.nodeA.postChannelMessage("一次性")
        h.awaitChannelCount(h.storeB, 1)

        val stored = h.storeB.listMessages(AirChatProtocol.CHANNEL_CONVERSATION_ID, 10).single()
        val replay = MessageCodec.encodeChannelPost(
            ChannelPost(
                stored.msgId,
                stored.timestampMs,
                h.nodeA.deviceIdHex.let { ByteOps.fromHex(it) },
                "小明",
                "一次性",
            ),
        )
        h.links!!.second.inject(FrameCodec.encode(FrameType.CHANNEL_POST, replay))
        delay(200)

        assertEquals("replay must be deduped by msgId", 1, h.storeB.messageOrder.size)
        assertEquals(2, h.storeB.insertCalls)
    }

    @Test
    fun `private messages are encrypted end to end and acknowledged`() = withHarness { h ->
        h.connect()
        h.awaitBothReady()

        val result = h.nodeA.sendPrivateMessage(h.nodeB.deviceIdHex, "只有你能看到 🔒")
        assertTrue(result is SendResult.Sent)

        awaitUntil("peer stored the private message") { h.storeB.messageOrder.size == 1 }
        val received = h.storeB.listMessages(h.nodeA.deviceIdHex, 10).single()
        assertEquals("只有你能看到 🔒", received.text)
        assertEquals(MessageKind.PRIVATE, received.kind)
        assertEquals(MessageDirection.INCOMING, received.direction)

        // The delivery ACK upgrades the sender's copy from SENT to DELIVERED (double check mark).
        val sentMsgId = (result as SendResult.Sent).record.msgId
        awaitUntil("sender saw the delivery ack") {
            h.storeA.getMessage(sentMsgId)?.status == MessageStatus.DELIVERED
        }
    }

    @Test
    fun `private messages to an unknown peer are rejected`() = withHarness { h ->
        h.connect()
        h.awaitBothReady()
        val result = h.nodeA.sendPrivateMessage(ByteOps.toHex(AirChatCrypto.randomDeviceId()), "hi")
        assertTrue(result is SendResult.Rejected)
    }

    @Test
    fun `confirming the safety code is stored locally and reported to the peer`() = withHarness { h ->
        h.connect()
        h.awaitBothReady()

        val codeA = h.nodeA.state.value.links.single().safetyCode
        val codeB = h.nodeB.state.value.links.single().safetyCode
        assertNotNull(codeA)
        assertEquals("both users must see the same code", codeA, codeB)

        h.nodeB.confirmSafetyCode(h.nodeA.deviceIdHex, accepted = true)
        awaitUntil("B persisted TRUSTED") {
            h.storeB.getPeer(ByteOps.fromHex(h.nodeA.deviceIdHex))?.trustState == TrustState.TRUSTED
        }
        awaitUntil("A learned that B confirmed") {
            h.nodeA.state.value.links.single().peerConfirmedTheCode
        }
        // Confirming on B must never auto-trust A's own record: trust is per-device and local.
        assertEquals(
            TrustState.UNVERIFIED,
            h.storeA.getPeer(ByteOps.fromHex(h.nodeB.deviceIdHex))?.trustState,
        )
    }

    @Test
    fun `a rejected safety code blocks outbound private messages`() = withHarness { h ->
        h.connect()
        h.awaitBothReady()

        h.nodeA.confirmSafetyCode(h.nodeB.deviceIdHex, accepted = false)
        awaitUntil("A persisted REJECTED") {
            h.storeA.getPeer(ByteOps.fromHex(h.nodeB.deviceIdHex))?.trustState == TrustState.REJECTED
        }
        val result = h.nodeA.sendPrivateMessage(h.nodeB.deviceIdHex, "should not go out")
        assertTrue(result is SendResult.Rejected)
        assertTrue((result as SendResult.Rejected).reason.contains("安全码"))
    }

    @Test
    fun `duplicate links are deduped deterministically on both sides`() = withHarness { h ->
        // Two connections at once: both nodes must converge on exactly one surviving link.
        h.connect(aIsCentral = true)
        h.connect(aIsCentral = false)

        awaitUntil("both sides settle on a single link") {
            h.nodeA.state.value.linkCount == 1 && h.nodeB.state.value.linkCount == 1
        }

        val aId = ByteOps.fromHex(h.nodeA.deviceIdHex)
        val bId = ByteOps.fromHex(h.nodeB.deviceIdHex)
        val aIsSmaller = ByteOps.compareUnsigned(aId, bId) < 0

        // Rule 5.4: the survivor is the link whose central owns the smaller deviceId, so the
        // two nodes must report exactly mirrored roles for that same link.
        val linkA = h.nodeA.state.value.links.single()
        val linkB = h.nodeB.state.value.links.single()
        assertEquals(
            "A must see the survivor as central iff A owns the smaller deviceId",
            aIsSmaller,
            linkA.isCentral,
        )
        assertEquals(
            "B must see the very same link with the opposite role",
            !aIsSmaller,
            linkB.isCentral,
        )
    }

    @Test
    fun `channel messages fan out to every ready link`() = runBlocking {
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        try {
            val storeA = InMemoryChatStore()
            val storeB = InMemoryChatStore()
            val storeC = InMemoryChatStore()
            val transportA = FakeTransport()
            val transportB = FakeTransport()
            val transportC = FakeTransport()
            val nodeA = AirChatNode(storeA, transportA, scope)
            val nodeB = AirChatNode(storeB, transportB, scope)
            val nodeC = AirChatNode(storeC, transportC, scope)
            nodeA.start(); nodeB.start(); nodeC.start()

            FakeBle.connect(transportA, transportB, 185, aIsCentral = true, labelPrefix = "ab")
            FakeBle.connect(transportA, transportC, 185, aIsCentral = false, labelPrefix = "ac")
            awaitUntil("A has two ready links") { nodeA.state.value.readyLinkCount == 2 }

            nodeA.postChannelMessage("广播给所有人")
            awaitUntil("both peers received the broadcast") {
                storeB.messageOrder.size == 1 && storeC.messageOrder.size == 1
            }
            assertEquals("广播给所有人", storeB.listMessages(AirChatProtocol.CHANNEL_CONVERSATION_ID, 5).single().text)
            assertEquals("广播给所有人", storeC.listMessages(AirChatProtocol.CHANNEL_CONVERSATION_ID, 5).single().text)

            // A's own copy is stored once, not once per link.
            assertEquals(1, storeA.messageOrder.size)
        } finally {
            scope.cancel()
        }
    }

    @Test
    fun `a newly connected peer backfills channel history via SYNC`() = runBlocking {
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        try {
            val storeA = InMemoryChatStore()
            val storeB = InMemoryChatStore()
            val transportA = FakeTransport()
            val transportB = FakeTransport()
            val nodeA = AirChatNode(storeA, transportA, scope)
            val nodeB = AirChatNode(storeB, transportB, scope)
            nodeA.start(); nodeB.start()

            // A posts while alone: stored locally, marked FAILED because nothing was reachable.
            nodeA.postChannelMessage("离线时写的 1")
            nodeA.postChannelMessage("离线时写的 2")
            awaitUntil("A stored both messages") { storeA.messageOrder.size == 2 }

            FakeBle.connect(transportA, transportB)
            awaitUntil("B backfilled the history") { storeB.messageOrder.size == 2 }

            val texts = storeB.listMessages(AirChatProtocol.CHANNEL_CONVERSATION_ID, 10).map { it.text }
            assertEquals(listOf("离线时写的 1", "离线时写的 2"), texts)
        } finally {
            scope.cancel()
        }
    }

    @Test
    fun `empty and oversized channel messages are rejected`() = withHarness { h ->
        h.connect()
        h.awaitBothReady()

        assertTrue(h.nodeA.postChannelMessage("   ") is SendResult.Rejected)
        assertTrue(h.nodeA.postChannelMessage("x".repeat(AirChatProtocol.MAX_TEXT_CHARS + 1)) is SendResult.Rejected)
        assertTrue(h.nodeA.postChannelMessage("👋".repeat(4000)) is SendResult.Rejected)
        assertEquals(0, h.storeA.messageOrder.size)
    }

    @Test
    fun `nickname changes are persisted and advertised in later posts`() = withHarness { h ->
        h.connect()
        h.awaitBothReady()

        h.nodeA.setNickname("阿明")
        awaitUntil("nickname is published") { h.nodeA.state.value.nickname == "阿明" }
        assertEquals("阿明", h.storeA.loadIdentity()?.nickname)

        h.nodeA.postChannelMessage("换了昵称")
        awaitUntil("peer received it") { h.storeB.messageOrder.size == 1 }
        assertEquals("阿明", h.storeB.getPeer(ByteOps.fromHex(h.nodeA.deviceIdHex))?.nickname)
    }

    @Test
    fun `a disconnect removes the link and the node keeps running`() = withHarness { h ->
        h.connect()
        h.awaitBothReady()
        val linkA = h.links!!.first
        linkA.close()

        awaitUntil("both sides dropped the link") {
            h.nodeA.state.value.linkCount == 0 && h.nodeB.state.value.linkCount == 0
        }

        // Transport-owned status is surfaced verbatim so the UI can explain the situation.
        h.transportA.reportStatus(ChatStatus.NEARBY_FULL, "附近人数已满")
        awaitUntil("status propagates to the node state") {
            h.nodeA.state.value.status == ChatStatus.NEARBY_FULL
        }
        assertEquals("附近人数已满", h.nodeA.state.value.statusMessage)

        // The node must still accept local writes after the link disappears.
        val result = h.nodeA.postChannelMessage("断线后仍可本地记录")
        assertTrue(result is SendResult.Sent)
        assertEquals(MessageStatus.FAILED, (result as SendResult.Sent).record.status)
    }

    @Test
    fun `identity is generated once and reused across restarts`() = runBlocking {
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        try {
            val store = InMemoryChatStore()
            val first = AirChatNode(store, FakeTransport(), scope)
            first.start()
            val firstId = first.deviceIdHex
            assertTrue(firstId.isNotEmpty())
            assertNotNull(store.loadIdentity())
            val publicKey = AirIdentityPersistenceProbe.publicKeyOf(store)

            val second = AirChatNode(store, FakeTransport(), scope)
            second.start()
            assertEquals("identity must be stable across restarts", firstId, second.deviceIdHex)
            assertEquals(publicKey, AirIdentityPersistenceProbe.publicKeyOf(store))
        } finally {
            scope.cancel()
        }
    }
}

/** Helper that reloads the persisted identity to prove the stored key pair round-trips. */
object AirIdentityPersistenceProbe {
    fun publicKeyOf(store: InMemoryChatStore): String = runBlocking {
        val record = store.loadIdentity()!!
        ByteOps.toHex(LocalIdentity.fromRecord(record).publicKeyBytes)
    }
}
