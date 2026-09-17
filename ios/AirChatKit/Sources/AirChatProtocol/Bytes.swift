import Foundation

/// Errors raised while decoding wire data or running a session.
public enum AirChatError: Error, CustomStringConvertible {
    /// A payload or frame could not be decoded. Never fatal to the link on its own.
    case format(String)
    /// The byte stream is unrecoverable; the link must be closed.
    case fatal(String)
    /// An operation was attempted on a session that is not ready.
    case notReady(String)

    public var description: String {
        switch self {
        case .format(let message): return "format: \(message)"
        case .fatal(let message): return "fatal: \(message)"
        case .notReady(let message): return "notReady: \(message)"
        }
    }
}

/// Big-endian writer for wire payloads.
public struct ByteWriter {
    public private(set) var data: Data

    public init(capacity: Int = 64) {
        data = Data()
        data.reserveCapacity(capacity)
    }

    public mutating func u8(_ value: Int) {
        data.append(UInt8(value & 0xFF))
    }

    public mutating func u16(_ value: Int) {
        precondition(value >= 0 && value <= 0xFFFF, "u16 out of range: \(value)")
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8(value & 0xFF))
    }

    public mutating func i64(_ value: Int64) {
        var bigEndian = value.bigEndian
        withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
    }

    public mutating func put(_ bytes: Data) {
        data.append(bytes)
    }

    /// u16 length prefix followed by the bytes.
    public mutating func putVar(_ bytes: Data) {
        u16(bytes.count)
        data.append(bytes)
    }
}

/// Bounds-checked big-endian reader. Every accessor throws `AirChatError.format` on truncation.
public struct ByteReader {
    private let bytes: [UInt8]
    private var offset: Int = 0

    public init(_ data: Data) {
        bytes = [UInt8](data)
    }

    public init(_ data: [UInt8]) {
        bytes = data
    }

    public var remaining: Int { bytes.count - offset }

    public mutating func u8() throws -> Int {
        try require(1)
        defer { offset += 1 }
        return Int(bytes[offset])
    }

    public mutating func u16() throws -> Int {
        try require(2)
        defer { offset += 2 }
        return (Int(bytes[offset]) << 8) | Int(bytes[offset + 1])
    }

    public mutating func i64() throws -> Int64 {
        try require(8)
        var value: UInt64 = 0
        for index in 0..<8 {
            value = (value << 8) | UInt64(bytes[offset + index])
        }
        offset += 8
        return Int64(bitPattern: value)
    }

    public mutating func take(_ count: Int) throws -> Data {
        try require(count)
        let slice = Data(bytes[offset..<(offset + count)])
        offset += count
        return slice
    }

    public mutating func varBytes() throws -> Data {
        let length = try u16()
        return try take(length)
    }

    /// Requires the payload to be fully consumed; guards against trailing junk.
    public func requireFullyConsumed() throws {
        guard remaining == 0 else {
            throw AirChatError.format("trailing bytes after payload: \(remaining)")
        }
    }

    private func require(_ count: Int) throws {
        guard count >= 0 && remaining >= count else {
            throw AirChatError.format("truncated payload: needed \(count) bytes, \(remaining) available")
        }
    }
}

/// Small helpers shared by both platform implementations.
public enum ByteOps {
    /// Unsigned lexicographic comparison, matching the ordering the protocol requires.
    public static func compareUnsigned(_ lhs: Data, _ rhs: Data) -> Int {
        let left = [UInt8](lhs)
        let right = [UInt8](rhs)
        let count = min(left.count, right.count)
        for index in 0..<count where left[index] != right[index] {
            return Int(left[index]) - Int(right[index])
        }
        return left.count - right.count
    }

    public static func toHex(_ bytes: Data) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    public static func fromHex(_ hex: String) -> Data {
        let clean = hex.filter { !$0.isWhitespace }
        precondition(clean.count % 2 == 0, "hex string must have even length")
        var out = Data(capacity: clean.count / 2)
        var index = clean.startIndex
        while index < clean.endIndex {
            let next = clean.index(index, offsetBy: 2)
            guard let byte = UInt8(clean[index..<next], radix: 16) else {
                preconditionFailure("invalid hex at \(index)")
            }
            out.append(byte)
            index = next
        }
        return out
    }

    public static func concat(_ parts: Data...) -> Data {
        var out = Data()
        out.reserveCapacity(parts.reduce(0) { $0 + $1.count })
        for part in parts { out.append(part) }
        return out
    }

    public static func concat(_ parts: [Data]) -> Data {
        var out = Data()
        out.reserveCapacity(parts.reduce(0) { $0 + $1.count })
        for part in parts { out.append(part) }
        return out
    }
}
