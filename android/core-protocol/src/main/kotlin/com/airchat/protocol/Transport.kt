package com.airchat.protocol

import kotlinx.coroutines.flow.Flow

/**
 * One established BLE GATT connection, seen from the local side.
 *
 * Implemented by `core-ble` on Android and `AirChatBLE` on iOS. The session layer only needs
 * framed byte transport plus the link metadata, which keeps it testable with a fake.
 */
interface Link {
    /** Stable identifier for this specific connection attempt (not the peer deviceId). */
    val linkId: String

    /** True when the local side initiated the GATT connection (the handshake initiator). */
    val isCentral: Boolean

    /** Negotiated ATT MTU. [AirChatProtocol.DEFAULT_MTU] until the MTU exchange completes. */
    val mtu: Int

    /** Platform peer handle for diagnostics (BLE address or CoreBluetooth identifier). */
    val peerLabel: String?

    /**
     * Queues [bytes] for delivery on the control channel when [control] is true, otherwise on
     * the data channel. Returns false when the link is closed or its queue is saturated.
     */
    fun send(bytes: ByteArray, control: Boolean): Boolean

    /**
     * Registers the single consumer for inbound bytes. Must be called as soon as the link is
     * announced.
     *
     * Contract: the transport must **not** discard bytes that arrive before a handler is
     * registered. A peripheral may legitimately write to CH_RX immediately after connecting,
     * so the transport queues early bytes and flushes them once the handler is set. Dropping
     * them would silently corrupt the peer's frame stream.
     */
    fun setInboundHandler(handler: (ByteArray) -> Unit)

    fun close()
}

sealed interface TransportEvent {
    data class LinkOpened(val link: Link) : TransportEvent

    data class LinkClosed(val linkId: String, val reason: String) : TransportEvent

    /** A peer is advertising nearby. Purely informational; authoritative data comes from HELLO. */
    data class PeerSeen(
        val peerLabel: String,
        val protocolVersion: Int,
        val capabilities: Int,
        val ticket: Int,
        val rssi: Int?,
    ) : TransportEvent

    data class PeerLost(val peerLabel: String) : TransportEvent

    data class Status(val status: ChatStatus, val message: String) : TransportEvent
}

/**
 * Platform BLE transport. Owns advertising, scanning, connection management and the GATT
 * server (for the peripheral role), and applies the connection-direction and link-cap rules
 * from docs/protocol.md sections 5.3 to 5.5.
 */
interface Transport {
    val events: Flow<TransportEvent>

    /** Random 16-bit connect ticket currently advertised (protocol section 5.3). */
    val ticket: Int

    suspend fun start()

    suspend fun stop()

    /** Refreshes the presence block carried in the advertising packet. */
    fun updatePresence(protocolVersion: Int, capabilities: Int)

    /**
     * Connection explicitly asked for by the user, for the peer advertising under [peerLabel].
     *
     * Bypasses the connection-direction policy (protocol section 5.3) because the user outranks
     * the ticket comparison, but not the link cap or the reconnect backoff: an attempt that the
     * radio refuses is simply never made. Outcomes are reported through state rather than a
     * return value - a link for that peer appearing (or not) is the only truthful signal, and
     * asking the BLE handler thread to answer synchronously would block a caller for no gain.
     *
     * Duplicate links from a simultaneous tap on both sides are resolved by the post-handshake
     * dedupe in section 5.4, exactly as with automatic connections.
     */
    fun connectTo(peerLabel: String)
}
