package com.airchat.app

import android.util.Log
import com.airchat.protocol.AirChatNode
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch

/**
 * Emits one machine-readable status line per second so a host-side harness can verify a
 * two-device session without screenshots or UI automation.
 *
 * Line format (identical on iOS, see ios/AirChat/DiagnosticStateReporter.swift):
 *
 * `AIRCHAT_STATE {"platform":"android","self":"<32 hex>","status":"scanning","nearby":1,
 *                  "links":[{"peer":"<32 hex>","ready":true,"central":true,"mtu":23,"code":"123456"}]}`
 *
 * A fixed 1 Hz heartbeat is deliberate: it is bounded (no log spam during discovery churn) and it
 * doubles as liveness detection, so the harness can tell "app not running" from "no peer found".
 */
class DiagnosticStateReporter(
    private val node: AirChatNode,
    private val scope: CoroutineScope,
) {
    fun start() {
        scope.launch {
            while (isActive) {
                Log.i(TAG, snapshot())
                delay(INTERVAL_MS)
            }
        }
    }

    private fun snapshot(): String {
        val state = node.state.value
        return buildString {
            append("AIRCHAT_STATE {")
            append("\"platform\":\"android\",")
            append("\"self\":\"").append(state.deviceIdHex).append("\",")
            append("\"status\":\"").append(state.status.name.lowercase()).append("\",")
            append("\"nearby\":").append(state.nearby.size).append(',')
            append("\"links\":[")
            state.links.forEachIndexed { index, link ->
                if (index > 0) append(',')
                append("{\"peer\":")
                if (link.peerIdHex == null) append("null") else append('"').append(link.peerIdHex).append('"')
                append(",\"ready\":").append(link.ready)
                append(",\"central\":").append(link.isCentral)
                append(",\"mtu\":").append(link.mtu)
                append(",\"code\":")
                if (link.safetyCode == null) append("null") else append('"').append(link.safetyCode).append('"')
                append('}')
            }
            append("]}")
        }
    }

    private companion object {
        const val TAG = "AirChat/State"
        const val INTERVAL_MS = 1_000L
    }
}
