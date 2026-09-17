package com.airchat.app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import com.airchat.protocol.NodeState
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeoutOrNull

/**
 * Keeps the BLE session alive while the UI is backgrounded or destroyed.
 *
 * Declared with `foregroundServiceType="connectedDevice"`, which is the Android 14+ requirement
 * for an app that maintains a connection to a nearby device. The service is deliberately thin:
 * all Bluetooth state lives in [AirChatContainer].
 */
class AirChatLinkService : Service() {

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private lateinit var container: AirChatContainer

    override fun onCreate() {
        super.onCreate()
        container = (application as AirChatApp).container
        createNotificationChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        startForeground(
            NOTIFICATION_ID,
            buildNotification(getString(R.string.status_scanning)),
            ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE,
        )
        scope.launch {
            container.ensureStarted()
            container.node.state.collect { state -> updateNotification(state) }
        }
        // START_STICKY: if the process is killed, Android restarts the service and the node
        // re-advertises. Peer links are re-established by the normal discovery path.
        return START_STICKY
    }

    override fun onDestroy() {
        // Bounded so a stuck BLE teardown cannot block the main thread indefinitely.
        runBlocking { withTimeoutOrNull(SHUTDOWN_TIMEOUT_MS) { container.stop() } }
        scope.cancel()
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    // ------------------------------------------------------------ notification

    private fun createNotificationChannel() {
        val manager = getSystemService(NotificationManager::class.java) ?: return
        val existing = manager.getNotificationChannel(CHANNEL_ID)
        if (existing != null) return
        val channel = NotificationChannel(
            CHANNEL_ID,
            getString(R.string.service_channel_name),
            NotificationManager.IMPORTANCE_LOW,
        ).apply {
            description = getString(R.string.service_channel_description)
            setShowBadge(false)
        }
        manager.createNotificationChannel(channel)
    }

    private fun buildNotification(text: String): Notification {
        val contentIntent = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        return Notification.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_stat_airchat)
            .setContentTitle(getString(R.string.app_name))
            .setContentText(text)
            .setContentIntent(contentIntent)
            .setOngoing(true)
            .setShowWhen(false)
            .setCategory(Notification.CATEGORY_SERVICE)
            .build()
    }

    private fun updateNotification(state: NodeState) {
        val connected = state.readyLinkCount
        val text = when {
            connected > 0 -> "已连接 $connected 个附近设备"
            state.nearby.isNotEmpty() -> "发现 ${state.nearby.size} 个附近设备，正在连接…"
            else -> getString(R.string.status_scanning)
        }
        val manager = getSystemService(NotificationManager::class.java) ?: return
        manager.notify(NOTIFICATION_ID, buildNotification(text))
    }

    companion object {
        const val NOTIFICATION_ID = 0x41C
        private const val CHANNEL_ID = "airchat-link"
        private const val SHUTDOWN_TIMEOUT_MS = 2_000L

        fun start(context: android.content.Context) {
            val intent = Intent(context, AirChatLinkService::class.java)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        fun stop(context: android.content.Context) {
            context.stopService(Intent(context, AirChatLinkService::class.java))
        }
    }
}
