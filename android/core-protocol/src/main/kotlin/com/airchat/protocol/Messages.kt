package com.airchat.protocol

/** HELLO / HELLO_ACK payload. Structure is identical for both frame types. */
class Hello(
    val protocolVersion: Int,
    val deviceId: ByteArray,
    val nickname: String,
    val publicKey: ByteArray,
    val capabilities: Int,
    val helloNonce: ByteArray,
) {
    init {
        require(deviceId.size == AirChatProtocol.DEVICE_ID_BYTES) { "deviceId must be 16 bytes" }
        require(publicKey.size == AirChatProtocol.PUBLIC_KEY_BYTES) { "publicKey must be 65 bytes" }
        require(helloNonce.size == AirChatProtocol.HELLO_NONCE_BYTES) { "helloNonce must be 8 bytes" }
        require(publicKey[0] == 0x04.toByte()) { "publicKey must be an uncompressed point" }
    }

    val supportsPrivate: Boolean get() = (capabilities and Capabilities.PRIVATE) != 0
    val supportsSync: Boolean get() = (capabilities and Capabilities.SYNC) != 0

    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (other !is Hello) return false
        return protocolVersion == other.protocolVersion &&
            deviceId.contentEquals(other.deviceId) &&
            nickname == other.nickname &&
            publicKey.contentEquals(other.publicKey) &&
            capabilities == other.capabilities &&
            helloNonce.contentEquals(other.helloNonce)
    }

    override fun hashCode(): Int {
        var result = protocolVersion
        result = 31 * result + deviceId.contentHashCode()
        result = 31 * result + nickname.hashCode()
        result = 31 * result + publicKey.contentHashCode()
        result = 31 * result + capabilities
        result = 31 * result + helloNonce.contentHashCode()
        return result
    }

    override fun toString(): String =
        "Hello(v$protocolVersion, ${ByteOps.toHex(deviceId)}, \"$nickname\", caps=$capabilities)"
}

/** Public channel message. Plaintext by design: the channel is not encrypted in v1. */
class ChannelPost(
    val msgId: ByteArray,
    val timestampMillis: Long,
    val senderId: ByteArray,
    val senderNickname: String,
    val text: String,
) {
    init {
        require(msgId.size == AirChatProtocol.MSG_ID_BYTES) { "msgId must be 16 bytes" }
        require(senderId.size == AirChatProtocol.DEVICE_ID_BYTES) { "senderId must be 16 bytes" }
    }

    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (other !is ChannelPost) return false
        return msgId.contentEquals(other.msgId) &&
            timestampMillis == other.timestampMillis &&
            senderId.contentEquals(other.senderId) &&
            senderNickname == other.senderNickname &&
            text == other.text
    }

    override fun hashCode(): Int {
        var result = msgId.contentHashCode()
        result = 31 * result + timestampMillis.hashCode()
        result = 31 * result + senderId.contentHashCode()
        result = 31 * result + senderNickname.hashCode()
        result = 31 * result + text.hashCode()
        return result
    }

    override fun toString(): String =
        "ChannelPost(${ByteOps.toHex(msgId)}, ${ByteOps.toHex(senderId)}, \"$text\")"
}

/** 1:1 message. `ciphertext` is the AEAD output (ciphertext followed by the 16-byte tag). */
class PrivateMessage(
    val msgId: ByteArray,
    val timestampMillis: Long,
    val senderId: ByteArray,
    val recipientId: ByteArray,
    val nonce: ByteArray,
    val ciphertext: ByteArray,
) {
    init {
        require(msgId.size == AirChatProtocol.MSG_ID_BYTES) { "msgId must be 16 bytes" }
        require(senderId.size == AirChatProtocol.DEVICE_ID_BYTES) { "senderId must be 16 bytes" }
        require(recipientId.size == AirChatProtocol.DEVICE_ID_BYTES) { "recipientId must be 16 bytes" }
        require(nonce.size == AirChatProtocol.AEAD_NONCE_BYTES) { "nonce must be 12 bytes" }
        require(ciphertext.size >= AirChatProtocol.AEAD_TAG_BYTES) { "ciphertext must include the tag" }
    }

    /** Additional authenticated data, binding the ciphertext to this exact message. */
    val aad: ByteArray get() = ByteOps.concat(msgId, senderId, recipientId)
}

class DeliveryAck(val msgId: ByteArray, val status: AckStatus) {
    init {
        require(msgId.size == AirChatProtocol.MSG_ID_BYTES) { "msgId must be 16 bytes" }
    }
}

class Typing(val scope: TypingScope, val active: Boolean, val recipientId: ByteArray) {
    init {
        require(recipientId.size == AirChatProtocol.DEVICE_ID_BYTES) { "recipientId must be 16 bytes" }
    }
}

class SyncRequest(val requesterId: ByteArray, val sinceMinutesAgo: Int, val maxCount: Int) {
    init {
        require(requesterId.size == AirChatProtocol.DEVICE_ID_BYTES) { "requesterId must be 16 bytes" }
    }
}

class SyncResponse(val posts: List<ChannelPost>)

class KeyVerifyResponse(val accepted: Boolean)

/**
 * Encode/decode for every payload type in `docs/protocol.md` section 8.
 *
 * Decoding never throws for malformed input: it returns null and the caller drops the frame,
 * matching protocol section 9 rule 3.
 */
object MessageCodec {

    // ---------------------------------------------------------------- HELLO

    fun encodeHello(hello: Hello): ByteArray {
        val nickname = hello.nickname.toByteArray(Charsets.UTF_8)
        require(nickname.size <= AirChatProtocol.MAX_NICKNAME_BYTES) { "nickname too long" }
        val writer = ByteWriter(96)
        writer.u16(hello.protocolVersion)
        writer.put(hello.deviceId)
        writer.u8(nickname.size)
        writer.put(nickname)
        writer.put(hello.publicKey)
        writer.u8(hello.capabilities)
        writer.put(hello.helloNonce)
        return writer.toByteArray()
    }

    fun decodeHello(payload: ByteArray): Hello? = runCatching {
        val reader = ByteReader(payload)
        val version = reader.u16()
        val deviceId = reader.bytes(AirChatProtocol.DEVICE_ID_BYTES)
        val nicknameLength = reader.u8()
        if (nicknameLength > AirChatProtocol.MAX_NICKNAME_BYTES) {
            throw ProtocolFormatException("nickname $nicknameLength bytes exceeds limit")
        }
        val nickname = reader.bytes(nicknameLength).toString(Charsets.UTF_8)
        val publicKey = reader.bytes(AirChatProtocol.PUBLIC_KEY_BYTES)
        val capabilities = reader.u8()
        val helloNonce = reader.bytes(AirChatProtocol.HELLO_NONCE_BYTES)
        reader.requireFullyConsumed()
        Hello(version, deviceId, nickname, publicKey, capabilities, helloNonce)
    }.getOrNull()

    // -------------------------------------------------------- CHANNEL_POST

    fun encodeChannelPost(post: ChannelPost): ByteArray {
        val nickname = post.senderNickname.toByteArray(Charsets.UTF_8)
        val text = post.text.toByteArray(Charsets.UTF_8)
        require(nickname.size <= AirChatProtocol.MAX_NICKNAME_BYTES) { "nickname too long" }
        require(text.size <= AirChatProtocol.MAX_TEXT_BYTES) { "text too long" }
        val writer = ByteWriter(text.size + 64)
        writer.put(post.msgId)
        writer.i64(post.timestampMillis)
        writer.put(post.senderId)
        writer.u8(nickname.size)
        writer.put(nickname)
        writer.putVar(text)
        return writer.toByteArray()
    }

    fun decodeChannelPost(payload: ByteArray): ChannelPost? = runCatching {
        val reader = ByteReader(payload)
        val msgId = reader.bytes(AirChatProtocol.MSG_ID_BYTES)
        val timestamp = reader.i64()
        val senderId = reader.bytes(AirChatProtocol.DEVICE_ID_BYTES)
        val nicknameLength = reader.u8()
        if (nicknameLength > AirChatProtocol.MAX_NICKNAME_BYTES) {
            throw ProtocolFormatException("nickname $nicknameLength bytes exceeds limit")
        }
        val nickname = reader.bytes(nicknameLength).toString(Charsets.UTF_8)
        val textLength = reader.u16()
        if (textLength > AirChatProtocol.MAX_TEXT_BYTES) {
            throw ProtocolFormatException("text $textLength bytes exceeds limit")
        }
        val text = reader.bytes(textLength).toString(Charsets.UTF_8)
        reader.requireFullyConsumed()
        ChannelPost(msgId, timestamp, senderId, nickname, text)
    }.getOrNull()

    // --------------------------------------------------------- PRIVATE_MSG

    fun encodePrivateMessage(message: PrivateMessage): ByteArray {
        require(message.ciphertext.size <= AirChatProtocol.MAX_TEXT_BYTES + AirChatProtocol.AEAD_TAG_BYTES) {
            "ciphertext too long"
        }
        val writer = ByteWriter(message.ciphertext.size + 80)
        writer.put(message.msgId)
        writer.i64(message.timestampMillis)
        writer.put(message.senderId)
        writer.put(message.recipientId)
        writer.put(message.nonce)
        writer.putVar(message.ciphertext)
        return writer.toByteArray()
    }

    fun decodePrivateMessage(payload: ByteArray): PrivateMessage? = runCatching {
        val reader = ByteReader(payload)
        val msgId = reader.bytes(AirChatProtocol.MSG_ID_BYTES)
        val timestamp = reader.i64()
        val senderId = reader.bytes(AirChatProtocol.DEVICE_ID_BYTES)
        val recipientId = reader.bytes(AirChatProtocol.DEVICE_ID_BYTES)
        val nonce = reader.bytes(AirChatProtocol.AEAD_NONCE_BYTES)
        val ciphertext = reader.varBytes()
        if (ciphertext.size < AirChatProtocol.AEAD_TAG_BYTES) {
            throw ProtocolFormatException("ciphertext shorter than the AEAD tag")
        }
        reader.requireFullyConsumed()
        PrivateMessage(msgId, timestamp, senderId, recipientId, nonce, ciphertext)
    }.getOrNull()

    // -------------------------------------------------------- DELIVERY_ACK

    fun encodeDeliveryAck(ack: DeliveryAck): ByteArray {
        val writer = ByteWriter(24)
        writer.put(ack.msgId)
        writer.u8(ack.status.code)
        return writer.toByteArray()
    }

    fun decodeDeliveryAck(payload: ByteArray): DeliveryAck? = runCatching {
        val reader = ByteReader(payload)
        val msgId = reader.bytes(AirChatProtocol.MSG_ID_BYTES)
        val status = AckStatus.fromCode(reader.u8())
            ?: throw ProtocolFormatException("unknown ack status")
        reader.requireFullyConsumed()
        DeliveryAck(msgId, status)
    }.getOrNull()

    // --------------------------------------------------------------- TYPING

    fun encodeTyping(typing: Typing): ByteArray {
        val writer = ByteWriter(20)
        writer.u8(typing.scope.code)
        writer.u8(if (typing.active) 1 else 0)
        writer.put(typing.recipientId)
        return writer.toByteArray()
    }

    fun decodeTyping(payload: ByteArray): Typing? = runCatching {
        val reader = ByteReader(payload)
        val scope = TypingScope.fromCode(reader.u8())
            ?: throw ProtocolFormatException("unknown typing scope")
        val active = reader.u8() != 0
        val recipientId = reader.bytes(AirChatProtocol.DEVICE_ID_BYTES)
        reader.requireFullyConsumed()
        Typing(scope, active, recipientId)
    }.getOrNull()

    // ------------------------------------------------------------- SYNC_REQ

    fun encodeSyncRequest(request: SyncRequest): ByteArray {
        val writer = ByteWriter(24)
        writer.put(request.requesterId)
        writer.u16(request.sinceMinutesAgo)
        writer.u16(request.maxCount)
        return writer.toByteArray()
    }

    fun decodeSyncRequest(payload: ByteArray): SyncRequest? = runCatching {
        val reader = ByteReader(payload)
        val requesterId = reader.bytes(AirChatProtocol.DEVICE_ID_BYTES)
        val since = reader.u16()
        val maxCount = reader.u16()
        reader.requireFullyConsumed()
        SyncRequest(requesterId, since, maxCount)
    }.getOrNull()

    // ------------------------------------------------------------ SYNC_RESP

    /**
     * Encodes as many posts as fit inside MAX_PAYLOAD_BYTES. Entries that would overflow are
     * dropped and `count` reflects only what was written (protocol section 8.7).
     */
    fun encodeSyncResponse(response: SyncResponse, maxPayloadBytes: Int = AirChatProtocol.MAX_PAYLOAD_BYTES): ByteArray {
        val encodedPosts = response.posts.map { encodeChannelPost(it) }
        val body = ByteWriter(256)
        var count = 0
        var payloadBytes = 2 // the u16 count itself
        for (post in encodedPosts) {
            if (post.size > 0xFFFF) continue
            if (payloadBytes + 2 + post.size > maxPayloadBytes) break
            body.u16(post.size)
            body.put(post)
            payloadBytes += 2 + post.size
            count++
        }
        val writer = ByteWriter(payloadBytes)
        writer.u16(count)
        writer.put(body.toByteArray())
        return writer.toByteArray()
    }

    fun decodeSyncResponse(payload: ByteArray): SyncResponse? = runCatching {
        val reader = ByteReader(payload)
        val count = reader.u16()
        val posts = ArrayList<ChannelPost>(count)
        for (i in 0 until count) {
            val length = reader.u16()
            val post = decodeChannelPost(reader.bytes(length)) ?: continue
            posts += post
        }
        reader.requireFullyConsumed()
        SyncResponse(posts)
    }.getOrNull()

    // ------------------------------------------------------ KEY_VERIFY_RESP

    fun encodeKeyVerifyResponse(response: KeyVerifyResponse): ByteArray =
        byteArrayOf(if (response.accepted) 1 else 0)

    fun decodeKeyVerifyResponse(payload: ByteArray): KeyVerifyResponse? = runCatching {
        val reader = ByteReader(payload)
        val value = reader.u8()
        reader.requireFullyConsumed()
        KeyVerifyResponse(value != 0)
    }.getOrNull()
}
