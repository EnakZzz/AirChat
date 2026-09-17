package com.airchat.protocol

/**
 * A decoded protocol frame: `[1B version][1B type][2B payloadLength][payload]`.
 *
 * Equality is content based, which matters for the golden-vector tests.
 */
class Frame(val type: Int, val payload: ByteArray) {
    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (other !is Frame) return false
        return type == other.type && payload.contentEquals(other.payload)
    }

    override fun hashCode(): Int = 31 * type + payload.contentHashCode()

    override fun toString(): String =
        "Frame(${FrameType.name(type)}, ${payload.size} bytes)"

    val payloadLength: Int get() = payload.size
}

object FrameCodec {
    fun encode(type: Int, payload: ByteArray): ByteArray {
        require(payload.size <= AirChatProtocol.MAX_PAYLOAD_BYTES) {
            "payload ${payload.size} exceeds MAX_PAYLOAD_BYTES"
        }
        return ByteOps.concat(
            byteArrayOf(AirChatProtocol.VERSION.toByte(), type.toByte()),
            byteArrayOf(
                ((payload.size ushr 8) and 0xFF).toByte(),
                (payload.size and 0xFF).toByte(),
            ),
            payload,
        )
    }

    fun encode(frame: Frame): ByteArray = encode(frame.type, frame.payload)
}

/** Why the framer refused to continue reading the stream. */
enum class FatalReason {
    /** Frame header declared a protocol version this implementation does not speak. */
    UNSUPPORTED_VERSION,

    /** Frame header declared a payload larger than MAX_PAYLOAD_BYTES. */
    PAYLOAD_TOO_LARGE,
}

sealed interface FramingOutcome {
    /** Zero or more complete frames extracted from the stream so far. */
    data class Frames(val frames: List<Frame>) : FramingOutcome

    /**
     * The stream is unrecoverable: the caller must close the link and discard the buffer.
     * Framing always stops at the first fatal condition, so no frames are returned with it.
     */
    data class Fatal(val reason: FatalReason, val message: String) : FramingOutcome
}

/**
 * Turns an unbounded GATT byte stream back into frames.
 *
 * GATT writes and notifications carry no message boundaries, so frames may be split across
 * many chunks and several frames may arrive in one chunk. Unknown frame types are skipped by
 * payload length, which keeps the protocol forward compatible.
 */
class StreamFramer {
    private var buffer = ByteArray(INITIAL_CAPACITY)
    private var size = 0

    /** Bytes currently held awaiting more data. */
    val bufferedBytes: Int get() = size

    fun reset() {
        size = 0
    }

    fun push(bytes: ByteArray, offset: Int = 0, length: Int = bytes.size): FramingOutcome {
        if (length <= 0) return FramingOutcome.Frames(emptyList())
        ensureCapacity(size + length)
        System.arraycopy(bytes, offset, buffer, size, length)
        size += length

        val frames = mutableListOf<Frame>()
        var cursor = 0
        while (true) {
            if (size - cursor < AirChatProtocol.FRAME_HEADER_BYTES) break

            val version = buffer[cursor].toInt() and 0xFF
            if (version != AirChatProtocol.VERSION) {
                reset()
                return FramingOutcome.Fatal(
                    FatalReason.UNSUPPORTED_VERSION,
                    "unsupported protocol version $version (expected ${AirChatProtocol.VERSION})",
                )
            }

            val type = buffer[cursor + 1].toInt() and 0xFF
            val payloadLength =
                ((buffer[cursor + 2].toInt() and 0xFF) shl 8) or
                    (buffer[cursor + 3].toInt() and 0xFF)

            if (payloadLength > AirChatProtocol.MAX_PAYLOAD_BYTES) {
                reset()
                return FramingOutcome.Fatal(
                    FatalReason.PAYLOAD_TOO_LARGE,
                    "declared payload $payloadLength exceeds ${AirChatProtocol.MAX_PAYLOAD_BYTES}",
                )
            }

            val frameEnd = cursor + AirChatProtocol.FRAME_HEADER_BYTES + payloadLength
            if (size < frameEnd) break

            val payload = buffer.copyOfRange(cursor + AirChatProtocol.FRAME_HEADER_BYTES, frameEnd)
            frames += Frame(type, payload)
            cursor = frameEnd
        }

        if (cursor > 0) {
            val remaining = size - cursor
            if (remaining > 0) System.arraycopy(buffer, cursor, buffer, 0, remaining)
            size = remaining
        }
        return FramingOutcome.Frames(frames)
    }

    private fun ensureCapacity(required: Int) {
        if (required <= buffer.size) return
        var newSize = buffer.size
        while (newSize < required) newSize *= 2
        buffer = buffer.copyOf(newSize)
    }

    private companion object {
        const val INITIAL_CAPACITY = 512
    }
}

/**
 * Slices an encoded frame stream into GATT-sized chunks.
 *
 * The chunk size is `min(mtu - 3, MAX_CHUNK_BYTES)`; the upper bound keeps every stack
 * (Android, iOS, and third-party peripherals) inside a well-tested write length.
 */
class StreamChunker(private val maxChunkBytes: Int = AirChatProtocol.MAX_CHUNK_BYTES) {
    fun chunkSizeFor(mtu: Int): Int {
        val effectiveMtu = if (mtu <= 0) AirChatProtocol.DEFAULT_MTU else mtu
        return maxOf(1, minOf(effectiveMtu - 3, maxChunkBytes))
    }

    fun chunk(encoded: ByteArray, mtu: Int): List<ByteArray> {
        val chunkSize = chunkSizeFor(mtu)
        if (encoded.isEmpty()) return emptyList()
        if (encoded.size <= chunkSize) return listOf(encoded)
        val chunks = ArrayList<ByteArray>((encoded.size + chunkSize - 1) / chunkSize)
        var offset = 0
        while (offset < encoded.size) {
            val end = minOf(offset + chunkSize, encoded.size)
            chunks += encoded.copyOfRange(offset, end)
            offset = end
        }
        return chunks
    }
}
