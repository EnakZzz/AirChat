import CoreBluetooth
import Foundation
import AirChatProtocol

/// CoreBluetooth view of the protocol UUIDs.
internal enum BleUuids {
    static let service = CBUUID(string: AirChatUuids.service)
    static let ctrl = CBUUID(string: AirChatUuids.ctrl)
    static let tx = CBUUID(string: AirChatUuids.tx)
    static let rx = CBUUID(string: AirChatUuids.rx)

    /// Service Data AD type 0x16 carries the presence block under the 16-bit alias.
    static let presence = CBUUID(string: AirChatUuids.presence)

    /// Client Characteristic Configuration descriptor.
    static let cccd = CBUUID(string: AirChatUuids.cccd)

    /// Presence block: `protocolVersion | capabilities | ticket(u16 BE)`.
    static func encodePresence(protocolVersion: Int, capabilities: Int, ticket: Int) -> Data {
        Data([
            UInt8(protocolVersion & 0xFF),
            UInt8(capabilities & 0xFF),
            UInt8((ticket >> 8) & 0xFF),
            UInt8(ticket & 0xFF),
        ])
    }

    struct Presence {
        let protocolVersion: Int
        let capabilities: Int
        let ticket: Int
    }

    static func decodePresence(_ data: Data?) -> Presence? {
        guard let data, data.count >= 4 else { return nil }
        let bytes = [UInt8](data)
        return Presence(
            protocolVersion: Int(bytes[0]),
            capabilities: Int(bytes[1]),
            ticket: (Int(bytes[2]) << 8) | Int(bytes[3])
        )
    }
}
