import Foundation

/// Persisted device identity. The private key encoding is platform specific (opaque blob).
public struct IdentityRecord: Equatable {
    public let deviceId: Data
    /// Raw 32-byte P-256 scalar (CryptoKit `rawRepresentation`).
    public let privateKeyRaw: Data
    /// Uncompressed public point, persisted alongside because iOS and Android must agree on it.
    public let publicKey: Data
    public let nickname: String

    public init(deviceId: Data, privateKeyRaw: Data, publicKey: Data, nickname: String) {
        self.deviceId = deviceId
        self.privateKeyRaw = privateKeyRaw
        self.publicKey = publicKey
        self.nickname = nickname
    }
}

public struct PeerRecord: Equatable {
    public let deviceId: Data
    public let nickname: String
    public let publicKey: Data
    public let trustState: Int
    public let lastSeenMs: Int64
    public let createdMs: Int64

    public init(
        deviceId: Data,
        nickname: String,
        publicKey: Data,
        trustState: Int,
        lastSeenMs: Int64,
        createdMs: Int64
    ) {
        self.deviceId = deviceId
        self.nickname = nickname
        self.publicKey = publicKey
        self.trustState = trustState
        self.lastSeenMs = lastSeenMs
        self.createdMs = createdMs
    }
}

public struct MessageRecord: Equatable {
    public let msgId: Data
    public let conversationId: String
    public let kind: Int
    public let direction: Int
    public let senderId: Data
    public let recipientId: Data?
    public let text: String
    public let timestampMs: Int64
    public let receivedMs: Int64
    public let status: Int

    public init(
        msgId: Data,
        conversationId: String,
        kind: Int,
        direction: Int,
        senderId: Data,
        recipientId: Data?,
        text: String,
        timestampMs: Int64,
        receivedMs: Int64,
        status: Int
    ) {
        self.msgId = msgId
        self.conversationId = conversationId
        self.kind = kind
        self.direction = direction
        self.senderId = senderId
        self.recipientId = recipientId
        self.text = text
        self.timestampMs = timestampMs
        self.receivedMs = receivedMs
        self.status = status
    }

    public func withStatus(_ newStatus: Int) -> MessageRecord {
        MessageRecord(
            msgId: msgId,
            conversationId: conversationId,
            kind: kind,
            direction: direction,
            senderId: senderId,
            recipientId: recipientId,
            text: text,
            timestampMs: timestampMs,
            receivedMs: receivedMs,
            status: newStatus
        )
    }
}

public struct SessionRecord: Equatable {
    public let peerDeviceId: Data
    public let sessionKey: Data
    public let peerPublicKey: Data
    public let verified: Bool
    public let createdMs: Int64
    public let lastUsedMs: Int64

    public init(
        peerDeviceId: Data,
        sessionKey: Data,
        peerPublicKey: Data,
        verified: Bool,
        createdMs: Int64,
        lastUsedMs: Int64
    ) {
        self.peerDeviceId = peerDeviceId
        self.sessionKey = sessionKey
        self.peerPublicKey = peerPublicKey
        self.verified = verified
        self.createdMs = createdMs
        self.lastUsedMs = lastUsedMs
    }
}

public enum TrustState {
    public static let unverified = 0
    public static let trusted = 1
    public static let rejected = 2
}

public enum MessageKind {
    public static let channel = 0
    public static let `private` = 1
}

public enum MessageDirection {
    public static let incoming = 0
    public static let outgoing = 1
}

public enum MessageStatus {
    public static let local = 0
    public static let sent = 1
    public static let delivered = 2
    public static let failed = 3
}

/// Persistence contract implemented by `AirChatData` (SQLite) in production and by an in-memory
/// fake in tests. Mirrors `docs/protocol.md` section 12.
///
/// Deliberately synchronous: SQLite access is local and fast, and a synchronous contract removes
/// an entire class of ordering bugs from the node's single serial queue.
public protocol ChatStore: AnyObject {
    func loadIdentity() throws -> IdentityRecord?
    func saveIdentity(_ record: IdentityRecord) throws

    func upsertPeer(_ record: PeerRecord) throws
    func getPeer(_ deviceId: Data) throws -> PeerRecord?
    func listPeers() throws -> [PeerRecord]
    func setTrustState(_ deviceId: Data, trustState: Int) throws

    /// Returns false when a message with this msgId already exists (dedupe by primary key).
    func insertMessage(_ record: MessageRecord) throws -> Bool
    func getMessage(_ msgId: Data) throws -> MessageRecord?
    /// Returns false when no message with this msgId exists.
    func updateMessageStatus(_ msgId: Data, status: Int) throws -> Bool
    func listMessages(conversationId: String, limit: Int) throws -> [MessageRecord]

    /// Channel history newer than `sinceMs`, oldest first, for SYNC_RESP.
    func historySince(_ sinceMs: Int64, limit: Int) throws -> [MessageRecord]

    func saveSession(_ record: SessionRecord) throws
    func getSession(_ peerDeviceId: Data) throws -> SessionRecord?

    func pruneChannel(retainCount: Int, retainDays: Int) throws
}
