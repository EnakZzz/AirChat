package com.airchat.app

import android.Manifest
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.content.ContextCompat

/**
 * Owns the runtime permission and adapter-state decisions for the UI.
 *
 * Keeping this out of the composables means the "why can I not connect" logic is testable and
 * the UI only renders what this reports.
 */
class RadioController(
    private val context: Context,
    private val container: AirChatContainer,
) {
    val bluetoothPermissions: Array<String> = arrayOf(
        Manifest.permission.BLUETOOTH_SCAN,
        Manifest.permission.BLUETOOTH_CONNECT,
        Manifest.permission.BLUETOOTH_ADVERTISE,
    )

    /**
     * Android 13+ requires an explicit notification permission for the foreground service
     * notification. It is requested alongside the Bluetooth permissions.
     */
    fun allRuntimePermissions(): Array<String> {
        val base = bluetoothPermissions.toMutableList()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            base += Manifest.permission.POST_NOTIFICATIONS
        }
        return base.toTypedArray()
    }

    fun hasBluetoothPermissions(): Boolean = bluetoothPermissions.all { granted(it) }

    fun hasNotificationPermission(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return true
        return granted(Manifest.permission.POST_NOTIFICATIONS)
    }

    fun missingBluetoothPermissions(): List<String> = bluetoothPermissions.filterNot { granted(it) }

    fun isBluetoothSupported(): Boolean = adapter() != null

    fun isBluetoothEnabled(): Boolean = adapter()?.isEnabled == true

    /** `ACTION_REQUEST_ENABLE` is the only sanctioned way for an app to ask for Bluetooth. */
    fun bluetoothEnableIntent(): Intent = Intent(BluetoothAdapter.ACTION_REQUEST_ENABLE)

    fun startLinkService() = AirChatLinkService.start(context)

    fun stopLinkService() = AirChatLinkService.stop(context)

    fun refreshRadio() = container.refreshRadio()

    private fun granted(permission: String): Boolean =
        ContextCompat.checkSelfPermission(context, permission) == PackageManager.PERMISSION_GRANTED

    private fun adapter(): BluetoothAdapter? =
        context.getSystemService(BluetoothManager::class.java)?.adapter
}
