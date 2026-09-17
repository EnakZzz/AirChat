import Foundation

/// Every wire-protocol constant. Mirrors `docs/protocol.md` section 2, which is the single source
/// of truth shared with the Kotlin implementation.
public enum AirChatProtocol {
    public static let version = 1

    public static let frameHeaderBytes = 4
    public static let maxPayloadBytes = 6144
    public static let maxChunkBytes = 512
    public static let maxLinks = 8

    public static let deviceIdBytes = 16
    public static let msgIdBytes = 16
    public static let publicKeyBytes = 65
    public static let aeadNonceBytes = 12
    public static let aeadTagBytes = 16
    public static let helloNonceBytes = 8

    public static let maxNicknameBytes = 32
    public static let maxTextBytes = 4000
    public static let maxTextChars = 1000

    public static let channelRetainCount = 500
    public static let channelRetainDays = 7

    public static let defaultMtu = 23
    public static let preferredMtu = 517

    public static let handshakeTimeoutMs: Int64 = 10_000
    public static let pingIntervalMs: Int64 = 15_000
    public static let linkIdleTimeoutMs: Int64 = 45_000
    public static let scanRetryAfterMs: Int64 = 6_000
    public static let reconnectBackoffMs: Int64 = 3_000

    public static let syncSinceMinutes = 10
    public static let syncMaxCount = 50

    public static let channelConversationId = "channel"
    public static let defaultNickname = "邻居"
}

/// GATT UUIDs plus the 16-bit advertising alias.
public enum AirChatUuids {
    public static let service = "a1c0a000-1e63-4b5a-9d2f-0f1e2d3c4b5a"
    public static let ctrl = "a1c0a001-1e63-4b5a-9d2f-0f1e2d3c4b5a"
    public static let tx = "a1c0a002-1e63-4b5a-9d2f-0f1e2d3c4b5a"
    public static let rx = "a1c0a003-1e63-4b5a-9d2f-0f1e2d3c4b5a"

    /// Presence hint carried in Service Data (AD type 0x16). Never authoritative.
    public static let presenceUuid16: UInt16 = 0xA1C0
    /// The same alias expanded the way CoreBluetooth normalises 16-bit UUIDs.
    public static let presence = "0000a1c0-0000-1000-8000-00805f9b34fb"

    public static let cccd = "00002902-0000-1000-8000-00805f9b34fb"
}

public enum FrameType {
    public static let hello = 0x01
    public static let helloAck = 0x02
    public static let channelPost = 0x10
    public static let privateMsg = 0x11
    public static let deliveryAck = 0x12
    public static let typing = 0x13
    public static let syncReq = 0x20
    public static let syncResp = 0x21
    public static let keyVerifyReq = 0x30
    public static let keyVerifyResp = 0x31
    public static let pong = 0x7E
    public static let ping = 0x7F

    /// Signalling frames travel on CH_CTRL; everything else uses the data channel.
    public static func isControl(_ type: Int) -> Bool {
        switch type {
        case hello, helloAck, keyVerifyReq, keyVerifyResp, ping, pong: return true
        default: return false
        }
    }

    public static func name(_ type: Int) -> String {
        switch type {
        case hello: return "HELLO"
        case helloAck: return "HELLO_ACK"
        case channelPost: return "CHANNEL_POST"
        case privateMsg: return "PRIVATE_MSG"
        case deliveryAck: return "DELIVERY_ACK"
        case typing: return "TYPING"
        case syncReq: return "SYNC_REQ"
        case syncResp: return "SYNC_RESP"
        case keyVerifyReq: return "KEY_VERIFY_REQ"
        case keyVerifyResp: return "KEY_VERIFY_RESP"
        case ping: return "PING"
        case pong: return "PONG"
        default: return String(format: "UNKNOWN(0x%02x)", type)
        }
    }
}

public enum Capabilities {
    public static let `private` = 0x01
    public static let sync = 0x02
    public static let all = 0x03
}

public enum AckStatus: Int {
    case delivered = 0
    case undecryptable = 1
}

public enum TypingScope: Int {
    case channel = 0
    case `private` = 1
}

/// Link lifecycle status surfaced to the UI.
public enum ChatStatus: Equatable {
    case stopped
    case bluetoothUnavailable
    case permissionMissing
    case scanning
    case nearbyFull
    case failed
}
