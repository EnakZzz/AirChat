package com.airchat.protocol

import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Frame encode/decode and stream reassembly, driven by the shared `testdata/frames.json`.
 *
 * These cases are what prove the "MTU-independent byte stream" contract: the same frames must
 * survive being split at 20, 182 and 512 byte boundaries and being concatenated together.
 */
class FramingVectorsTest {

    private val vectors = TestVectors.load("frames.json")

    private fun constants() = vectors["constants"]!!.jsonObject

    @Test
    fun `constants match the protocol module`() {
        val c = constants()
        assertEquals(AirChatProtocol.VERSION, TestVectors.int(c["protocolVersion"]!!))
        assertEquals(AirChatProtocol.MAX_PAYLOAD_BYTES, TestVectors.int(c["maxPayloadBytes"]!!))
        assertEquals(AirChatProtocol.MAX_CHUNK_BYTES, TestVectors.int(c["maxChunkBytes"]!!))
        assertEquals(AirChatProtocol.MAX_NICKNAME_BYTES, TestVectors.int(c["maxNicknameBytes"]!!))
        assertEquals(AirChatProtocol.MAX_TEXT_BYTES, TestVectors.int(c["maxTextBytes"]!!))
        assertEquals(AirChatProtocol.MAX_LINKS, TestVectors.int(c["maxLinks"]!!))
    }

    @Test
    fun `frame encoding matches the vectors`() {
        val encodes = vectors["encodes"]!!.jsonArray
        assertTrue("expected the full v1 message set", encodes.size >= 11)
        for (entry in encodes) {
            val obj = entry.jsonObject
            val name = obj["name"]!!.jsonPrimitive.content
            val type = TestVectors.int(obj["type"]!!)
            val payload = TestVectors.hex(obj["payloadHex"]!!)
            val expectedFrame = obj["frameHex"]!!.jsonPrimitive.content
            val expectedLength = TestVectors.int(obj["expectedPayloadLength"]!!)

            assertEquals("$name payload length", expectedLength, payload.size)
            assertEquals("$name encoded frame", expectedFrame, ByteOps.toHex(FrameCodec.encode(type, payload)))
        }
    }

    @Test
    fun `message payloads round-trip through the codec`() {
        for (entry in vectors["encodes"]!!.jsonArray) {
            val obj = entry.jsonObject
            val name = obj["name"]!!.jsonPrimitive.content
            val type = TestVectors.int(obj["type"]!!)
            val payload = TestVectors.hex(obj["payloadHex"]!!)
            val reencoded = encodeThroughModel(type, payload)
            if (reencoded == null) {
                assertEquals("$name has no payload model", 0, payload.size)
            } else {
                assertEquals("$name payload round-trip", ByteOps.toHex(payload), ByteOps.toHex(reencoded))
            }
        }
    }

    private fun encodeThroughModel(type: Int, payload: ByteArray): ByteArray? = when (type) {
        FrameType.HELLO, FrameType.HELLO_ACK -> MessageCodec.decodeHello(payload)?.let(MessageCodec::encodeHello)
        FrameType.CHANNEL_POST -> MessageCodec.decodeChannelPost(payload)?.let(MessageCodec::encodeChannelPost)
        FrameType.PRIVATE_MSG -> MessageCodec.decodePrivateMessage(payload)?.let(MessageCodec::encodePrivateMessage)
        FrameType.DELIVERY_ACK -> MessageCodec.decodeDeliveryAck(payload)?.let(MessageCodec::encodeDeliveryAck)
        FrameType.TYPING -> MessageCodec.decodeTyping(payload)?.let(MessageCodec::encodeTyping)
        FrameType.SYNC_REQ -> MessageCodec.decodeSyncRequest(payload)?.let(MessageCodec::encodeSyncRequest)
        FrameType.KEY_VERIFY_RESP -> MessageCodec.decodeKeyVerifyResponse(payload)
            ?.let(MessageCodec::encodeKeyVerifyResponse)
        FrameType.PING, FrameType.PONG, FrameType.KEY_VERIFY_REQ -> payload.takeIf { it.isEmpty() }
        else -> null
    }

    @Test
    fun `stream reassembly matches every vector case`() {
        for (case in vectors["streamCases"]!!.jsonArray) {
            val obj = case.jsonObject
            val name = obj["name"]!!.jsonPrimitive.content
            val chunks = obj["inputChunksHex"]!!.jsonArray.map { ByteOps.fromHex(it.jsonPrimitive.content) }
            val expectedFrames = obj["expectedFrames"]!!.jsonArray.map {
                val frame = it.jsonObject
                Frame(TestVectors.int(frame["type"]!!), TestVectors.hex(frame["payloadHex"]!!))
            }
            val expectFatal = obj["expectedFatal"]!!.jsonPrimitive.content.toBoolean()

            val framer = StreamFramer()
            val collected = mutableListOf<Frame>()
            var fatal: FramingOutcome.Fatal? = null
            for (chunk in chunks) {
                when (val outcome = framer.push(chunk)) {
                    is FramingOutcome.Frames -> collected += outcome.frames
                    is FramingOutcome.Fatal -> {
                        fatal = outcome
                        break
                    }
                }
            }

            assertEquals("$name fatal", expectFatal, fatal != null)
            assertEquals("$name frame count", expectedFrames.size, collected.size)
            expectedFrames.forEachIndexed { index, expected ->
                assertEquals("$name frame[$index] type", expected.type, collected[index].type)
                assertEquals(
                    "$name frame[$index] payload",
                    ByteOps.toHex(expected.payload),
                    ByteOps.toHex(collected[index].payload),
                )
            }
            if (expectFatal) {
                assertEquals("$name must clear its buffer", 0, framer.bufferedBytes)
            }
        }
    }

    @Test
    fun `chunk sizes follow mtu minus three capped at the protocol maximum`() {
        val chunker = StreamChunker()
        assertEquals(20, chunker.chunkSizeFor(23))
        assertEquals(182, chunker.chunkSizeFor(185))
        assertEquals(AirChatProtocol.MAX_CHUNK_BYTES, chunker.chunkSizeFor(517))
        // An unknown or zero MTU falls back to the BLE minimum ATT MTU (23 -> 20 bytes).
        assertEquals(20, chunker.chunkSizeFor(0))
        assertEquals(20, chunker.chunkSizeFor(-5))
        // A degenerately small MTU still yields a usable, non-zero chunk.
        assertEquals(1, chunker.chunkSizeFor(4))
    }

    @Test
    fun `chunking a large frame at mtu 20 reassembles to the original`() {
        val payload = ByteArray(1000) { (it % 251).toByte() }
        val encoded = FrameCodec.encode(FrameType.CHANNEL_POST, payload)
        val chunker = StreamChunker()

        for (mtu in intArrayOf(23, 185, 517)) {
            val chunks = chunker.chunk(encoded, mtu)
            assertTrue("mtu $mtu should split", chunks.size >= 1)
            val framer = StreamFramer()
            val frames = mutableListOf<Frame>()
            for (chunk in chunks) {
                val outcome = framer.push(chunk)
                assertTrue("mtu $mtu chunking must not be fatal", outcome is FramingOutcome.Frames)
                frames += (outcome as FramingOutcome.Frames).frames
            }
            assertEquals("mtu $mtu frame count", 1, frames.size)
            assertEquals("mtu $mtu payload", ByteOps.toHex(payload), ByteOps.toHex(frames[0].payload))
        }
    }

    @Test
    fun `framer keeps unknown types but does not break on them`() {
        // Layering contract: the framer is a pure byte-stream parser. It surfaces every frame
        // it can delimit - including types it does not know - so the session layer owns the
        // policy decision to drop them. Crucially it must never desynchronise.
        val unknown = FrameCodec.encode(0x42, ByteArray(16) { 0x7F })
        val known = FrameCodec.encode(FrameType.PING, ByteArray(0))
        val framer = StreamFramer()
        val outcome = framer.push(ByteOps.concat(unknown, known)) as FramingOutcome.Frames
        assertEquals(2, outcome.frames.size)
        assertEquals(0x42, outcome.frames[0].type)
        assertEquals(FrameType.PING, outcome.frames[1].type)
        assertEquals(0, framer.bufferedBytes)
    }

    @Test
    fun `oversize payload is fatal and clears the buffer`() {
        val header = byteArrayOf(
            AirChatProtocol.VERSION.toByte(),
            FrameType.CHANNEL_POST.toByte(),
            ((AirChatProtocol.MAX_PAYLOAD_BYTES + 1) ushr 8).toByte(),
            ((AirChatProtocol.MAX_PAYLOAD_BYTES + 1) and 0xFF).toByte(),
        )
        val outcome = StreamFramer().push(header)
        assertTrue(outcome is FramingOutcome.Fatal)
        assertEquals(FatalReason.PAYLOAD_TOO_LARGE, (outcome as FramingOutcome.Fatal).reason)
    }

    @Test
    fun `unsupported version is fatal`() {
        val header = byteArrayOf(9, FrameType.PING.toByte(), 0, 0)
        val outcome = StreamFramer().push(header)
        assertTrue(outcome is FramingOutcome.Fatal)
        assertEquals(FatalReason.UNSUPPORTED_VERSION, (outcome as FramingOutcome.Fatal).reason)
    }

    @Test
    fun `a frame split byte by byte never emits early`() {
        val payload = "你好世界".toByteArray(Charsets.UTF_8)
        val encoded = FrameCodec.encode(FrameType.CHANNEL_POST, payload)
        val framer = StreamFramer()
        var emitted = 0
        for (i in encoded.indices) {
            val outcome = framer.push(encoded, i, 1)
            assertTrue(outcome is FramingOutcome.Frames)
            emitted += (outcome as FramingOutcome.Frames).frames.size
        }
        assertEquals(1, emitted)
    }
}

/** Codec-level behaviour that is not covered by the shared vectors. */
class MessageCodecTest {

    private val deviceA = ByteOps.fromHex("0f1e2d3c4b5a69788796a5b4c3d2e1f0")
    private val deviceB = ByteOps.fromHex("a0b1c2d3e4f50112233445566778899a")

    @Test
    fun `channel post keeps multi-byte utf8 intact`() {
        val text = "晚上好，今天气温 26°C 👍 — длинный текст"
        val post = ChannelPost(
            msgId = AirChatCrypto.randomMessageId(),
            timestampMillis = 1_758_000_000_123L,
            senderId = deviceA,
            senderNickname = "小明",
            text = text,
        )
        val decoded = MessageCodec.decodeChannelPost(MessageCodec.encodeChannelPost(post))
        assertNotNull(decoded)
        assertEquals(text, decoded!!.text)
        assertEquals("小明", decoded.senderNickname)
        assertEquals(post.timestampMillis, decoded.timestampMillis)
        assertEquals(ByteOps.toHex(deviceA), ByteOps.toHex(decoded.senderId))
    }

    @Test
    fun `hello rejects an oversized nickname on decode`() {
        val nickname = "x".repeat(AirChatProtocol.MAX_NICKNAME_BYTES + 1)
        val writer = ByteWriter()
        writer.u16(AirChatProtocol.VERSION)
        writer.put(deviceA)
        writer.u8(nickname.length)
        writer.put(nickname.toByteArray())
        writer.put(ByteArray(AirChatProtocol.PUBLIC_KEY_BYTES).also { it[0] = 0x04 })
        writer.u8(Capabilities.ALL)
        writer.put(ByteArray(AirChatProtocol.HELLO_NONCE_BYTES))
        assertNull(MessageCodec.decodeHello(writer.toByteArray()))
    }

    @Test
    fun `decoders reject truncated and trailing-garbage payloads`() {
        val post = ChannelPost(
            AirChatCrypto.randomMessageId(), 1L, deviceA, "n", "hello",
        )
        val encoded = MessageCodec.encodeChannelPost(post)

        assertNull(MessageCodec.decodeChannelPost(encoded.copyOf(encoded.size - 1)))
        assertNull(MessageCodec.decodeChannelPost(ByteOps.concat(encoded, byteArrayOf(0))))
        assertNull(MessageCodec.decodeChannelPost(ByteArray(0)))
    }

    @Test
    fun `private message requires a ciphertext large enough to hold the tag`() {
        val writer = ByteWriter()
        writer.put(AirChatCrypto.randomMessageId())
        writer.i64(1L)
        writer.put(deviceA)
        writer.put(deviceB)
        writer.put(ByteArray(AirChatProtocol.AEAD_NONCE_BYTES))
        writer.u16(4)
        writer.put(ByteArray(4))
        assertNull(MessageCodec.decodePrivateMessage(writer.toByteArray()))
    }

    @Test
    fun `sync response drops entries that would overflow the frame`() {
        val nickname = "n"
        val posts = (0 until 200).map { index ->
            ChannelPost(
                msgId = AirChatCrypto.randomMessageId(),
                timestampMillis = index.toLong(),
                senderId = deviceA,
                senderNickname = nickname,
                text = "m".repeat(200),
            )
        }
        val encoded = MessageCodec.encodeSyncResponse(SyncResponse(posts))
        assertTrue("must fit in one frame", encoded.size <= AirChatProtocol.MAX_PAYLOAD_BYTES)
        val decoded = MessageCodec.decodeSyncResponse(encoded)
        assertNotNull(decoded)
        assertTrue("should have dropped some entries", decoded!!.posts.size in 1 until posts.size)
        assertEquals("first entry survives", 0L, decoded.posts.first().timestampMillis)
    }

    @Test
    fun `typing and ack vectors round-trip`() {
        val typing = Typing(TypingScope.PRIVATE, active = true, recipientId = deviceB)
        val decodedTyping = MessageCodec.decodeTyping(MessageCodec.encodeTyping(typing))
        assertNotNull(decodedTyping)
        assertEquals(TypingScope.PRIVATE, decodedTyping!!.scope)
        assertTrue(decodedTyping.active)
        assertEquals(ByteOps.toHex(deviceB), ByteOps.toHex(decodedTyping.recipientId))

        val ack = DeliveryAck(AirChatCrypto.randomMessageId(), AckStatus.UNDECRYPTABLE)
        val decodedAck = MessageCodec.decodeDeliveryAck(MessageCodec.encodeDeliveryAck(ack))
        assertNotNull(decodedAck)
        assertEquals(AckStatus.UNDECRYPTABLE, decodedAck!!.status)
    }

    @Test
    fun `unsigned comparison orders device ids the way the protocol requires`() {
        val low = ByteOps.fromHex("0f1e2d3c4b5a69788796a5b4c3d2e1f0")
        val high = ByteOps.fromHex("a0b1c2d3e4f50112233445566778899a")
        assertTrue(ByteOps.compareUnsigned(low, high) < 0)
        assertTrue(ByteOps.compareUnsigned(high, low) > 0)
        assertEquals(0, ByteOps.compareUnsigned(low, low.copyOf()))
        // 0xff must sort above 0x00, which a signed comparison would get wrong.
        assertTrue(ByteOps.compareUnsigned(byteArrayOf(0xFF.toByte()), byteArrayOf(0x00)) > 0)
    }
}
