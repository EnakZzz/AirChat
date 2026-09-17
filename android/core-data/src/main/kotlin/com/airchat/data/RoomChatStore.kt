package com.airchat.data

import com.airchat.protocol.AirChatProtocol
import com.airchat.protocol.ChatStore
import com.airchat.protocol.IdentityRecord
import com.airchat.protocol.MessageRecord
import com.airchat.protocol.PeerRecord
import com.airchat.protocol.SessionRecord
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import androidx.room.withTransaction

/**
 * Room-backed [ChatStore].
 *
 * Every method moves to [Dispatchers.IO] because the callers are BLE callback threads and the
 * protocol's maintenance loop; blocking them on disk would stall the connection.
 */
class RoomChatStore(private val database: AirChatDatabase) : ChatStore {

    private companion object {
        const val MILLIS_PER_DAY = 24L * 60L * 60L * 1000L
        val TRUST_STATE_RANGE = 0..2
    }

    private val identityDao get() = database.identityDao()
    private val peerDao get() = database.peerDao()
    private val messageDao get() = database.messageDao()
    private val sessionDao get() = database.sessionDao()

    override suspend fun loadIdentity(): IdentityRecord? = withContext(Dispatchers.IO) {
        identityDao.load()?.toRecord()
    }

    override suspend fun saveIdentity(record: IdentityRecord) = withContext(Dispatchers.IO) {
        requireProtocolWidth("device_id", record.deviceId, DEVICE_ID_BYTES)
        requireProtocolWidth("public_key", record.publicKeyEncoded, AirChatProtocol.PUBLIC_KEY_BYTES)
        database.withTransaction {
            // Preserve the original creation time: REPLACE rewrites the whole row.
            val createdMs = identityDao.load()?.createdMs ?: System.currentTimeMillis()
            identityDao.upsert(record.toEntity(createdMs))
        }
    }

    override suspend fun upsertPeer(record: PeerRecord) = withContext(Dispatchers.IO) {
        requireProtocolWidth("device_id", record.deviceId, DEVICE_ID_BYTES)
        peerDao.upsert(record.toEntity())
    }

    override suspend fun getPeer(deviceId: ByteArray): PeerRecord? = withContext(Dispatchers.IO) {
        peerDao.get(deviceId)?.toRecord()
    }

    override suspend fun listPeers(): List<PeerRecord> = withContext(Dispatchers.IO) {
        peerDao.list().map { it.toRecord() }
    }

    override suspend fun setTrustState(deviceId: ByteArray, trustState: Int) {
        withContext(Dispatchers.IO) {
            require(trustState in TRUST_STATE_RANGE) { "invalid trust state $trustState" }
            peerDao.updateTrustState(deviceId, trustState)
        }
    }

    override suspend fun insertMessage(record: MessageRecord): Boolean = withContext(Dispatchers.IO) {
        requireProtocolWidth("msg_id", record.msgId, MESSAGE_ID_BYTES)
        // -1 means the IGNORE conflict strategy skipped a duplicate msgId.
        messageDao.insert(record.toEntity()) != -1L
    }

    override suspend fun getMessage(msgId: ByteArray): MessageRecord? = withContext(Dispatchers.IO) {
        messageDao.get(msgId)?.toRecord()
    }

    override suspend fun updateMessageStatus(msgId: ByteArray, status: Int): Boolean = withContext(Dispatchers.IO) {
        messageDao.updateStatus(msgId, status) > 0
    }

    override suspend fun listMessages(conversationId: String, limit: Int): List<MessageRecord> =
        withContext(Dispatchers.IO) {
            messageDao.recent(conversationId, limit).map { it.toRecord() }
        }

    override suspend fun historySince(sinceMs: Long, limit: Int): List<MessageRecord> =
        withContext(Dispatchers.IO) {
            messageDao.channelSince(sinceMs, limit).map { it.toRecord() }
        }

    override suspend fun saveSession(record: SessionRecord) = withContext(Dispatchers.IO) {
        sessionDao.upsert(record.toEntity())
    }

    override suspend fun getSession(peerDeviceId: ByteArray): SessionRecord? = withContext(Dispatchers.IO) {
        sessionDao.get(peerDeviceId)?.toRecord()
    }

    override suspend fun pruneChannel(retainCount: Int, retainDays: Int) {
        withContext(Dispatchers.IO) {
            val cutoff = System.currentTimeMillis() - retainDays * MILLIS_PER_DAY
            messageDao.pruneChannel(retainCount, cutoff)
        }
    }
}
