package com.airchat.data

import androidx.room.ColumnInfo
import androidx.room.Entity
import androidx.room.Index
import androidx.room.PrimaryKey
import com.airchat.protocol.AirChatProtocol
import com.airchat.protocol.MessageRecord
import com.airchat.protocol.PeerRecord
import com.airchat.protocol.SessionRecord
import com.airchat.protocol.IdentityRecord

/*
 * Table and column names follow docs/protocol.md section 12 exactly, so the iOS port can use
 * the same schema and the two implementations stay comparable.
 */

@Entity(tableName = "identity")
data class IdentityEntity(
    @PrimaryKey @ColumnInfo(name = "id") val id: Int = SINGLE_ROW,
    @ColumnInfo(name = "device_id") val deviceId: ByteArray,
    @ColumnInfo(name = "private_key") val privateKey: ByteArray,
    @ColumnInfo(name = "public_key") val publicKey: ByteArray,
    @ColumnInfo(name = "nickname") val nickname: String,
    @ColumnInfo(name = "created_ms") val createdMs: Long,
) {
    companion object {
        const val SINGLE_ROW = 1
    }
}

@Entity(tableName = "peers")
data class PeerEntity(
    @PrimaryKey @ColumnInfo(name = "device_id") val deviceId: ByteArray,
    @ColumnInfo(name = "nickname") val nickname: String,
    @ColumnInfo(name = "public_key") val publicKey: ByteArray,
    @ColumnInfo(name = "trust_state") val trustState: Int,
    @ColumnInfo(name = "last_seen_ms") val lastSeenMs: Long,
    @ColumnInfo(name = "created_ms") val createdMs: Long,
)

@Entity(
    tableName = "messages",
    indices = [
        Index(value = ["conversation_id", "received_ms"]),
        Index(value = ["status"]),
        Index(value = ["kind", "received_ms"]),
    ],
)
data class MessageEntity(
    @PrimaryKey @ColumnInfo(name = "msg_id") val msgId: ByteArray,
    @ColumnInfo(name = "conversation_id") val conversationId: String,
    @ColumnInfo(name = "kind") val kind: Int,
    @ColumnInfo(name = "direction") val direction: Int,
    @ColumnInfo(name = "sender_id") val senderId: ByteArray,
    @ColumnInfo(name = "recipient_id") val recipientId: ByteArray?,
    @ColumnInfo(name = "text") val text: String,
    @ColumnInfo(name = "timestamp_ms") val timestampMs: Long,
    @ColumnInfo(name = "received_ms") val receivedMs: Long,
    @ColumnInfo(name = "status") val status: Int,
)

@Entity(tableName = "sessions")
data class SessionEntity(
    @PrimaryKey @ColumnInfo(name = "peer_device_id") val peerDeviceId: ByteArray,
    @ColumnInfo(name = "session_key") val sessionKey: ByteArray,
    @ColumnInfo(name = "peer_public_key") val peerPublicKey: ByteArray,
    @ColumnInfo(name = "verified") val verified: Int,
    @ColumnInfo(name = "created_ms") val createdMs: Long,
    @ColumnInfo(name = "last_used_ms") val lastUsedMs: Long,
)

// ---------------------------------------------------------------- mapping

fun IdentityEntity.toRecord(): IdentityRecord =
    IdentityRecord(deviceId, privateKey, publicKey, nickname)

fun IdentityRecord.toEntity(createdMs: Long): IdentityEntity =
    IdentityEntity(
        deviceId = deviceId,
        privateKey = privateKeyEncoded,
        publicKey = publicKeyEncoded,
        nickname = nickname,
        createdMs = createdMs,
    )

fun PeerEntity.toRecord(): PeerRecord =
    PeerRecord(deviceId, nickname, publicKey, trustState, lastSeenMs, createdMs)

fun PeerRecord.toEntity(): PeerEntity =
    PeerEntity(deviceId, nickname, publicKey, trustState, lastSeenMs, createdMs)

fun MessageEntity.toRecord(): MessageRecord =
    MessageRecord(msgId, conversationId, kind, direction, senderId, recipientId, text, timestampMs, receivedMs, status)

fun MessageRecord.toEntity(): MessageEntity =
    MessageEntity(msgId, conversationId, kind, direction, senderId, recipientId, text, timestampMs, receivedMs, status)

fun SessionEntity.toRecord(): SessionRecord =
    SessionRecord(peerDeviceId, sessionKey, peerPublicKey, verified != 0, createdMs, lastUsedMs)

fun SessionRecord.toEntity(): SessionEntity =
    SessionEntity(peerDeviceId, sessionKey, peerPublicKey, if (verified) 1 else 0, createdMs, lastUsedMs)

/** Guard against accidentally storing values that the protocol cannot represent. */
internal fun requireProtocolWidth(name: String, bytes: ByteArray, expected: Int) {
    require(bytes.size == expected) { "$name must be $expected bytes, got ${bytes.size}" }
}

internal const val MESSAGE_ID_BYTES = AirChatProtocol.MSG_ID_BYTES
internal const val DEVICE_ID_BYTES = AirChatProtocol.DEVICE_ID_BYTES
