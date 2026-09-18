package com.airchat.app

import android.util.Log
import com.airchat.protocol.AirChatNode
import com.airchat.protocol.MessageDirection
import com.airchat.protocol.MessageKind
import com.airchat.protocol.MessageStatus
import com.airchat.protocol.NodeEvent
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
    // Counters proving messages actually crossed the link. Inbound counts come from stored messages
    // and `delivered` from the DELIVERY_ACK that upgrades an outgoing message, so a non-zero
    // `delivered` on both sides exercises the notification path in both directions.
    private val lock = Any()
    private var channelInbound = 0
    private var verifyPrompts = 0
    private var privateInbound = 0
    private var deliveredOutbound = 0
    private var lastChannelText = ""
    private var lastPrivateText = ""

    fun start() {
        scope.launch {
            node.events.collect { event ->
                when (event) {
                    is NodeEvent.MessageStored -> {
                        val record = event.record
                        if (record.direction != MessageDirection.INCOMING) return@collect
                        val text = record.text.take(40)
                        synchronized(lock) {
                            when (record.kind) {
                                MessageKind.CHANNEL -> { channelInbound++; lastChannelText = text }
                                MessageKind.PRIVATE -> { privateInbound++; lastPrivateText = text }
                            }
                        }
                    }

                    is NodeEvent.MessageStatusChanged -> {
                        if (event.status == MessageStatus.DELIVERED) {
                            synchronized(lock) { deliveredOutbound++ }
                        }
                    }

                    is NodeEvent.VerifyRequested -> {
                        // Proves the tap-driven prompt path ran, which the message counters cannot.
                        synchronized(lock) { verifyPrompts++ }
                    }

                    else -> Unit
                }
            }
        }
        scope.launch {
            while (isActive) {
                Log.i(TAG, snapshot())
                delay(INTERVAL_MS)
            }
        }
    }

    private fun snapshot(): String {
        val state = node.state.value
        // Read individually so each value keeps its concrete type: a combined list would widen them
        // all to Any and the JSON assembly would not compile.
        val channel = synchronized(lock) { channelInbound }
        val priv = synchronized(lock) { privateInbound }
        val delivered = synchronized(lock) { deliveredOutbound }
        val lastChannel = synchronized(lock) { lastChannelText }
        val lastPrivate = synchronized(lock) { lastPrivateText }
        return buildString {
            append("AIRCHAT_STATE {")
            append("\"platform\":\"android\",")
            append("\"self\":\"").append(state.deviceIdHex).append("\",")
            append("\"status\":\"").append(state.status.name.lowercase()).append("\",")
            append("\"nearby\":").append(state.nearby.size).append(',')
            append("\"nearbyLabels\":[").append(
                state.nearby.joinToString(",") { "\"" + escape(it.label) + "\"" },
            ).append("],")
            append("\"verifyPrompts\":").append(verifyPrompts).append(',')
            append("\"channel\":").append(channel).append(',')
            append("\"private\":").append(priv).append(',')
            append("\"delivered\":").append(delivered).append(',')
            append("\"lastChannel\":\"").append(escape(lastChannel)).append("\",")
            append("\"lastPrivate\":\"").append(escape(lastPrivate)).append("\",")
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

    private fun escape(value: String): String =
        value.replace("\\", "\\\\").replace("\"", "\\\"")

    private companion object {
        const val TAG = "AirChat/State"
        const val INTERVAL_MS = 1_000L
    }
}
