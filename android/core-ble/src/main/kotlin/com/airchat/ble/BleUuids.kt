package com.airchat.ble

import android.os.ParcelUuid
import com.airchat.protocol.AirChatUuids
import java.util.UUID

/**
 * Android's `ParcelUuid` view of the protocol UUIDs.
 *
 * The 16-bit presence alias must be expressed as a full 128-bit UUID because that is how the
 * Bluetooth stack normalises 16-bit UUIDs inside Service Data (`0000xxxx-0000-1000-8000-00805f9b34fb`).
 */
internal object BleUuids {
    val SERVICE: ParcelUuid = ParcelUuid.fromString(AirChatUuids.SERVICE)
    val CH_CTRL: ParcelUuid = ParcelUuid.fromString(AirChatUuids.CH_CTRL)
    val CH_TX: ParcelUuid = ParcelUuid.fromString(AirChatUuids.CH_TX)
    val CH_RX: ParcelUuid = ParcelUuid.fromString(AirChatUuids.CH_RX)

    /** Service Data AD type 0x16 carries the presence block under this 16-bit alias. */
    val PRESENCE: ParcelUuid = ParcelUuid.fromString(
        String.format("%08x-0000-1000-8000-00805f9b34fb", AirChatUuids.PRESENCE_UUID16),
    )

    /** Client Characteristic Configuration descriptor. */
    val CCCD: UUID = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")

    fun serviceUuid(): UUID = UUID.fromString(AirChatUuids.SERVICE)
    fun ctrlUuid(): UUID = UUID.fromString(AirChatUuids.CH_CTRL)
    fun txUuid(): UUID = UUID.fromString(AirChatUuids.CH_TX)
    fun rxUuid(): UUID = UUID.fromString(AirChatUuids.CH_RX)

    /** Presence block: `protocolVersion | capabilities | ticket(u16 BE)`. */
    fun encodePresence(protocolVersion: Int, capabilities: Int, ticket: Int): ByteArray =
        byteArrayOf(
            protocolVersion.toByte(),
            capabilities.toByte(),
            ((ticket ushr 8) and 0xFF).toByte(),
            (ticket and 0xFF).toByte(),
        )

    class Presence(val protocolVersion: Int, val capabilities: Int, val ticket: Int)

    fun decodePresence(bytes: ByteArray?): Presence? {
        if (bytes == null || bytes.size < 4) return null
        return Presence(
            protocolVersion = bytes[0].toInt() and 0xFF,
            capabilities = bytes[1].toInt() and 0xFF,
            ticket = ((bytes[2].toInt() and 0xFF) shl 8) or (bytes[3].toInt() and 0xFF),
        )
    }
}
