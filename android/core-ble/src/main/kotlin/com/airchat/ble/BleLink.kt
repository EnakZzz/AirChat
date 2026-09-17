package com.airchat.ble

import android.annotation.SuppressLint
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattDescriptor
import android.bluetooth.BluetoothGattServer
import android.bluetooth.BluetoothStatusCodes
import android.os.Build
import com.airchat.protocol.AirChatProtocol
import com.airchat.protocol.AirChatLogger
import com.airchat.protocol.Link
import java.util.UUID

/**
 * One BLE GATT connection, exposed to the protocol layer as a [Link].
 *
 * Android hard requirements encoded here:
 * - **GATT operations are serialised.** The stack silently drops a second operation while one is
 *   in flight, so setup runs as a queue where each step is advanced only by its own completion
 *   callback, and data writes are paced by a single in-flight slot.
 * - **Nothing may be written before the link is usable.** The node calls `send` as soon as a
 *   link is announced, so frames are queued until [readyForTraffic] becomes true.
 * - **Early inbound bytes must survive.** A peer may write to CH_RX before our handler is
 *   registered (or before we subscribe); those bytes are buffered in [pendingInbound].
 *
 * Every method is invoked on the transport's single BLE handler thread. That single-threaded
 * discipline is what allows `LinkSession` to remain lock-free.
 *
 * Permission note: `BleTransport` verifies BLUETOOTH_SCAN / BLUETOOTH_CONNECT /
 * BLUETOOTH_ADVERTISE before it opens a GATT server or a connection, and re-verifies whenever the
 * adapter state changes, so every call below is reachable only with the permission granted.
 * BleLink itself has no Context and therefore cannot re-check; the suppression is deliberate.
 */
@SuppressLint("MissingPermission")
internal class BleLink(
    override val linkId: String,
    override val isCentral: Boolean,
    override val peerLabel: String,
    private val logger: AirChatLogger,
    private val onDisconnected: (BleLink, String) -> Unit,
) : Link {

    @Volatile
    override var mtu: Int = AirChatProtocol.DEFAULT_MTU
        private set

    private var inbound: ((ByteArray) -> Unit)? = null
    private val pendingInbound = ArrayDeque<ByteArray>()

    private class Chunk(val control: Boolean, val bytes: ByteArray)

    private val outbound = ArrayDeque<Chunk>()
    private val setupOps = ArrayDeque<(BleLink) -> Boolean>()
    private var inFlight = false
    private var setupStepInFlight = false

    var closed = false
        private set

    /** True once the peer can actually receive frames on both channels. */
    var readyForTraffic = false
        private set

    // Central-role handles.
    var gatt: BluetoothGatt? = null
    private var ctrlChar: BluetoothGattCharacteristic? = null
    private var txChar: BluetoothGattCharacteristic? = null
    private var rxChar: BluetoothGattCharacteristic? = null

    // Peripheral-role handles.
    var server: BluetoothGattServer? = null
    private var device: BluetoothDevice? = null

    private var ctrlSubscribed = false
    private var txSubscribed = false

    val address: String get() = peerLabel

    // ------------------------------------------------------------------ Link

    override fun setInboundHandler(handler: (ByteArray) -> Unit) {
        inbound = handler
        if (pendingInbound.isNotEmpty()) {
            val flush = pendingInbound.toList()
            pendingInbound.clear()
            for (bytes in flush) handler(bytes)
        }
    }

    override fun send(bytes: ByteArray, control: Boolean): Boolean {
        if (closed) return false
        if (outbound.size >= MAX_QUEUED_CHUNKS) {
            logger.log(TAG, "outbound queue full on $linkId; refusing chunk")
            return false
        }
        outbound.addLast(Chunk(control, bytes))
        drainOutbound()
        return true
    }

    override fun close() {
        if (closed) return
        closed = true
        releaseGatt()
        onDisconnected(this, "closed locally")
    }

    // ---------------------------------------------------- peripheral wiring

    /** Peripheral role: bind the shared GATT server, the remote device and our characteristics. */
    fun bindPeripheral(
        server: BluetoothGattServer,
        device: BluetoothDevice,
        ctrl: BluetoothGattCharacteristic,
        tx: BluetoothGattCharacteristic,
    ) {
        this.server = server
        this.device = device
        this.ctrlChar = ctrl
        this.txChar = tx
        // The peripheral cannot send until the central subscribes, so readiness is driven by
        // the CCCD writes rather than by an MTU exchange.
        evaluatePeripheralReadiness()
    }

    // -------------------------------------------------------- central wiring

    /** Central role: connection established; begin the serialised setup sequence. */
    fun onGattConnected(connectedGatt: BluetoothGatt) {
        if (closed) return
        gatt = connectedGatt
        logger.log(TAG, "central setup: requesting service discovery on $linkId")
        setupOps.addLast { link ->
            link.gatt?.discoverServices() ?: false
        }
        nextSetupOp()
    }

    fun onServicesDiscovered(status: Int) {
        if (closed) return
        val gatt = gatt ?: return
        if (status != BluetoothGatt.GATT_SUCCESS) {
            logger.log(TAG, "service discovery failed on $linkId (status=$status)")
            close()
            return
        }
        val service = gatt.getService(BleUuids.serviceUuid())
        if (service == null) {
            logger.log(TAG, "peer $linkId does not expose the AirChat service")
            close()
            return
        }
        ctrlChar = service.getCharacteristic(BleUuids.ctrlUuid())
        txChar = service.getCharacteristic(BleUuids.txUuid())
        rxChar = service.getCharacteristic(BleUuids.rxUuid())
        if (ctrlChar == null || txChar == null || rxChar == null) {
            logger.log(TAG, "peer $linkId is missing a required characteristic")
            close()
            return
        }

        logger.log(
            TAG,
            "central setup: discovery ok on $linkId (status=$status, characteristics=" +
                "${service.characteristics?.size ?: 0})",
        )
        // Enqueue the remaining steps before releasing the discovery step.
        setupOps.addLast { link -> link.subscribe(link.ctrlChar) }
        setupOps.addLast { link -> link.subscribe(link.txChar) }
        setupOps.addLast { link -> link.gatt?.requestMtu(AirChatProtocol.PREFERRED_MTU) ?: false }
        completeSetupStep()
    }

    private fun subscribe(characteristic: BluetoothGattCharacteristic?): Boolean {
        val gatt = gatt ?: return false
        val char = characteristic ?: return false
        logger.log(TAG, "central setup: subscribing ${char.uuid} on $linkId")
        if (!gatt.setCharacteristicNotification(char, true)) {
            logger.log(TAG, "central setup: setCharacteristicNotification failed for ${char.uuid}")
            return false
        }
        val cccd = char.getDescriptor(BleUuids.CCCD) ?: run {
            logger.log(TAG, "central setup: no CCCD on ${char.uuid}")
            return false
        }
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            gatt.writeDescriptor(cccd, BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE) ==
                BluetoothStatusCodes.SUCCESS
        } else {
            cccd.value = BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE
            @Suppress("DEPRECATION")
            gatt.writeDescriptor(cccd)
        }
    }

    fun onDescriptorWritten(status: Int) {
        if (closed) return
        if (status != BluetoothGatt.GATT_SUCCESS) {
            logger.log(TAG, "CCCD write failed on $linkId (status=$status)")
            close()
            return
        }
        completeSetupStep()
    }

    fun onMtuChanged(newMtu: Int) {
        mtu = newMtu
        logger.log(TAG, "mtu for $linkId is now $newMtu")
        completeSetupStep()
    }

    /** Peripheral role: a central subscribed (or unsubscribed) to one of our characteristics. */
    fun onSubscriptionChanged(characteristicUuid: UUID, enabled: Boolean) {
        when (characteristicUuid) {
            BleUuids.ctrlUuid() -> ctrlSubscribed = enabled
            BleUuids.txUuid() -> txSubscribed = enabled
            else -> return
        }
        evaluatePeripheralReadiness()
    }

    private fun evaluatePeripheralReadiness() {
        if (isCentral || closed) return
        if (ctrlSubscribed && txSubscribed && !readyForTraffic) {
            readyForTraffic = true
            logger.log(TAG, "peripheral $linkId ready (central subscribed to CTRL and TX)")
            drainOutbound()
        }
    }

    // -------------------------------------------------------------- inbound

    fun onInbound(value: ByteArray?) {
        if (closed || value == null || value.isEmpty()) return
        val handler = inbound
        if (handler != null) handler(value) else pendingInbound.addLast(value)
    }

    // ------------------------------------------------------------- outbound

    private fun drainOutbound() {
        if (closed || inFlight || outbound.isEmpty() || !readyForTraffic) return

        val chunk = outbound.first()
        val written = if (isCentral) writeAsCentral(chunk) else notifyAsPeripheral(chunk)
        if (written) {
            outbound.removeFirst()
            inFlight = true
        } else {
            // Leave it at the head and retry from the next callback instead of corrupting the
            // frame stream by skipping a chunk.
            logger.log(TAG, "write to $linkId deferred")
        }
    }

    private fun writeAsCentral(chunk: Chunk): Boolean {
        val gatt = gatt ?: return false
        val char = (if (chunk.control) ctrlChar else rxChar) ?: return false
        // write-with-response gives ATT-level flow control; see docs/protocol.md section 6.3.
        char.writeType = BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT
        char.value = chunk.bytes
        return gatt.writeCharacteristic(char)
    }

    private fun notifyAsPeripheral(chunk: Chunk): Boolean {
        val server = server ?: return false
        val device = device ?: return false
        val char = (if (chunk.control) ctrlChar else txChar) ?: return false
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            // Pass the value explicitly so concurrent centrals cannot race on char.value.
            server.notifyCharacteristicChanged(device, char, false, chunk.bytes) ==
                BluetoothStatusCodes.SUCCESS
        } else {
            @Suppress("DEPRECATION")
            char.value = chunk.bytes
            @Suppress("DEPRECATION")
            server.notifyCharacteristicChanged(device, char, false)
        }
    }

    /** Central role: our write completed (or failed). */
    fun onCharacteristicWritten(status: Int) {
        inFlight = false
        if (status != BluetoothGatt.GATT_SUCCESS) {
            logger.log(TAG, "write to $linkId failed (status=$status)")
        }
        drainOutbound()
    }

    /** Peripheral role: our notification was delivered (or failed). */
    fun onNotificationSent(status: Int) {
        inFlight = false
        if (status != BluetoothGatt.GATT_SUCCESS) {
            logger.log(TAG, "notification to $linkId failed (status=$status)")
        }
        drainOutbound()
    }

    // -------------------------------------------------------------- setup

    private fun nextSetupOp() {
        if (closed) return
        if (setupStepInFlight) return
        val op = setupOps.removeFirstOrNull() ?: run {
            markCentralReady()
            return
        }
        setupStepInFlight = true
        if (!op(this)) {
            logger.log(TAG, "setup step failed to start on $linkId")
            setupStepInFlight = false
            close()
        }
    }

    /** Releases the in-flight setup step so the next one can start. */
    private fun completeSetupStep() {
        setupStepInFlight = false
        nextSetupOp()
    }

    private fun markCentralReady() {
        logger.log(TAG, "central setup: all steps done on $linkId (mtu=$mtu)")
        if (isCentral && !readyForTraffic && !closed) {
            readyForTraffic = true
            logger.log(TAG, "central $linkId ready (mtu=$mtu)")
            drainOutbound()
        }
    }

    // ------------------------------------------------------------ teardown

    fun onGattDisconnected(status: Int) {
        if (closed) return
        closed = true
        releaseGatt()
        onDisconnected(this, "disconnected (status=$status)")
    }

    private fun releaseGatt() {
        runCatching { gatt?.close() }
        gatt = null
    }

    private companion object {
        const val TAG = "BleLink"

        /**
         * Bounded so a stalled link cannot grow without limit. Chunks are at most 512 bytes, so
         * this caps a link's backlog at roughly 256 KB.
         */
        const val MAX_QUEUED_CHUNKS = 512
    }
}
