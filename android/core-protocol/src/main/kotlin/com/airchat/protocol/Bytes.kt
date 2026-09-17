package com.airchat.protocol

/** Thrown when a frame or payload cannot be decoded. Never fatal to the link on its own. */
class ProtocolFormatException(message: String) : RuntimeException(message)

/** Big-endian writer for wire payloads. */
class ByteWriter(initialCapacity: Int = 64) {
    private val out = java.io.ByteArrayOutputStream(initialCapacity)

    val size: Int get() = out.size()

    fun u8(value: Int) {
        out.write(value and 0xFF)
    }

    fun u16(value: Int) {
        require(value in 0..0xFFFF) { "u16 out of range: $value" }
        out.write((value ushr 8) and 0xFF)
        out.write(value and 0xFF)
    }

    fun i64(value: Long) {
        for (shift in 56 downTo 0 step 8) {
            out.write(((value ushr shift) and 0xFF).toInt())
        }
    }

    fun put(value: ByteArray) {
        out.write(value, 0, value.size)
    }

    /** u16 length prefix followed by the bytes. */
    fun putVar(value: ByteArray) {
        u16(value.size)
        out.write(value, 0, value.size)
    }

    fun toByteArray(): ByteArray = out.toByteArray()
}

/** Bounds-checked big-endian reader. Every accessor throws ProtocolFormatException on truncation. */
class ByteReader(private val data: ByteArray, private val limit: Int = data.size) {
    private var position = 0

    val remaining: Int get() = limit - position

    fun u8(): Int {
        need(1)
        return data[position++].toInt() and 0xFF
    }

    fun u16(): Int {
        need(2)
        val value = ((data[position].toInt() and 0xFF) shl 8) or (data[position + 1].toInt() and 0xFF)
        position += 2
        return value
    }

    fun i64(): Long {
        need(8)
        var value = 0L
        for (i in 0 until 8) {
            value = (value shl 8) or (data[position + i].toLong() and 0xFF)
        }
        position += 8
        return value
    }

    fun bytes(count: Int): ByteArray {
        need(count)
        val slice = data.copyOfRange(position, position + count)
        position += count
        return slice
    }

    fun varBytes(): ByteArray = bytes(u16())

    /** Requires that the payload is fully consumed; guards against trailing junk. */
    fun requireFullyConsumed() {
        if (remaining != 0) {
            throw ProtocolFormatException("trailing bytes after payload: $remaining")
        }
    }

    private fun need(count: Int) {
        if (count < 0 || remaining < count) {
            throw ProtocolFormatException("truncated payload: needed $count bytes, $remaining available")
        }
    }
}

/** Small helpers shared by both platform implementations. */
object ByteOps {
    /** Unsigned lexicographic comparison, matching the ordering used by the protocol. */
    fun compareUnsigned(a: ByteArray, b: ByteArray): Int {
        val n = minOf(a.size, b.size)
        for (i in 0 until n) {
            val x = a[i].toInt() and 0xFF
            val y = b[i].toInt() and 0xFF
            if (x != y) return x - y
        }
        return a.size - b.size
    }

    fun toHex(bytes: ByteArray): String = buildString(bytes.size * 2) {
        for (b in bytes) {
            val v = b.toInt() and 0xFF
            append(HEX[v ushr 4])
            append(HEX[v and 0x0F])
        }
    }

    fun fromHex(hex: String): ByteArray {
        val clean = hex.filterNot { it.isWhitespace() }
        require(clean.length % 2 == 0) { "hex string must have even length" }
        val out = ByteArray(clean.length / 2)
        for (i in out.indices) {
            val hi = Character.digit(clean[i * 2], 16)
            val lo = Character.digit(clean[i * 2 + 1], 16)
            require(hi >= 0 && lo >= 0) { "invalid hex at index ${i * 2}" }
            out[i] = ((hi shl 4) or lo).toByte()
        }
        return out
    }

    fun concat(vararg parts: ByteArray): ByteArray {
        var total = 0
        for (p in parts) total += p.size
        val out = ByteArray(total)
        var offset = 0
        for (p in parts) {
            System.arraycopy(p, 0, out, offset, p.size)
            offset += p.size
        }
        return out
    }

    private const val HEX = "0123456789abcdef"
}
