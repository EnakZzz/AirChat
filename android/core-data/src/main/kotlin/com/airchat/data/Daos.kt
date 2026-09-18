package com.airchat.data

import androidx.room.Dao
import androidx.room.Insert
import androidx.room.OnConflictStrategy
import androidx.room.Query
import androidx.room.Upsert

@Dao
interface IdentityDao {
    @Query("SELECT * FROM identity WHERE id = ${IdentityEntity.SINGLE_ROW}")
    suspend fun load(): IdentityEntity?

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun upsert(entity: IdentityEntity)
}

@Dao
interface PeerDao {
    @Upsert
    suspend fun upsert(entity: PeerEntity)

    @Query("SELECT * FROM peers WHERE device_id = :deviceId")
    suspend fun get(deviceId: ByteArray): PeerEntity?

    @Query("SELECT * FROM peers ORDER BY last_seen_ms DESC")
    suspend fun list(): List<PeerEntity>

    @Query("UPDATE peers SET trust_state = :trustState WHERE device_id = :deviceId")
    suspend fun updateTrustState(deviceId: ByteArray, trustState: Int): Int
}

@Dao
interface MessageDao {
    /**
     * Returns the new row id, or -1 when the primary key already existed. That single round trip
     * is what deduplicates replayed messages.
     */
    @Insert(onConflict = OnConflictStrategy.IGNORE)
    suspend fun insert(entity: MessageEntity): Long

    @Query("SELECT * FROM messages WHERE msg_id = :msgId")
    suspend fun get(msgId: ByteArray): MessageEntity?

    /** Returns the number of rows updated (0 when the message is unknown). */
    @Query("UPDATE messages SET status = :status WHERE msg_id = :msgId")
    suspend fun updateStatus(msgId: ByteArray, status: Int): Int

    /**
     * Most recent [limit] messages of one conversation, oldest first.
     *
     * Ordered by the sort key documented in `docs/protocol.md`: the sender's timestamp first, with
     * the local receive time and the message id breaking ties. Sorting on the receive time alone
     * put a batch of history backfilled by SYNC in msg_id order, because every message of such a
     * batch is stored inside the same millisecond.
     */
    @Query(
        """
        SELECT * FROM (
            SELECT * FROM messages WHERE conversation_id = :conversationId
            ORDER BY timestamp_ms DESC, received_ms DESC, msg_id DESC LIMIT :limit
        ) ORDER BY timestamp_ms ASC, received_ms ASC, msg_id ASC
        """,
    )
    suspend fun recent(conversationId: String, limit: Int): List<MessageEntity>

    @Query(
        """
        SELECT * FROM messages
        WHERE kind = 0 AND received_ms >= :sinceMs
        ORDER BY timestamp_ms ASC, received_ms ASC, msg_id ASC LIMIT :limit
        """,
    )
    suspend fun channelSince(sinceMs: Long, limit: Int): List<MessageEntity>

    /**
     * Drops channel messages that fall outside both retention rules. Private conversations are
     * never pruned.
     */
    @Query(
        """
        DELETE FROM messages
        WHERE kind = 0 AND (
            received_ms < :cutoffMs
            OR msg_id NOT IN (
                SELECT msg_id FROM messages WHERE kind = 0
                ORDER BY received_ms DESC LIMIT :retainCount
            )
        )
        """,
    )
    suspend fun pruneChannel(retainCount: Int, cutoffMs: Long): Int
}

@Dao
interface SessionDao {
    @Upsert
    suspend fun upsert(entity: SessionEntity)

    @Query("SELECT * FROM sessions WHERE peer_device_id = :peerDeviceId")
    suspend fun get(peerDeviceId: ByteArray): SessionEntity?
}
