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
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull
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
        // Also to logcat: without this the protocol layer (LinkSession/AirChatNode) is invisible to
        // `adb logcat`, which made the earlier cross-device failures undiagnosable from the host.
        logger = FanOutLogger(AndroidLogSink(), diagnostics),
    )

    /** Machine-readable heartbeat consumed by tools/cross_device_test.py. */
    private val reporter = DiagnosticStateReporter(node, scope)

    private val lifecycleMutex = Mutex()
    private var started = false

    init {
        // Started here rather than in [ensureStarted] so the heartbeat also runs when the service
        // has not been started yet: that lets the harness distinguish a dead app from a
        // not-yet-connected one.
        reporter.start()
    }

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
     * Host-driven message injection for tools/cross_device_test.py, e.g.
     * `adb shell am start -n <pkg>/<activity> --es airchat_selftest "channel:hi|private:secret"`.
     *
     * Waits for a ready link rather than asking the caller to time it: the link is established by two
     * radios negotiating, so the only reliable trigger is "as soon as we are connected". Only reachable
     * from a debuggable build (see MainActivity).
     */
    fun runSelfTest(spec: String) {
        scope.launch {
            val ready = withTimeoutOrNull(SELF_TEST_TIMEOUT_MS) {
                node.state.first { it.readyLinkCount > 0 }
            }
            if (ready == null) return@launch

            for (part in spec.split('|')) {
                val separator = part.indexOf(':')
                if (separator <= 0) continue
                val kind = part.substring(0, separator).trim()
                val text = part.substring(separator + 1)
                when (kind) {
                    "channel" -> node.postChannelMessage(text)
                    "private" -> node.state.value.links
                        .firstOrNull { it.ready && it.peerIdHex != null }
                        ?.peerIdHex
                        ?.let { node.sendPrivateMessage(it, text) }
                }
            }
        }
    }

    private companion object {
        const val SELF_TEST_TIMEOUT_MS = 45_000L
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
