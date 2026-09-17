import XCTest
@testable import AirChatProtocol

/// Frame encode/decode and stream reassembly, driven by the shared `testdata/frames.json`.
///
/// These cases prove the "MTU-independent byte stream" contract: the same frames must survive
/// being split at 20, 182 and 512 byte boundaries and being concatenated together.
final class FramingVectorsTests: XCTestCase {

    private var vectors: [String: Any] = [:]

    override func setUpWithError() throws {
        vectors = try TestVectors.load("frames.json")
    }

    func testFrameEncodingMatchesTheVectors() throws {
        let encodes = try TestVectors.array(vectors, "encodes")
        XCTAssertGreaterThanOrEqual(encodes.count, 11)
        for entry in encodes {
            let name = TestVectors.string(entry["name"])
            let type = TestVectors.int(entry["type"])
            let payload = TestVectors.hex(entry["payloadHex"])
            let expectedFrame = TestVectors.string(entry["frameHex"])
            let expectedLength = TestVectors.int(entry["expectedPayloadLength"])

            XCTAssertEqual(expectedLength, payload.count, "\(name) payload length")
            XCTAssertEqual(expectedFrame, ByteOps.toHex(FrameCodec.encode(type: type, payload: payload)), name)
        }
    }

    func testMessagePayloadsRoundTripThroughTheCodec() throws {
        let encodes = try TestVectors.array(vectors, "encodes")
        for entry in encodes {
            let name = TestVectors.string(entry["name"])
            let type = TestVectors.int(entry["type"])
            let payload = TestVectors.hex(entry["payloadHex"])
            if let reencoded = encodeThroughModel(type: type, payload: payload) {
                XCTAssertEqual(ByteOps.toHex(payload), ByteOps.toHex(reencoded), "\(name) payload round-trip")
            } else {
                XCTAssertEqual(0, payload.count, "\(name) has no payload model")
            }
        }
    }

    private func encodeThroughModel(type: Int, payload: Data) -> Data? {
        switch type {
        case FrameType.hello, FrameType.helloAck:
            return MessageCodec.decodeHello(payload).flatMap(MessageCodec.encodeHello)
        case FrameType.channelPost:
            return MessageCodec.decodeChannelPost(payload).flatMap(MessageCodec.encodeChannelPost)
        case FrameType.privateMsg:
            return MessageCodec.decodePrivateMessage(payload).flatMap(MessageCodec.encodePrivateMessage)
        case FrameType.deliveryAck:
            return MessageCodec.decodeDeliveryAck(payload).map(MessageCodec.encodeDeliveryAck)
        case FrameType.typing:
            return MessageCodec.decodeTyping(payload).map(MessageCodec.encodeTyping)
        case FrameType.syncReq:
            return MessageCodec.decodeSyncRequest(payload).map(MessageCodec.encodeSyncRequest)
        case FrameType.keyVerifyResp:
            return MessageCodec.decodeKeyVerifyResponse(payload).map(MessageCodec.encodeKeyVerifyResponse)
        case FrameType.ping, FrameType.pong, FrameType.keyVerifyReq:
            return payload.isEmpty ? payload : nil
        default:
            return nil
        }
    }

    func testStreamReassemblyMatchesEveryVectorCase() throws {
        let cases = try TestVectors.array(vectors, "streamCases")
        XCTAssertGreaterThanOrEqual(cases.count, 10)

        for item in cases {
            let name = TestVectors.string(item["name"])
            let chunks = (item["inputChunksHex"] as? [String] ?? []).map { ByteOps.fromHex($0) }
            let expected = try TestVectors.array(item, "expectedFrames")
            let expectFatal = TestVectors.bool(item["expectedFatal"])

            let framer = StreamFramer()
            var collected: [Frame] = []
            var fatal = false
            for chunk in chunks {
                switch framer.push(chunk) {
                case .frames(let frames):
                    collected.append(contentsOf: frames)
                case .fatal:
                    fatal = true
                }
                if fatal { break }
            }

            XCTAssertEqual(expectFatal, fatal, "\(name) fatal")
            XCTAssertEqual(expected.count, collected.count, "\(name) frame count")
            for (index, frame) in expected.enumerated() where index < collected.count {
                XCTAssertEqual(TestVectors.int(frame["type"]), collected[index].type, "\(name) frame[\(index)] type")
                XCTAssertEqual(
                    ByteOps.toHex(TestVectors.hex(frame["payloadHex"])),
                    ByteOps.toHex(collected[index].payload),
                    "\(name) frame[\(index)] payload"
                )
            }
            if expectFatal {
                XCTAssertEqual(0, framer.bufferedBytes, "\(name) must clear its buffer")
            }
        }
    }

    func testChunkSizesFollowMtuMinusThreeCappedAtTheProtocolMaximum() {
        let chunker = StreamChunker()
        XCTAssertEqual(20, chunker.chunkSize(forMtu: 23))
        XCTAssertEqual(182, chunker.chunkSize(forMtu: 185))
        XCTAssertEqual(AirChatProtocol.maxChunkBytes, chunker.chunkSize(forMtu: 517))
        // An unknown or zero MTU falls back to the BLE minimum ATT MTU (23 -> 20 bytes).
        XCTAssertEqual(20, chunker.chunkSize(forMtu: 0))
        XCTAssertEqual(20, chunker.chunkSize(forMtu: -5))
        // A degenerately small MTU still yields a usable, non-zero chunk.
        XCTAssertEqual(1, chunker.chunkSize(forMtu: 4))
    }

    func testChunkingALargeFrameReassemblesToTheOriginal() {
        let payload = Data((0..<1000).map { UInt8($0 % 251) })
        let encoded = FrameCodec.encode(type: FrameType.channelPost, payload: payload)
        let chunker = StreamChunker()

        for mtu in [23, 185, 517] {
            let chunks = chunker.chunk(encoded, mtu: mtu)
            XCTAssertFalse(chunks.isEmpty, "mtu \(mtu) should produce chunks")

            let framer = StreamFramer()
            var frames: [Frame] = []
            for chunk in chunks {
                switch framer.push(chunk) {
                case .frames(let parsed):
                    frames.append(contentsOf: parsed)
                case .fatal(let reason, let message):
                    XCTFail("mtu \(mtu) chunking must not be fatal: \(reason) \(message)")
                }
            }
            XCTAssertEqual(1, frames.count, "mtu \(mtu) frame count")
            XCTAssertEqual(ByteOps.toHex(payload), ByteOps.toHex(frames[0].payload), "mtu \(mtu) payload")
        }
    }

    func testFramerSurfacesUnknownTypesWithoutBreaking() {
        // Layering contract: the framer is a pure byte-stream parser. It surfaces every frame it
        // can delimit - including types it does not know - so the session layer owns the policy
        // decision to drop them. Crucially it must never desynchronise.
        let unknown = FrameCodec.encode(type: 0x42, payload: Data(repeating: 0x7F, count: 16))
        let known = FrameCodec.encode(type: FrameType.ping, payload: Data())

        let framer = StreamFramer()
        let outcome = framer.push(ByteOps.concat(unknown, known))
        guard case .frames(let frames) = outcome else {
            return XCTFail("expected frames")
        }
        XCTAssertEqual(2, frames.count)
        XCTAssertEqual(0x42, frames[0].type)
        XCTAssertEqual(FrameType.ping, frames[1].type)
        XCTAssertEqual(0, framer.bufferedBytes)
    }

    func testOversizePayloadIsFatalAndClearsTheBuffer() {
        let declared = AirChatProtocol.maxPayloadBytes + 1
        var writer = ByteWriter()
        writer.u8(AirChatProtocol.version)
        writer.u8(FrameType.channelPost)
        writer.u16(declared)

        let outcome = StreamFramer().push(writer.data)
        guard case .fatal(let reason, _) = outcome else {
            return XCTFail("expected a fatal outcome")
        }
        XCTAssertEqual(FatalReason.payloadTooLarge, reason)
    }

    func testUnsupportedVersionIsFatal() {
        var writer = ByteWriter()
        writer.u8(9)
        writer.u8(FrameType.ping)
        writer.u16(0)

        let outcome = StreamFramer().push(writer.data)
        guard case .fatal(let reason, _) = outcome else {
            return XCTFail("expected a fatal outcome")
        }
        XCTAssertEqual(FatalReason.unsupportedVersion, reason)
    }

    func testAFrameSplitByteByByteNeverEmitsEarly() {
        let payload = Data("你好世界".utf8)
        let encoded = FrameCodec.encode(type: FrameType.channelPost, payload: payload)

        let framer = StreamFramer()
        var emitted = 0
        for index in 0..<encoded.count {
            let slice = encoded.subdata(in: index..<(index + 1))
            switch framer.push(slice) {
            case .frames(let frames): emitted += frames.count
            case .fatal: return XCTFail("unexpected fatal outcome")
            }
        }
        XCTAssertEqual(1, emitted)
    }

    func testDecodersRejectTruncatedAndTrailingGarbage() throws {
        let post = try ChannelPost(
            msgId: AirChatCrypto.randomMessageId(),
            timestampMillis: 1,
            senderId: AirChatCrypto.randomDeviceId(),
            senderNickname: "n",
            text: "hello"
        )
        let encoded = try XCTUnwrap(MessageCodec.encodeChannelPost(post))

        XCTAssertNil(MessageCodec.decodeChannelPost(encoded.subdata(in: 0..<(encoded.count - 1))))
        XCTAssertNil(MessageCodec.decodeChannelPost(ByteOps.concat(encoded, Data([0]))))
        XCTAssertNil(MessageCodec.decodeChannelPost(Data()))
    }

    func testChannelPostKeepsMultiByteUtf8Intact() throws {
        let text = "晚上好，今天气温 26°C 👍 — длинный текст"
        let post = try ChannelPost(
            msgId: AirChatCrypto.randomMessageId(),
            timestampMillis: 1_758_000_000_123,
            senderId: AirChatCrypto.randomDeviceId(),
            senderNickname: "小明",
            text: text
        )
        let decoded = try XCTUnwrap(MessageCodec.decodeChannelPost(try XCTUnwrap(MessageCodec.encodeChannelPost(post))))
        XCTAssertEqual(text, decoded.text)
        XCTAssertEqual("小明", decoded.senderNickname)
        XCTAssertEqual(post.timestampMillis, decoded.timestampMillis)
    }

    func testSyncResponseDropsEntriesThatWouldOverflowTheFrame() throws {
        let sender = AirChatCrypto.randomDeviceId()
        let posts = try (0..<200).map { index in
            try ChannelPost(
                msgId: AirChatCrypto.randomMessageId(),
                timestampMillis: Int64(index),
                senderId: sender,
                senderNickname: "n",
                text: String(repeating: "m", count: 200)
            )
        }
        let encoded = MessageCodec.encodeSyncResponse(SyncResponse(posts: posts))
        XCTAssertLessThanOrEqual(encoded.count, AirChatProtocol.maxPayloadBytes)

        let decoded = try XCTUnwrap(MessageCodec.decodeSyncResponse(encoded))
        XCTAssertGreaterThanOrEqual(decoded.posts.count, 1)
        XCTAssertLessThan(decoded.posts.count, posts.count)
        XCTAssertEqual(0, decoded.posts.first?.timestampMillis ?? -1)
    }

    func testUnsignedComparisonOrdersDeviceIdsTheWayTheProtocolRequires() {
        let low = ByteOps.fromHex("0f1e2d3c4b5a69788796a5b4c3d2e1f0")
        let high = ByteOps.fromHex("a0b1c2d3e4f50112233445566778899a")
        XCTAssertLessThan(ByteOps.compareUnsigned(low, high), 0)
        XCTAssertGreaterThan(ByteOps.compareUnsigned(high, low), 0)
        XCTAssertEqual(0, ByteOps.compareUnsigned(low, low))
        // 0xff must sort above 0x00, which a signed comparison would get wrong.
        XCTAssertGreaterThan(ByteOps.compareUnsigned(Data([0xFF]), Data([0x00])), 0)
    }
}
