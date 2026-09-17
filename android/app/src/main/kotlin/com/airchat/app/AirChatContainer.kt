package com.airchat.app

import android.content.Context
import com.airchat.ble.BleTransport
import com.airchat.data.AirChatDatabase
import com.airchat.data.RoomChatStore
import com.airchat.protocol.AirChatNode
import com.airchat.protocol.BufferLogger
import com.airchat.protocol.ChatStore
import com.airchat.protocol.FanOutLogger
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

/**
 * Application-scoped composition root.
 *
 * The container lives as long as the process and owns the single [AirChatNode], which in turn
 * owns every Bluetooth object. [AirChatLinkService] only keeps the process alive with a
 * foreground notification and mirrors the node state into it; keeping the object graph here
 * instead of inside the service avoids a binder layer and the lifecycle bugs that come with it.
 */
class AirChatContainer(context: Context) {

    private val appContext = context.applicationContext

    /** Bounded in-memory log tail, surfaced by the settings screen for on-device debugging. */
    val diagnostics = BufferLogger()

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)

    private val database = AirChatDatabase.get(appContext)

    val store: ChatStore = RoomChatStore(database)

    private val transport = BleTransport(appContext, FanOutLogger(AndroidLogSink(), diagnostics))

    val node = AirChatNode(
        store = store,
        transport = transport,
        scope = scope,
        logger = diagnostics,
    )

    private val lifecycleMutex = Mutex()
    private var started = false

    suspend fun ensureStarted() {
        lifecycleMutex.withLock {
            if (started) return
            started = true
            node.start()
        }
    }

    suspend fun stop() {
        lifecycleMutex.withLock {
            if (!started) return
            started = false
            node.stop()
        }
    }

    /**
     * Re-evaluates Bluetooth permissions and adapter state. Called after the user grants
     * permissions or returns from the system Bluetooth dialog.
     */
    fun refreshRadio() {
        transport.refresh()
    }

    fun logTail(): List<String> = diagnostics.snapshot()
}
