import Foundation

/// A decoded protocol frame: `[1B version][1B type][2B payloadLength][payload]`.
public struct Frame: Equatable {
    public let type: Int
    public let payload: Data

    public init(type: Int, payload: Data) {
        self.type = type
        self.payload = payload
    }

    public var payloadLength: Int { payload.count }
}

public enum FrameCodec {
    public static func encode(type: Int, payload: Data) -> Data {
        precondition(payload.count <= AirChatProtocol.maxPayloadBytes, "payload exceeds MAX_PAYLOAD_BYTES")
        var writer = ByteWriter(capacity: payload.count + AirChatProtocol.frameHeaderBytes)
        writer.u8(AirChatProtocol.version)
        writer.u8(type)
        writer.u16(payload.count)
        writer.put(payload)
        return writer.data
    }

    public static func encode(_ frame: Frame) -> Data {
        encode(type: frame.type, payload: frame.payload)
    }
}

/// Why the framer refused to continue reading the stream.
public enum FatalReason: Equatable {
    case unsupportedVersion
    case payloadTooLarge
}

public enum FramingOutcome {
    /// Zero or more complete frames extracted from the stream so far.
    case frames([Frame])
    /// The stream is unrecoverable: close the link and discard the buffer.
    case fatal(FatalReason, String)

    public var frames: [Frame]? {
        if case .frames(let value) = self { return value }
        return nil
    }

    public var isFatal: Bool {
        if case .fatal = self { return true }
        return false
    }
}

/// Turns an unbounded GATT byte stream back into frames.
///
/// GATT writes and notifications carry no message boundaries, so frames may be split across many
/// chunks and several frames may arrive in one chunk. Unknown frame types are surfaced to the
/// caller and skipped by payload length, which keeps the protocol forward compatible.
public final class StreamFramer {
    private var buffer = Data()

    public init() {}

    public var bufferedBytes: Int { buffer.count }

    public func reset() {
        buffer.removeAll(keepingCapacity: true)
    }

    public func push(_ bytes: Data) -> FramingOutcome {
        guard !bytes.isEmpty else { return .frames([]) }
        buffer.append(bytes)

        let raw = [UInt8](buffer)
        var frames: [Frame] = []
        var cursor = 0

        while raw.count - cursor >= AirChatProtocol.frameHeaderBytes {
            let version = Int(raw[cursor])
            guard version == AirChatProtocol.version else {
                reset()
                return .fatal(
                    .unsupportedVersion,
                    "unsupported protocol version \(version) (expected \(AirChatProtocol.version))"
                )
            }

            let type = Int(raw[cursor + 1])
            let payloadLength = (Int(raw[cursor + 2]) << 8) | Int(raw[cursor + 3])

            guard payloadLength <= AirChatProtocol.maxPayloadBytes else {
                reset()
                return .fatal(
                    .payloadTooLarge,
                    "declared payload \(payloadLength) exceeds \(AirChatProtocol.maxPayloadBytes)"
                )
            }

            let frameEnd = cursor + AirChatProtocol.frameHeaderBytes + payloadLength
            guard raw.count >= frameEnd else { break }

            let payloadStart = cursor + AirChatProtocol.frameHeaderBytes
            frames.append(Frame(type: type, payload: Data(raw[payloadStart..<frameEnd])))
            cursor = frameEnd
        }

        if cursor > 0 {
            buffer.removeFirst(cursor)
        }
        return .frames(frames)
    }
}

/// Slices an encoded frame stream into GATT-sized chunks.
///
/// The chunk size is `min(mtu - 3, maxChunkBytes)`. A degenerate or unknown MTU falls back to the
/// BLE minimum ATT MTU rather than producing unusable chunks.
public struct StreamChunker {
    private let maxChunkBytes: Int

    public init(maxChunkBytes: Int = AirChatProtocol.maxChunkBytes) {
        self.maxChunkBytes = maxChunkBytes
    }

    public func chunkSize(forMtu mtu: Int) -> Int {
        let effective = mtu <= 0 ? AirChatProtocol.defaultMtu : mtu
        return max(1, min(effective - 3, maxChunkBytes))
    }

    public func chunk(_ encoded: Data, mtu: Int) -> [Data] {
        let size = chunkSize(forMtu: mtu)
        guard !encoded.isEmpty else { return [] }
        guard encoded.count > size else { return [encoded] }

        var chunks: [Data] = []
        chunks.reserveCapacity((encoded.count + size - 1) / size)
        let bytes = [UInt8](encoded)
        var offset = 0
        while offset < bytes.count {
            let end = min(offset + size, bytes.count)
            chunks.append(Data(bytes[offset..<end]))
            offset = end
        }
        return chunks
    }
}
