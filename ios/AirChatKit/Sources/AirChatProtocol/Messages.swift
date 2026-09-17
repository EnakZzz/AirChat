import Foundation

/// HELLO / HELLO_ACK payload. The structure is identical for both frame types.
public struct Hello: Equatable {
    public let protocolVersion: Int
    public let deviceId: Data
    public let nickname: String
    public let publicKey: Data
    public let capabilities: Int
    public let helloNonce: Data

    public init(
        protocolVersion: Int,
        deviceId: Data,
        nickname: String,
        publicKey: Data,
        capabilities: Int,
        helloNonce: Data
    ) throws {
        guard deviceId.count == AirChatProtocol.deviceIdBytes else {
            throw AirChatError.format("deviceId must be \(AirChatProtocol.deviceIdBytes) bytes")
        }
        guard publicKey.count == AirChatProtocol.publicKeyBytes else {
            throw AirChatError.format("publicKey must be \(AirChatProtocol.publicKeyBytes) bytes")
        }
        guard helloNonce.count == AirChatProtocol.helloNonceBytes else {
            throw AirChatError.format("helloNonce must be \(AirChatProtocol.helloNonceBytes) bytes")
        }
        guard publicKey.first == 0x04 else {
            throw AirChatError.format("publicKey must be an uncompressed point")
        }
        self.protocolVersion = protocolVersion
        self.deviceId = deviceId
        self.nickname = nickname
        self.publicKey = publicKey
        self.capabilities = capabilities
        self.helloNonce = helloNonce
    }

    public var supportsPrivate: Bool { (capabilities & Capabilities.`private`) != 0 }
    public var supportsSync: Bool { (capabilities & Capabilities.sync) != 0 }
    public var deviceIdHex: String { ByteOps.toHex(deviceId) }
}

/// Public channel message. Plaintext by design: the channel is not encrypted in v1.
public struct ChannelPost: Equatable {
    public let msgId: Data
    public let timestampMillis: Int64
    public let senderId: Data
    public let senderNickname: String
    public let text: String

    public init(msgId: Data, timestampMillis: Int64, senderId: Data, senderNickname: String, text: String) throws {
        guard msgId.count == AirChatProtocol.msgIdBytes else {
            throw AirChatError.format("msgId must be \(AirChatProtocol.msgIdBytes) bytes")
        }
        guard senderId.count == AirChatProtocol.deviceIdBytes else {
            throw AirChatError.format("senderId must be \(AirChatProtocol.deviceIdBytes) bytes")
        }
        self.msgId = msgId
        self.timestampMillis = timestampMillis
        self.senderId = senderId
        self.senderNickname = senderNickname
        self.text = text
    }
}

/// 1:1 message. `ciphertext` is the AEAD output: ciphertext followed by the 16-byte tag.
public struct PrivateMessage: Equatable {
    public let msgId: Data
    public let timestampMillis: Int64
    public let senderId: Data
    public let recipientId: Data
    public let nonce: Data
    public let ciphertext: Data

    public init(
        msgId: Data,
        timestampMillis: Int64,
        senderId: Data,
        recipientId: Data,
        nonce: Data,
        ciphertext: Data
    ) throws {
        guard msgId.count == AirChatProtocol.msgIdBytes else {
            throw AirChatError.format("msgId must be \(AirChatProtocol.msgIdBytes) bytes")
        }
        guard senderId.count == AirChatProtocol.deviceIdBytes else {
            throw AirChatError.format("senderId must be \(AirChatProtocol.deviceIdBytes) bytes")
        }
        guard recipientId.count == AirChatProtocol.deviceIdBytes else {
            throw AirChatError.format("recipientId must be \(AirChatProtocol.deviceIdBytes) bytes")
        }
        guard nonce.count == AirChatProtocol.aeadNonceBytes else {
            throw AirChatError.format("nonce must be \(AirChatProtocol.aeadNonceBytes) bytes")
        }
        guard ciphertext.count >= AirChatProtocol.aeadTagBytes else {
            throw AirChatError.format("ciphertext must include the tag")
        }
        self.msgId = msgId
        self.timestampMillis = timestampMillis
        self.senderId = senderId
        self.recipientId = recipientId
        self.nonce = nonce
        self.ciphertext = ciphertext
    }

    /// Additional authenticated data, binding the ciphertext to this exact message.
    public var aad: Data { ByteOps.concat(msgId, senderId, recipientId) }
}

public struct DeliveryAck: Equatable {
    public let msgId: Data
    public let status: AckStatus

    public init(msgId: Data, status: AckStatus) throws {
        guard msgId.count == AirChatProtocol.msgIdBytes else {
            throw AirChatError.format("msgId must be \(AirChatProtocol.msgIdBytes) bytes")
        }
        self.msgId = msgId
        self.status = status
    }
}

public struct Typing: Equatable {
    public let scope: TypingScope
    public let active: Bool
    public let recipientId: Data

    public init(scope: TypingScope, active: Bool, recipientId: Data) {
        self.scope = scope
        self.active = active
        self.recipientId = recipientId
    }
}

public struct SyncRequest: Equatable {
    public let requesterId: Data
    public let sinceMinutesAgo: Int
    public let maxCount: Int

    public init(requesterId: Data, sinceMinutesAgo: Int, maxCount: Int) {
        self.requesterId = requesterId
        self.sinceMinutesAgo = sinceMinutesAgo
        self.maxCount = maxCount
    }
}

public struct SyncResponse: Equatable {
    public let posts: [ChannelPost]
    public init(posts: [ChannelPost]) { self.posts = posts }
}

public struct KeyVerifyResponse: Equatable {
    public let accepted: Bool
    public init(accepted: Bool) { self.accepted = accepted }
}

/// Encode/decode for every payload type in `docs/protocol.md` section 8.
///
/// Decoding never throws for malformed input: it returns nil and the caller drops the frame,
/// matching protocol section 9 rule 3.
public enum MessageCodec {

    // ---------------------------------------------------------------- HELLO

    public static func encodeHello(_ hello: Hello) -> Data? {
        let nickname = Data(hello.nickname.utf8)
        guard nickname.count <= AirChatProtocol.maxNicknameBytes else { return nil }
        var writer = ByteWriter(capacity: 96)
        writer.u16(hello.protocolVersion)
        writer.put(hello.deviceId)
        writer.u8(nickname.count)
        writer.put(nickname)
        writer.put(hello.publicKey)
        writer.u8(hello.capabilities)
        writer.put(hello.helloNonce)
        return writer.data
    }

    public static func decodeHello(_ payload: Data) -> Hello? {
        do {
            var reader = ByteReader(payload)
            let version = try reader.u16()
            let deviceId = try reader.take(AirChatProtocol.deviceIdBytes)
            let nicknameLength = try reader.u8()
            guard nicknameLength <= AirChatProtocol.maxNicknameBytes else {
                throw AirChatError.format("nickname \(nicknameLength) bytes exceeds limit")
            }
            let nicknameData = try reader.take(nicknameLength)
            let publicKey = try reader.take(AirChatProtocol.publicKeyBytes)
            let capabilities = try reader.u8()
            let helloNonce = try reader.take(AirChatProtocol.helloNonceBytes)
            try reader.requireFullyConsumed()
            return try Hello(
                protocolVersion: version,
                deviceId: deviceId,
                nickname: String(decoding: nicknameData, as: UTF8.self),
                publicKey: publicKey,
                capabilities: capabilities,
                helloNonce: helloNonce
            )
        } catch {
            return nil
        }
    }

    // -------------------------------------------------------- CHANNEL_POST

    public static func encodeChannelPost(_ post: ChannelPost) -> Data? {
        let nickname = Data(post.senderNickname.utf8)
        let text = Data(post.text.utf8)
        guard nickname.count <= AirChatProtocol.maxNicknameBytes else { return nil }
        guard text.count <= AirChatProtocol.maxTextBytes else { return nil }
        var writer = ByteWriter(capacity: text.count + 64)
        writer.put(post.msgId)
        writer.i64(post.timestampMillis)
        writer.put(post.senderId)
        writer.u8(nickname.count)
        writer.put(nickname)
        writer.putVar(text)
        return writer.data
    }

    public static func decodeChannelPost(_ payload: Data) -> ChannelPost? {
        do {
            var reader = ByteReader(payload)
            let msgId = try reader.take(AirChatProtocol.msgIdBytes)
            let timestamp = try reader.i64()
            let senderId = try reader.take(AirChatProtocol.deviceIdBytes)
            let nicknameLength = try reader.u8()
            guard nicknameLength <= AirChatProtocol.maxNicknameBytes else {
                throw AirChatError.format("nickname \(nicknameLength) bytes exceeds limit")
            }
            let nickname = try reader.take(nicknameLength)
            let textLength = try reader.u16()
            guard textLength <= AirChatProtocol.maxTextBytes else {
                throw AirChatError.format("text \(textLength) bytes exceeds limit")
            }
            let text = try reader.take(textLength)
            try reader.requireFullyConsumed()
            return try ChannelPost(
                msgId: msgId,
                timestampMillis: timestamp,
                senderId: senderId,
                senderNickname: String(decoding: nickname, as: UTF8.self),
                text: String(decoding: text, as: UTF8.self)
            )
        } catch {
            return nil
        }
    }

    // --------------------------------------------------------- PRIVATE_MSG

    public static func encodePrivateMessage(_ message: PrivateMessage) -> Data? {
        guard message.ciphertext.count <= AirChatProtocol.maxTextBytes + AirChatProtocol.aeadTagBytes else {
            return nil
        }
        var writer = ByteWriter(capacity: message.ciphertext.count + 80)
        writer.put(message.msgId)
        writer.i64(message.timestampMillis)
        writer.put(message.senderId)
        writer.put(message.recipientId)
        writer.put(message.nonce)
        writer.putVar(message.ciphertext)
        return writer.data
    }

    public static func decodePrivateMessage(_ payload: Data) -> PrivateMessage? {
        do {
            var reader = ByteReader(payload)
            let msgId = try reader.take(AirChatProtocol.msgIdBytes)
            let timestamp = try reader.i64()
            let senderId = try reader.take(AirChatProtocol.deviceIdBytes)
            let recipientId = try reader.take(AirChatProtocol.deviceIdBytes)
            let nonce = try reader.take(AirChatProtocol.aeadNonceBytes)
            let ciphertext = try reader.varBytes()
            guard ciphertext.count >= AirChatProtocol.aeadTagBytes else {
                throw AirChatError.format("ciphertext shorter than the AEAD tag")
            }
            try reader.requireFullyConsumed()
            return try PrivateMessage(
                msgId: msgId,
                timestampMillis: timestamp,
                senderId: senderId,
                recipientId: recipientId,
                nonce: nonce,
                ciphertext: ciphertext
            )
        } catch {
            return nil
        }
    }

    // -------------------------------------------------------- DELIVERY_ACK

    public static func encodeDeliveryAck(_ ack: DeliveryAck) -> Data {
        var writer = ByteWriter(capacity: 24)
        writer.put(ack.msgId)
        writer.u8(ack.status.rawValue)
        return writer.data
    }

    public static func decodeDeliveryAck(_ payload: Data) -> DeliveryAck? {
        do {
            var reader = ByteReader(payload)
            let msgId = try reader.take(AirChatProtocol.msgIdBytes)
            let rawStatus = try reader.u8()
            guard let status = AckStatus(rawValue: rawStatus) else {
                throw AirChatError.format("unknown ack status")
            }
            try reader.requireFullyConsumed()
            return try DeliveryAck(msgId: msgId, status: status)
        } catch {
            return nil
        }
    }

    // --------------------------------------------------------------- TYPING

    public static func encodeTyping(_ typing: Typing) -> Data {
        var writer = ByteWriter(capacity: 20)
        writer.u8(typing.scope.rawValue)
        writer.u8(typing.active ? 1 : 0)
        writer.put(typing.recipientId)
        return writer.data
    }

    public static func decodeTyping(_ payload: Data) -> Typing? {
        do {
            var reader = ByteReader(payload)
            let rawScope = try reader.u8()
            guard let scope = TypingScope(rawValue: rawScope) else {
                throw AirChatError.format("unknown typing scope")
            }
            let active = try reader.u8() != 0
            let recipientId = try reader.take(AirChatProtocol.deviceIdBytes)
            try reader.requireFullyConsumed()
            return Typing(scope: scope, active: active, recipientId: recipientId)
        } catch {
            return nil
        }
    }

    // ------------------------------------------------------------- SYNC_REQ

    public static func encodeSyncRequest(_ request: SyncRequest) -> Data {
        var writer = ByteWriter(capacity: 24)
        writer.put(request.requesterId)
        writer.u16(request.sinceMinutesAgo)
        writer.u16(request.maxCount)
        return writer.data
    }

    public static func decodeSyncRequest(_ payload: Data) -> SyncRequest? {
        do {
            var reader = ByteReader(payload)
            let requesterId = try reader.take(AirChatProtocol.deviceIdBytes)
            let since = try reader.u16()
            let maxCount = try reader.u16()
            try reader.requireFullyConsumed()
            return SyncRequest(requesterId: requesterId, sinceMinutesAgo: since, maxCount: maxCount)
        } catch {
            return nil
        }
    }

    // ------------------------------------------------------------ SYNC_RESP

    /// Encodes as many posts as fit inside `maxPayloadBytes`; entries that would overflow are
    /// dropped and the count reflects only what was written (protocol section 8.7).
    public static func encodeSyncResponse(
        _ response: SyncResponse,
        maxPayloadBytes: Int = AirChatProtocol.maxPayloadBytes
    ) -> Data {
        var body = ByteWriter(capacity: 256)
        var count = 0
        var payloadBytes = 2 // the u16 count itself

        for post in response.posts {
            guard let encoded = encodeChannelPost(post) else { continue }
            guard encoded.count <= 0xFFFF else { continue }
            guard payloadBytes + 2 + encoded.count <= maxPayloadBytes else { break }
            body.u16(encoded.count)
            body.put(encoded)
            payloadBytes += 2 + encoded.count
            count += 1
        }

        var writer = ByteWriter(capacity: payloadBytes)
        writer.u16(count)
        writer.put(body.data)
        return writer.data
    }

    public static func decodeSyncResponse(_ payload: Data) -> SyncResponse? {
        do {
            var reader = ByteReader(payload)
            let count = try reader.u16()
            var posts: [ChannelPost] = []
            posts.reserveCapacity(count)
            for _ in 0..<count {
                let length = try reader.u16()
                let entry = try reader.take(length)
                if let post = decodeChannelPost(entry) {
                    posts.append(post)
                }
            }
            try reader.requireFullyConsumed()
            return SyncResponse(posts: posts)
        } catch {
            return nil
        }
    }

    // ------------------------------------------------------ KEY_VERIFY_RESP

    public static func encodeKeyVerifyResponse(_ response: KeyVerifyResponse) -> Data {
        Data([response.accepted ? 1 : 0])
    }

    public static func decodeKeyVerifyResponse(_ payload: Data) -> KeyVerifyResponse? {
        do {
            var reader = ByteReader(payload)
            let value = try reader.u8()
            try reader.requireFullyConsumed()
            return KeyVerifyResponse(accepted: value != 0)
        } catch {
            return nil
        }
    }
}
