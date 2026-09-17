package com.airchat.ble

import android.Manifest
import android.annotation.SuppressLint
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattDescriptor
import android.bluetooth.BluetoothGattServer
import android.bluetooth.BluetoothGattServerCallback
import android.bluetooth.BluetoothGattService
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.bluetooth.le.AdvertiseCallback
import android.bluetooth.le.AdvertiseData
import android.bluetooth.le.AdvertiseSettings
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanFilter
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.SystemClock
import androidx.core.content.ContextCompat
import com.airchat.protocol.AirChatCrypto
import com.airchat.protocol.AirChatLogger
import com.airchat.protocol.AirChatProtocol
import com.airchat.protocol.Capabilities
import com.airchat.protocol.ChatStatus
import com.airchat.protocol.Transport
import com.airchat.protocol.TransportEvent
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.asSharedFlow

/**
 * Android BLE transport: advertises, scans, hosts a GATT server and opens GATT client
 * connections, implementing the discovery and connect-direction rules of
 * `docs/protocol.md` sections 4 and 5.
 *
 * Concurrency model: every Bluetooth callback is posted onto a single dedicated handler thread,
 * so [BleLink] and the protocol's `LinkSession` are only ever touched from one thread.
 *
 * Requires (checked at runtime, never assumed):
 * `BLUETOOTH_SCAN`, `BLUETOOTH_CONNECT`, `BLUETOOTH_ADVERTISE`.
 *
 * Device note: BLE peripheral and scanning behaviour cannot be exercised on an emulator; this
 * transport must be validated on physical hardware.
 */
@SuppressLint("MissingPermission")
class BleTransport(
    context: Context,
    private val logger: AirChatLogger = AirChatLogger.NOOP,
) : Transport {

    private val appContext: Context = context.applicationContext
    private val bluetoothManager: BluetoothManager? =
        appContext.getSystemService(BluetoothManager::class.java)

    private val handlerThread = HandlerThread("airchat-ble").apply { start() }
    private val handler = Handler(handlerThread.looper)

    private val _events = MutableSharedFlow<TransportEvent>(extraBufferCapacity = 256)
    override val events: SharedFlow<TransportEvent> = _events.asSharedFlow()

    override val ticket: Int = AirChatCrypto.randomTicket()

    private var advertisedProtocolVersion = AirChatProtocol.VERSION
    private var advertisedCapabilities = Capabilities.ALL

    private var running = false
    private var scanning = false
    private var advertised = false

    private var gattServer: BluetoothGattServer? = null
    private var ctrlCharacteristic: BluetoothGattCharacteristic? = null
    private var txCharacteristic: BluetoothGattCharacteristic? = null
    private var rxCharacteristic: BluetoothGattCharacteristic? = null

    /** All live links, keyed by the role-scoped link id. */
    private val links = LinkedHashMap<String, BleLink>()

    /** Live links by peer address, so stack callbacks (which only carry a device) can find them. */
    private val linksByAddress = HashMap<String, BleLink>()

    /** Addresses with a connect attempt in flight. */
    private val connecting = HashSet<String>()

    /** GATT objects for in-flight connect attempts, kept so failures can be cleaned up. */
    private val pendingGatt = HashMap<String, BluetoothGatt>()

    private class SeenPeer(val ticket: Int, val firstSeenMs: Long, var lastSeenMs: Long, var rssi: Int?)

    private val seen = HashMap<String, SeenPeer>()
    private val backoffUntil = HashMap<String, Long>()

    private val adapter: BluetoothAdapter? get() = bluetoothManager?.adapter

    // ------------------------------------------------------------- lifecycle

    override suspend fun start() {
        onHandler {
            if (running) return@onHandler
            running = true
            registerAdapterReceiver()
            val problem = diagnoseAdapter()
            if (problem != null) {
                logger.log(TAG, "start blocked: ${problem.message}")
                emit(problem)
                return@onHandler
            }
            logger.log(TAG, "start: adapter ready (ticket=$ticket), opening GATT server and radio")
            openGattServer()
            startAdvertising()
            startScanning()
        }
    }

    override suspend fun stop() {
        onHandler {
            if (!running) return@onHandler
            running = false
            stopScanning()
            stopAdvertising()
            closeGattServer()
            for (link in links.values.toList()) {
                link.close()
            }
            links.clear()
            linksByAddress.clear()
            connecting.clear()
            for (gatt in pendingGatt.values) runCatching { gatt.close() }
            pendingGatt.clear()
            unregisterAdapterReceiver()
            emit(TransportEvent.Status(ChatStatus.STOPPED, "已停止"))
        }
    }

    override fun updatePresence(protocolVersion: Int, capabilities: Int) {
        onHandler {
            advertisedProtocolVersion = protocolVersion
            advertisedCapabilities = capabilities
            // Restart advertising so the presence block reflects the new values.
            if (advertised) {
                stopAdvertising()
                startAdvertising()
            }
        }
    }

    // ------------------------------------------------------------ diagnostics

    /** Returns a status event when the radio cannot be used, or null when it is ready. */
    private fun diagnoseAdapter(): TransportEvent.Status? {
        val adapter = adapter
        if (adapter == null) {
            return TransportEvent.Status(ChatStatus.BLUETOOTH_UNAVAILABLE, "此设备不支持蓝牙")
        }
        if (!adapter.isEnabled) {
            return TransportEvent.Status(ChatStatus.BLUETOOTH_UNAVAILABLE, "请打开蓝牙")
        }
        if (!hasPermissions()) {
            return TransportEvent.Status(ChatStatus.PERMISSION_MISSING, "需要蓝牙权限才能发现附近的人")
        }
        if (!adapter.isMultipleAdvertisementSupported) {
            return TransportEvent.Status(
                ChatStatus.BLUETOOTH_UNAVAILABLE,
                "此设备不支持蓝牙广播，无法被附近的人发现",
            )
        }
        return null
    }

    private fun hasPermissions(): Boolean {
        val required = arrayOf(
            Manifest.permission.BLUETOOTH_SCAN,
            Manifest.permission.BLUETOOTH_CONNECT,
            Manifest.permission.BLUETOOTH_ADVERTISE,
        )
        return required.all {
            ContextCompat.checkSelfPermission(appContext, it) == PackageManager.PERMISSION_GRANTED
        }
    }

    /** Re-runs the checks after the user grants permissions or toggles Bluetooth. */
    fun refresh() {
        onHandler {
            if (!running) return@onHandler
            val problem = diagnoseAdapter()
            if (problem != null) {
                emit(problem)
                stopScanning()
                return@onHandler
            }
            openGattServer()
            startAdvertising()
            startScanning()
        }
    }

    // ----------------------------------------------------------- advertising

    private fun startAdvertising() {
        if (advertised) return
        val advertiser = adapter?.bluetoothLeAdvertiser
        if (advertiser == null) {
            emit(TransportEvent.Status(ChatStatus.BLUETOOTH_UNAVAILABLE, "无法启动蓝牙广播"))
            return
        }

        val settings = AdvertiseSettings.Builder()
            .setAdvertiseMode(AdvertiseSettings.ADVERTISE_MODE_LOW_LATENCY)
            .setTxPowerLevel(AdvertiseSettings.ADVERTISE_TX_POWER_MEDIUM)
            .setConnectable(true)
            .setTimeout(0)
            .build()

        // 3 (flags) + 18 (128-bit service uuid) + 8 (service data) = 29 bytes, inside the
        // legacy 31-byte limit. Never include the device name: it would not fit, and iOS drops
        // it in the background anyway (protocol section 11.3).
        val data = AdvertiseData.Builder()
            .setIncludeDeviceName(false)
            .setIncludeTxPowerLevel(false)
            .addServiceUuid(BleUuids.SERVICE)
            .addServiceData(
                BleUuids.PRESENCE,
                BleUuids.encodePresence(advertisedProtocolVersion, advertisedCapabilities, ticket),
            )
            .build()

        try {
            advertiser.startAdvertising(settings, data, advertiseCallback)
        } catch (error: SecurityException) {
            emit(TransportEvent.Status(ChatStatus.PERMISSION_MISSING, "缺少蓝牙广播权限"))
            logger.log(TAG, "advertising denied: ${error.message}")
        }
    }

    private fun stopAdvertising() {
        if (!advertised) return
        runCatching { adapter?.bluetoothLeAdvertiser?.stopAdvertising(advertiseCallback) }
        advertised = false
    }

    private val advertiseCallback = object : AdvertiseCallback() {
        override fun onStartSuccess(settingsInEffect: AdvertiseSettings?) {
            advertised = true
            logger.log(TAG, "advertising as ticket=$ticket")
            emitStatusIfIdle()
        }

        override fun onStartFailure(errorCode: Int) {
            advertised = false
            val reason = when (errorCode) {
                ADVERTISE_FAILED_DATA_TOO_LARGE -> "广播数据超出长度限制"
                ADVERTISE_FAILED_TOO_MANY_ADVERTISERS -> "广播实例过多"
                ADVERTISE_FAILED_ALREADY_STARTED -> "广播已启动"
                ADVERTISE_FAILED_INTERNAL_ERROR -> "蓝牙广播内部错误"
                ADVERTISE_FAILED_FEATURE_UNSUPPORTED -> "此设备不支持蓝牙广播"
                else -> "启动蓝牙广播失败（$errorCode）"
            }
            logger.log(TAG, "advertise failed: $reason")
            emit(TransportEvent.Status(ChatStatus.FAILED, reason))
        }
    }

    // -------------------------------------------------------------- scanning

    private fun startScanning() {
        if (scanning || !running) return
        if (links.size >= AirChatProtocol.MAX_LINKS) {
            emit(TransportEvent.Status(ChatStatus.NEARBY_FULL, "附近人数已满（上限 ${AirChatProtocol.MAX_LINKS}）"))
            return
        }
        val scanner = adapter?.bluetoothLeScanner
        if (scanner == null) {
            emit(TransportEvent.Status(ChatStatus.BLUETOOTH_UNAVAILABLE, "无法启动蓝牙扫描"))
            return
        }
        val filters = listOf(ScanFilter.Builder().setServiceUuid(BleUuids.SERVICE).build())
        val settings = ScanSettings.Builder()
            .setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY)
            .setCallbackType(ScanSettings.CALLBACK_TYPE_ALL_MATCHES)
            .setMatchMode(ScanSettings.MATCH_MODE_AGGRESSIVE)
            .setReportDelay(0)
            .setLegacy(true)
            .build()
        try {
            scanner.startScan(filters, settings, scanCallback)
            scanning = true
            emitStatusIfIdle()
        } catch (error: SecurityException) {
            emit(TransportEvent.Status(ChatStatus.PERMISSION_MISSING, "缺少蓝牙扫描权限"))
            logger.log(TAG, "scan denied: ${error.message}")
        }
    }

    private fun stopScanning() {
        if (!scanning) return
        runCatching { adapter?.bluetoothLeScanner?.stopScan(scanCallback) }
        scanning = false
    }

    private val scanCallback = object : ScanCallback() {
        override fun onScanResult(callbackType: Int, result: ScanResult) {
            onHandler { handleScanResult(result) }
        }

        override fun onBatchScanResults(results: MutableList<ScanResult>) {
            onHandler { results.forEach { handleScanResult(it) } }
        }

        override fun onScanFailed(errorCode: Int) {
            onHandler {
                scanning = false
                logger.log(TAG, "scan failed ($errorCode)")
                emit(TransportEvent.Status(ChatStatus.FAILED, "蓝牙扫描失败（$errorCode）"))
            }
        }
    }

    private fun handleScanResult(result: ScanResult) {
        if (!running) return
        val device = result.device ?: return
        val address = device.address ?: return
        val presence = BleUuids.decodePresence(result.scanRecord?.getServiceData(BleUuids.PRESENCE))

        // The presence block is an optional, non-authoritative hint (docs/protocol.md section 4):
        // iOS cannot advertise one at all, so a peer without it must still be considered rather
        // than ignored. Derive a pseudo-ticket from the peer address; it only has to be stable
        // within one encounter. A wrong guess costs at most one redundant connection, because the
        // SCAN_RETRY_AFTER_MS rule guarantees someone eventually connects and the post-handshake
        // dedupe (section 5.4) drops the extra link.
        val peerAdvertisesTicket = presence != null
        val peerTicket = presence?.ticket ?: (address.hashCode() and 0xFFFF)

        val now = SystemClock.elapsedRealtime()
        val entry = seen[address]
        if (entry == null) {
            seen[address] = SeenPeer(peerTicket, now, now, result.rssi)
        } else {
            entry.lastSeenMs = now
            entry.rssi = result.rssi
        }

        emit(
            TransportEvent.PeerSeen(
                peerLabel = address,
                protocolVersion = presence?.protocolVersion ?: 0,
                capabilities = presence?.capabilities ?: 0,
                ticket = peerTicket,
                rssi = result.rssi,
            ),
        )

        considerConnecting(device, address, peerTicket, peerAdvertisesTicket, now)
    }

    /**
     * Protocol 5.3: connect only when our ticket is smaller, unless the peer has been visible for
     * longer than the fallback window without connecting to us (which means it cannot, e.g. it is
     * already at its link cap).
     */
    private fun considerConnecting(
        device: BluetoothDevice,
        address: String,
        peerTicket: Int,
        peerAdvertisesTicket: Boolean,
        now: Long,
    ) {
        if (linksByAddress.containsKey(address) || connecting.contains(address)) return
        if (links.size + connecting.size >= AirChatProtocol.MAX_LINKS) return
        if (now < (backoffUntil[address] ?: 0L)) return

        val firstSeen = seen[address]?.firstSeenMs ?: now
        // Direction policy, see docs/protocol.md section 5.3.1.
        //
        // A peer that advertises no presence block (currently only iOS can be in that state)
        // cannot take part in a shared ticket comparison, so comparing against an invented
        // pseudo-ticket would just be a coin flip that both sides can lose - producing the
        // connect/disconnect storm that stopped handshakes from completing. Such a peer is
        // assumed unable to initiate, so we do it immediately.
        val weShouldInitiate = !peerAdvertisesTicket ||
            ticket < peerTicket ||
            now - firstSeen >= AirChatProtocol.SCAN_RETRY_AFTER_MS
        if (!weShouldInitiate) return

        connecting.add(address)
        val gatt = try {
            device.connectGatt(appContext, false, gattCallback, BluetoothDevice.TRANSPORT_LE)
        } catch (error: SecurityException) {
            logger.log(TAG, "connect denied: ${error.message}")
            null
        }
        if (gatt == null) {
            connecting.remove(address)
            backoffUntil[address] = now + AirChatProtocol.RECONNECT_BACKOFF_MS
            return
        }
        pendingGatt[address] = gatt
        logger.log(TAG, "connecting to $address (our ticket=$ticket, theirs=$peerTicket)")
    }

    // ------------------------------------------------------- GATT server side

    private fun openGattServer() {
        if (gattServer != null) return
        val server = try {
            bluetoothManager?.openGattServer(appContext, serverCallback)
        } catch (error: SecurityException) {
            logger.log(TAG, "openGattServer denied: ${error.message}")
            null
        }
        if (server == null) {
            emit(TransportEvent.Status(ChatStatus.FAILED, "无法启动蓝牙服务端"))
            return
        }
        gattServer = server

        val service = BluetoothGattService(BleUuids.serviceUuid(), BluetoothGattService.SERVICE_TYPE_PRIMARY)
        ctrlCharacteristic = BluetoothGattCharacteristic(
            BleUuids.ctrlUuid(),
            BluetoothGattCharacteristic.PROPERTY_NOTIFY or BluetoothGattCharacteristic.PROPERTY_WRITE,
            BluetoothGattCharacteristic.PERMISSION_WRITE,
        ).withCccd()
        txCharacteristic = BluetoothGattCharacteristic(
            BleUuids.txUuid(),
            BluetoothGattCharacteristic.PROPERTY_NOTIFY,
            BluetoothGattCharacteristic.PERMISSION_READ,
        ).withCccd()
        rxCharacteristic = BluetoothGattCharacteristic(
            BleUuids.rxUuid(),
            BluetoothGattCharacteristic.PROPERTY_WRITE or BluetoothGattCharacteristic.PROPERTY_WRITE_NO_RESPONSE,
            BluetoothGattCharacteristic.PERMISSION_WRITE,
        )

        service.addCharacteristic(ctrlCharacteristic)
        service.addCharacteristic(txCharacteristic)
        service.addCharacteristic(rxCharacteristic)

        val added = try {
            server.addService(service)
        } catch (error: SecurityException) {
            logger.log(TAG, "addService denied: ${error.message}")
            false
        }
        if (!added) {
            emit(TransportEvent.Status(ChatStatus.FAILED, "无法注册蓝牙服务"))
            runCatching { server.close() }
            gattServer = null
        }
    }

    private fun closeGattServer() {
        runCatching { gattServer?.clearServices() }
        runCatching { gattServer?.close() }
        gattServer = null
        ctrlCharacteristic = null
        txCharacteristic = null
        rxCharacteristic = null
    }

    private fun BluetoothGattCharacteristic.withCccd(): BluetoothGattCharacteristic {
        val descriptor = BluetoothGattDescriptor(
            BleUuids.CCCD,
            BluetoothGattDescriptor.PERMISSION_READ or BluetoothGattDescriptor.PERMISSION_WRITE,
        )
        // The initial CCCD value is written by the central when it subscribes, so only the
        // descriptor itself needs to exist here.
        addDescriptor(descriptor)
        return this
    }

    private val serverCallback = object : BluetoothGattServerCallback() {

        override fun onConnectionStateChange(device: BluetoothDevice, status: Int, newState: Int) {
            onHandler {
                val address = device.address ?: return@onHandler
                when (newState) {
                    BluetoothProfile.STATE_CONNECTED -> openPeripheralLink(device, address)
                    BluetoothProfile.STATE_DISCONNECTED -> {
                        linksByAddress.remove(address)?.let { link ->
                            link.onGattDisconnected(status)
                            forgetLink(link)
                        }
                    }
                }
            }
        }

        override fun onDescriptorWriteRequest(
            device: BluetoothDevice,
            requestId: Int,
            descriptor: BluetoothGattDescriptor,
            preparedWrite: Boolean,
            responseNeeded: Boolean,
            offset: Int,
            value: ByteArray?,
        ) {
            onHandler {
                if (!preparedWrite && descriptor.uuid == BleUuids.CCCD && value != null) {
                    val enabled = value.contentEquals(BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE) ||
                        value.contentEquals(BluetoothGattDescriptor.ENABLE_INDICATION_VALUE)
                    linksByAddress[device.address]?.onSubscriptionChanged(
                        descriptor.characteristic.uuid,
                        enabled,
                    )
                }
                respondToRequest(device, requestId, responseNeeded, BluetoothGatt.GATT_SUCCESS)
            }
        }

        override fun onCharacteristicWriteRequest(
            device: BluetoothDevice,
            requestId: Int,
            characteristic: BluetoothGattCharacteristic,
            preparedWrite: Boolean,
            responseNeeded: Boolean,
            offset: Int,
            value: ByteArray?,
        ) {
            onHandler {
                // Inbound frames arrive on CH_RX (data) and CH_CTRL (signalling): docs/protocol.md
                // section 5.1 declares CH_CTRL bidirectional. iOS had the mirror-image bug of
                // accepting only CH_RX, which made handshakes impossible; keep both ends explicit.
                val isInboundCharacteristic = characteristic.uuid == BleUuids.rxUuid() ||
                    characteristic.uuid == BleUuids.ctrlUuid()
                if (!preparedWrite && offset == 0 && isInboundCharacteristic) {
                    linksByAddress[device.address]?.onInbound(value)
                }
                respondToRequest(device, requestId, responseNeeded, BluetoothGatt.GATT_SUCCESS)
            }
        }

        override fun onNotificationSent(device: BluetoothDevice, status: Int) {
            onHandler { linksByAddress[device.address]?.onNotificationSent(status) }
        }

        override fun onMtuChanged(device: BluetoothDevice, mtu: Int) {
            onHandler { linksByAddress[device.address]?.onMtuChanged(mtu) }
        }
    }

    private fun openPeripheralLink(device: BluetoothDevice, address: String) {
        if (linksByAddress.containsKey(address)) return
        if (links.size >= AirChatProtocol.MAX_LINKS) {
            emit(TransportEvent.Status(ChatStatus.NEARBY_FULL, "附近人数已满（上限 ${AirChatProtocol.MAX_LINKS}）"))
            // Refuse politely by dropping the connection rather than holding a link we cannot serve.
            runCatching { gattServer?.cancelConnection(device) }
            return
        }
        val server = gattServer ?: return
        val ctrl = ctrlCharacteristic ?: return
        val tx = txCharacteristic ?: return

        val link = BleLink(
            linkId = peripheralLinkId(address),
            isCentral = false,
            peerLabel = address,
            logger = logger,
            onDisconnected = { closedLink, reason -> forgetLink(closedLink, reason) },
        )
        link.bindPeripheral(server, device, ctrl, tx)
        links[link.linkId] = link
        linksByAddress[address] = link
        logger.log(TAG, "peripheral link up with $address")
        emit(TransportEvent.LinkOpened(link))
        updateScanningForCapacity()
    }

    private fun respondToRequest(
        device: BluetoothDevice,
        requestId: Int,
        responseNeeded: Boolean,
        status: Int,
    ) {
        if (!responseNeeded) return
        runCatching { gattServer?.sendResponse(device, requestId, status, 0, null) }
    }

    // ------------------------------------------------------- GATT client side

    private val gattCallback = object : BluetoothGattCallback() {

        override fun onConnectionStateChange(gatt: BluetoothGatt, status: Int, newState: Int) {
            onHandler {
                val address = gatt.device?.address ?: return@onHandler
                when (newState) {
                    BluetoothProfile.STATE_CONNECTED -> openCentralLink(gatt, address)
                    BluetoothProfile.STATE_DISCONNECTED -> {
                        connecting.remove(address)
                        pendingGatt.remove(address)?.let { runCatching { it.close() } }
                        backoffUntil[address] = SystemClock.elapsedRealtime() + AirChatProtocol.RECONNECT_BACKOFF_MS
                        linksByAddress.remove(address)?.let { link ->
                            link.onGattDisconnected(status)
                            forgetLink(link)
                        }
                    }
                }
            }
        }

        override fun onServicesDiscovered(gatt: BluetoothGatt, status: Int) {
            onHandler { linkFor(gatt)?.onServicesDiscovered(status) }
        }

        override fun onDescriptorWrite(gatt: BluetoothGatt, descriptor: BluetoothGattDescriptor, status: Int) {
            onHandler { linkFor(gatt)?.onDescriptorWritten(status) }
        }

        override fun onMtuChanged(gatt: BluetoothGatt, mtu: Int, status: Int) {
            onHandler { if (status == BluetoothGatt.GATT_SUCCESS) linkFor(gatt)?.onMtuChanged(mtu) }
        }

        override fun onCharacteristicWrite(gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic, status: Int) {
            onHandler { linkFor(gatt)?.onCharacteristicWritten(status) }
        }

        @Deprecated("Superseded by the ByteArray overload on API 33+.")
        override fun onCharacteristicChanged(gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic) {
            @Suppress("DEPRECATION")
            val value = characteristic.value
            onHandler { linkFor(gatt)?.onInbound(value) }
        }

        override fun onCharacteristicChanged(
            gatt: BluetoothGatt,
            characteristic: BluetoothGattCharacteristic,
            value: ByteArray,
        ) {
            onHandler {
                logger.log(
                    TAG,
                    "inbound notification on ${characteristic.uuid} (${value.size} bytes)",
                )
                linkFor(gatt)?.onInbound(value)
            }
        }
    }

    private fun linkFor(gatt: BluetoothGatt): BleLink? = linksByAddress[gatt.device?.address]

    private fun openCentralLink(gatt: BluetoothGatt, address: String) {
        connecting.remove(address)
        pendingGatt.remove(address)
        if (linksByAddress.containsKey(address)) {
            runCatching { gatt.close() }
            return
        }
        if (links.size >= AirChatProtocol.MAX_LINKS) {
            runCatching { gatt.close() }
            emit(TransportEvent.Status(ChatStatus.NEARBY_FULL, "附近人数已满（上限 ${AirChatProtocol.MAX_LINKS}）"))
            return
        }
        val link = BleLink(
            linkId = centralLinkId(address),
            isCentral = true,
            peerLabel = address,
            logger = logger,
            onDisconnected = { closedLink, reason -> forgetLink(closedLink, reason) },
        )
        links[link.linkId] = link
        linksByAddress[address] = link
        logger.log(TAG, "central link up with $address")
        emit(TransportEvent.LinkOpened(link))
        link.onGattConnected(gatt)
        updateScanningForCapacity()
    }

    // ------------------------------------------------------------- housekeeping

    private fun forgetLink(link: BleLink, reason: String = "closed") {
        if (links.remove(link.linkId) == null) return
        linksByAddress.remove(link.peerLabel)
        logger.log(TAG, "link ${link.linkId} gone: $reason")
        emit(TransportEvent.LinkClosed(link.linkId, reason))
        updateScanningForCapacity()
    }

    /** Protocol 5.5: stop scanning at the link cap, resume as soon as capacity frees up. */
    private fun updateScanningForCapacity() {
        if (!running) return
        if (links.size >= AirChatProtocol.MAX_LINKS) {
            stopScanning()
            emit(TransportEvent.Status(ChatStatus.NEARBY_FULL, "附近人数已满（上限 ${AirChatProtocol.MAX_LINKS}）"))
        } else {
            startScanning()
        }
    }

    private fun emitStatusIfIdle() {
        if (links.isEmpty()) {
            emit(TransportEvent.Status(ChatStatus.SCANNING, "正在寻找附近的人…"))
        }
    }

    // ------------------------------------------------------- adapter receiver

    private val adapterReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (intent?.action != BluetoothAdapter.ACTION_STATE_CHANGED) return
            val state = intent.getIntExtra(BluetoothAdapter.EXTRA_STATE, BluetoothAdapter.ERROR)
            onHandler {
                when (state) {
                    BluetoothAdapter.STATE_ON -> refresh()
                    BluetoothAdapter.STATE_OFF -> {
                        stopScanning()
                        stopAdvertising()
                        for (link in links.values.toList()) link.close()
                        links.clear()
                        linksByAddress.clear()
                        emit(TransportEvent.Status(ChatStatus.BLUETOOTH_UNAVAILABLE, "蓝牙已关闭"))
                    }
                }
            }
        }
    }

    private var receiverRegistered = false

    private fun registerAdapterReceiver() {
        if (receiverRegistered) return
        ContextCompat.registerReceiver(
            appContext,
            adapterReceiver,
            IntentFilter(BluetoothAdapter.ACTION_STATE_CHANGED),
            ContextCompat.RECEIVER_NOT_EXPORTED,
        )
        receiverRegistered = true
    }

    private fun unregisterAdapterReceiver() {
        if (!receiverRegistered) return
        runCatching { appContext.unregisterReceiver(adapterReceiver) }
        receiverRegistered = false
    }

    // --------------------------------------------------------------- plumbing

    private fun onHandler(block: () -> Unit) {
        if (Thread.currentThread() === handlerThread) block() else handler.post(block)
    }

    private fun emit(event: TransportEvent) {
        val delivered = _events.tryEmit(event)
        if (!delivered) logger.log(TAG, "transport event dropped: $event")
    }

    private fun centralLinkId(address: String) = "central:$address"

    private fun peripheralLinkId(address: String) = "peripheral:$address"

    private companion object {
        const val TAG = "BleTransport"
    }
}
