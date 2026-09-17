package com.airchat.protocol

/** Persisted device identity. The private key encoding is platform specific (opaque blob). */
class IdentityRecord(
    val deviceId: ByteArray,
    /** Opaque platform encoding: PKCS#8 on Android, raw scalar on iOS. */
    val privateKeyEncoded: ByteArray,
    val publicKeyEncoded: ByteArray,
    val nickname: String,
)

class PeerRecord(
    val deviceId: ByteArray,
    val nickname: String,
    val publicKey: ByteArray,
    val trustState: Int,
    val lastSeenMs: Long,
    val createdMs: Long,
)

class MessageRecord(
    val msgId: ByteArray,
    val conversationId: String,
    val kind: Int,
    val direction: Int,
    val senderId: ByteArray,
    val recipientId: ByteArray?,
    val text: String,
    val timestampMs: Long,
    val receivedMs: Long,
    val status: Int,
)

class SessionRecord(
    val peerDeviceId: ByteArray,
    val sessionKey: ByteArray,
    val peerPublicKey: ByteArray,
    val verified: Boolean,
    val createdMs: Long,
    val lastUsedMs: Long,
)

object TrustState {
    const val UNVERIFIED = 0
    const val TRUSTED = 1
    const val REJECTED = 2
}

object MessageKind {
    const val CHANNEL = 0
    const val PRIVATE = 1
}

object MessageDirection {
    const val INCOMING = 0
    const val OUTGOING = 1
}

object MessageStatus {
    const val LOCAL = 0
    const val SENT = 1
    const val DELIVERED = 2
    const val FAILED = 3
}

/**
 * Persistence contract implemented by `core-data` (Room) in production and by an in-memory
 * fake in tests. Mirrors docs/protocol.md section 12; the Swift port exposes the same fields.
 */
interface ChatStore {
    suspend fun loadIdentity(): IdentityRecord?
    suspend fun saveIdentity(record: IdentityRecord)

    suspend fun upsertPeer(record: PeerRecord)
    suspend fun getPeer(deviceId: ByteArray): PeerRecord?
    suspend fun listPeers(): List<PeerRecord>
    suspend fun setTrustState(deviceId: ByteArray, trustState: Int)

    /** Returns false when a message with this msgId already exists (dedupe by primary key). */
    suspend fun insertMessage(record: MessageRecord): Boolean
    suspend fun getMessage(msgId: ByteArray): MessageRecord?
    /** Returns false when no message with this msgId exists. */
    suspend fun updateMessageStatus(msgId: ByteArray, status: Int): Boolean
    suspend fun listMessages(conversationId: String, limit: Int): List<MessageRecord>

    /** Channel history newer than [sinceMs], oldest first, for SYNC_RESP. */
    suspend fun historySince(sinceMs: Long, limit: Int): List<MessageRecord>

    suspend fun saveSession(record: SessionRecord)
    suspend fun getSession(peerDeviceId: ByteArray): SessionRecord?

    suspend fun pruneChannel(retainCount: Int, retainDays: Int)
}
