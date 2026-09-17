package com.airchat.data

import android.content.Context
import androidx.room.Database
import androidx.room.Room
import androidx.room.RoomDatabase

@Database(
    entities = [
        IdentityEntity::class,
        PeerEntity::class,
        MessageEntity::class,
        SessionEntity::class,
    ],
    version = 1,
    exportSchema = true,
)
abstract class AirChatDatabase : RoomDatabase() {
    abstract fun identityDao(): IdentityDao
    abstract fun peerDao(): PeerDao
    abstract fun messageDao(): MessageDao
    abstract fun sessionDao(): SessionDao

    companion object {
        private const val NAME = "airchat.db"

        @Volatile
        private var instance: AirChatDatabase? = null

        fun get(context: Context): AirChatDatabase =
            instance ?: synchronized(this) {
                instance ?: build(context.applicationContext).also { instance = it }
            }

        private fun build(context: Context): AirChatDatabase =
            Room.databaseBuilder(context, AirChatDatabase::class.java, NAME)
                // WAL keeps reads from blocking the link threads while a write is in flight.
                .setJournalMode(JournalMode.WRITE_AHEAD_LOGGING)
                .build()
    }
}
