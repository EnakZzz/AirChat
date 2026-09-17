import CryptoKit
import Foundation

/// The device's long-lived identity: a P-256 key pair plus a random 16-byte deviceId.
///
/// The key pair is generated exactly once and persisted. Changing it would invalidate every
/// peer's stored public key and force a fresh safety-number comparison, so `toRecord()` and
/// `from(record:)` must round-trip losslessly.
public final class LocalIdentity {
    public let deviceId: Data
    public let privateKey: P256.KeyAgreement.PrivateKey
    public let publicKeyBytes: Data

    private init(deviceId: Data, privateKey: P256.KeyAgreement.PrivateKey, publicKeyBytes: Data) {
        self.deviceId = deviceId
        self.privateKey = privateKey
        self.publicKeyBytes = publicKeyBytes
    }

    public var deviceIdHex: String { ByteOps.toHex(deviceId) }

    public static func generate() -> LocalIdentity {
        let privateKey = AirChatCrypto.generatePrivateKey()
        return LocalIdentity(
            deviceId: AirChatCrypto.randomDeviceId(),
            privateKey: privateKey,
            publicKeyBytes: AirChatCrypto.publicKeyBytes(privateKey.publicKey)
        )
    }

    /// Rebuilds an identity from the bytes produced by `toRecord(nickname:)`.
    public static func from(record: IdentityRecord) throws -> LocalIdentity {
        guard record.deviceId.count == AirChatProtocol.deviceIdBytes else {
            throw AirChatError.format("stored deviceId must be \(AirChatProtocol.deviceIdBytes) bytes")
        }
        guard record.publicKey.count == AirChatProtocol.publicKeyBytes else {
            throw AirChatError.format("stored public key must be \(AirChatProtocol.publicKeyBytes) bytes")
        }
        // Validate both halves before trusting them: a corrupt row must fail loudly rather than
        // silently producing a bogus identity.
        let privateKey = try AirChatCrypto.privateKey(fromRaw: record.privateKeyRaw)
        _ = try AirChatCrypto.publicKey(fromRaw: record.publicKey)
        return LocalIdentity(
            deviceId: record.deviceId,
            privateKey: privateKey,
            publicKeyBytes: record.publicKey
        )
    }

    public func toRecord(nickname: String) -> IdentityRecord {
        IdentityRecord(
            deviceId: deviceId,
            privateKeyRaw: AirChatCrypto.privateKeyScalar(privateKey),
            publicKey: publicKeyBytes,
            nickname: nickname
        )
    }
}
