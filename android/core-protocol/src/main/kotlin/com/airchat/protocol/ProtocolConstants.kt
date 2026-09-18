package com.airchat.protocol

/**
 * All wire-protocol constants. Mirrors `docs/protocol.md` section 2, which is the single
 * source of truth shared with the iOS implementation.
 */
object AirChatProtocol {
    const val VERSION = 1

    const val FRAME_HEADER_BYTES = 4
    const val MAX_PAYLOAD_BYTES = 6144
    const val MAX_CHUNK_BYTES = 512
    const val MAX_LINKS = 8

    const val DEVICE_ID_BYTES = 16
    const val MSG_ID_BYTES = 16
    const val PUBLIC_KEY_BYTES = 65
    const val AEAD_NONCE_BYTES = 12
    const val AEAD_TAG_BYTES = 16
    const val HELLO_NONCE_BYTES = 8
    const val AAD_BYTES = 48

    const val MAX_NICKNAME_BYTES = 32
    const val MAX_TEXT_BYTES = 4000
    const val MAX_TEXT_CHARS = 1000

    const val CHANNEL_RETAIN_COUNT = 500
    const val CHANNEL_RETAIN_DAYS = 7

    const val DEFAULT_MTU = 23
    const val PREFERRED_MTU = 517

    const val HANDSHAKE_TIMEOUT_MS = 10_000L
    const val PING_INTERVAL_MS = 15_000L
    const val LINK_IDLE_TIMEOUT_MS = 45_000L
    const val SCAN_RETRY_AFTER_MS = 6_000L
    const val RECONNECT_BACKOFF_MS = 3_000L

    const val SYNC_SINCE_MINUTES = 10
    const val SYNC_MAX_COUNT = 50

    const val CHANNEL_CONVERSATION_ID = "channel"
}

/** GATT UUIDs plus the 16-bit advertising alias. */
object AirChatUuids {
    const val SERVICE = "a1c0a000-1e63-4b5a-9d2f-0f1e2d3c4b5a"
    const val CH_CTRL = "a1c0a001-1e63-4b5a-9d2f-0f1e2d3c4b5a"
    const val CH_TX = "a1c0a002-1e63-4b5a-9d2f-0f1e2d3c4b5a"
    const val CH_RX = "a1c0a003-1e63-4b5a-9d2f-0f1e2d3c4b5a"

    /** Presence hint carried in Service Data (AD type 0x16). Never authoritative. */
    const val PRESENCE_UUID16 = 0xA1C0
}

object FrameType {
    const val HELLO = 0x01
    const val HELLO_ACK = 0x02
    const val CHANNEL_POST = 0x10
    const val PRIVATE_MSG = 0x11
    const val DELIVERY_ACK = 0x12
    const val TYPING = 0x13
    const val SYNC_REQ = 0x20
    const val SYNC_RESP = 0x21
    const val KEY_VERIFY_REQ = 0x30
    const val KEY_VERIFY_RESP = 0x31
    const val PONG = 0x7E
    const val PING = 0x7F

    /** Signalling frames travel on CH_CTRL; everything else uses the data channel. */
    fun isControl(type: Int): Boolean = when (type) {
        HELLO, HELLO_ACK, KEY_VERIFY_REQ, KEY_VERIFY_RESP, PING, PONG -> true
        else -> false
    }

    fun name(type: Int): String = when (type) {
        HELLO -> "HELLO"
        HELLO_ACK -> "HELLO_ACK"
        CHANNEL_POST -> "CHANNEL_POST"
        PRIVATE_MSG -> "PRIVATE_MSG"
        DELIVERY_ACK -> "DELIVERY_ACK"
        TYPING -> "TYPING"
        SYNC_REQ -> "SYNC_REQ"
        SYNC_RESP -> "SYNC_RESP"
        KEY_VERIFY_REQ -> "KEY_VERIFY_REQ"
        KEY_VERIFY_RESP -> "KEY_VERIFY_RESP"
        PING -> "PING"
        PONG -> "PONG"
        else -> "UNKNOWN(0x%02x)".format(type)
    }
}

object Capabilities {
    const val PRIVATE = 0x01
    const val SYNC = 0x02
    const val ALL = PRIVATE or SYNC
}

enum class AckStatus(val code: Int) {
    DELIVERED(0),
    UNDECRYPTABLE(1);

    companion object {
        fun fromCode(code: Int): AckStatus? = entries.firstOrNull { it.code == code }
    }
}

enum class TypingScope(val code: Int) {
    CHANNEL(0),
    PRIVATE(1);

    companion object {
        fun fromCode(code: Int): TypingScope? = entries.firstOrNull { it.code == code }
    }
}

/**
 * Link lifecycle status surfaced to the UI. Mirrors the iOS `LinkStatus` type.
 */
enum class ChatStatus {
    STOPPED,

    /** Radio up and advertising, but not looking for anyone: scanning is a user action. */
    IDLE,
    BLUETOOTH_UNAVAILABLE,
    PERMISSION_MISSING,
    SCANNING,
    NEARBY_FULL,
    FAILED,
}
