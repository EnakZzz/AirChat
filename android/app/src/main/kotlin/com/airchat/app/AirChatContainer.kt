package com.airchat.app

import android.content.Context
import com.airchat.ble.BleTransport
import com.airchat.data.AirChatDatabase
import com.airchat.data.RoomChatStore
import com.airchat.protocol.AirChatNode
import com.airchat.protocol.BufferLogger
import com.airchat.protocol.ChatStore
import com.airchat.protocol.FanOutLogger
import com.airchat.protocol.SendResult
import com.airchat.protocol.TrustState
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

    /**
     * Also to logcat: without this the protocol layer (LinkSession/AirChatNode) is invisible to
     * `adb logcat`, which made the earlier cross-device failures undiagnosable from the host.
     */
    private val logger = FanOutLogger(AndroidLogSink(), diagnostics)

    val node = AirChatNode(
        store = store,
        transport = transport,
        scope = scope,
        logger = logger,
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
     * `adb shell am start -n <pkg>/<activity> --es airchat_selftest "channel:hi,private:secret"`.
     *
     * Waits for a ready link rather than asking the caller to time it: the link is established by two
     * radios negotiating, so the only reliable trigger is "as soon as we are connected". Only reachable
     * from a debuggable build (see MainActivity).
     *
     * The separator is `,` and not `|` on purpose: `adb shell` hands this string to the device's own
     * shell, which reads an unquoted `|` as a pipe. The extra then arrives truncated at the pipe and
     * half the scripted script silently never runs - which is exactly how a passing private-message
     * path looked like a broken one for two rounds. Whatever the separator, the received spec is also
     * logged so a truncated argument is visible in the log rather than only as a missing message.
     */
    fun runSelfTest(spec: String) {
        logger.log(TAG, "selftest spec received: $spec")
        // The harness drives the app the way a user does, and a user has to ask for a scan before
        // anybody is discoverable. The window is longer than a person needs so discovery cannot
        // expire halfway through a 90 s run.
        node.startScan(DEBUG_SCAN_WINDOW_MS)
        scope.launch {
            val ready = withTimeoutOrNull(SELF_TEST_TIMEOUT_MS) {
                node.state.first { it.readyLinkCount > 0 }
            }
            if (ready == null) return@launch

            for (part in spec.split(SEPARATOR)) {
                val separator = part.indexOf(':')
                if (separator <= 0) continue
                val kind = part.substring(0, separator).trim()
                val text = part.substring(separator + 1)
                // The outcome is logged rather than ignored: a rejected send is otherwise completely
                // invisible and looks identical to "the peer never received it".
                when (kind) {
                    "channel" -> logger.log(TAG, "channel " + describe(node.postChannelMessage(text)))
                    "private" -> {
                        val peer = node.state.value.links
                            .firstOrNull { it.ready && it.peerIdHex != null }
                            ?.peerIdHex
                        if (peer == null) {
                            logger.log(TAG, "private skipped: no ready link")
                        } else {
                            logger.log(TAG, "private " + describe(node.sendPrivateMessage(peer, text)))
                        }
                    }
                }
            }
        }
    }

    /**
     * The reason a send was refused, spelled out.
     *
     * `SendResult` has no useful `toString`, and the reason is the whole diagnosis: "rejected
     * because the user marked this peer's code as mismatched" and "rejected because the peer is not
     * nearby" look identical when all the log says is the class name.
     */
    private fun describe(result: SendResult): String = when (result) {
        is SendResult.Sent -> "sent"
        is SendResult.Rejected -> "rejected: " + result.reason
    }

    /**
     * Debug-only: forgets every safety-code verdict.
     *
     * A confirmed code is deliberately remembered and not offered again, so observing a first
     * comparison normally means clearing app data - which also clears the Bluetooth permission and
     * leaves the suite waiting on a system dialog. This keeps the two concerns apart.
     */
    fun clearTrustVerdicts() {
        scope.launch {
            val peers = store.listPeers()
            for (peer in peers) store.setTrustState(peer.deviceId, TrustState.UNVERIFIED)
            logger.log(TAG, "cleared ${peers.size} trust verdict(s)")
        }
    }

    /** Debug-only: presses 扫描, which is how any of the harness phases begins. */
    fun startDebugScan() {
        logger.log(TAG, "debug scan requested")
        node.startScan(DEBUG_SCAN_WINDOW_MS)
    }

    /**
     * Debug-only: taps the first person that appears in the nearby list, exactly the way a user
     * would, and stops there. The safety-code prompt that follows is the assertion the harness
     * makes, so this deliberately does not confirm anything on the user's behalf.
     */
    fun connectFirstPeer() {
        node.startScan(DEBUG_SCAN_WINDOW_MS)
        scope.launch {
            val peer = withTimeoutOrNull(SELF_TEST_TIMEOUT_MS) {
                node.state.first { it.nearby.isNotEmpty() }.nearby.first()
            }
            if (peer == null) {
                logger.log(TAG, "connect-first found nobody nearby")
                return@launch
            }
            logger.log(TAG, "connect-first -> " + node.requestConnect(peer.label))
        }
    }

    private companion object {
        const val TAG = "SelfTest"
        const val SEPARATOR = ","
        const val SELF_TEST_TIMEOUT_MS = 45_000L

        /** Debug hooks keep looking for as long as a harness run may last. */
        const val DEBUG_SCAN_WINDOW_MS = 300_000L
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
