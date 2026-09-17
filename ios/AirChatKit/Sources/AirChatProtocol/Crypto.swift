import CryptoKit
import Foundation

/// Cryptography for the AirChat wire protocol, built on CryptoKit only.
///
/// See `docs/protocol.md` section 10. The Kotlin implementation uses JCA; both must produce
/// identical bytes, and `testdata/` holds the golden vectors that prove it.
public enum AirChatCrypto {

    private static let sessionKeyPrefix = Data("AirChat-v1-session-key".utf8)
    private static let safetyPrefix = Data("AirChat-v1-safety".utf8)
    private static let hkdfSaltLabel = Data("AirChat-v1-salt".utf8)

    // ------------------------------------------------------------- randomness

    /// `UInt8.random(in:)` is backed by `SystemRandomNumberGenerator`, which Apple documents as
    /// cryptographically secure on all supported platforms.
    public static func randomData(_ count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        for index in 0..<count {
            bytes[index] = UInt8.random(in: UInt8.min...UInt8.max)
        }
        return Data(bytes)
    }

    public static func randomNonce() -> Data { randomData(AirChatProtocol.aeadNonceBytes) }
    public static func randomDeviceId() -> Data { randomData(AirChatProtocol.deviceIdBytes) }
    public static func randomMessageId() -> Data { randomData(AirChatProtocol.msgIdBytes) }

    /// Random connect ticket advertised in the presence block (protocol section 5.3).
    public static func randomTicket() -> Int { Int(UInt16.random(in: UInt16.min...UInt16.max)) }

    // --------------------------------------------------------------- hashing

    public static func sha256(_ data: Data) -> Data {
        Data(SHA256.hash(data: data))
    }

    // ------------------------------------------------------------ identities

    public static func generatePrivateKey() -> P256.KeyAgreement.PrivateKey {
        P256.KeyAgreement.PrivateKey()
    }

    /// Uncompressed X9.63 point `0x04 || X || Y` (65 bytes), matching the Android side and
    /// `docs/protocol.md` section 10.1.
    ///
    /// CryptoKit trap, measured on macOS 27 / Xcode 27: `rawRepresentation` for a P-256 **public**
    /// key is 64 bytes (X || Y with no tag byte), not 65. `x963Representation` is the 65-byte
    /// `0x04 || X || Y` form the wire format requires. Using `rawRepresentation` here produces
    /// keys that every peer rejects and that cannot be persisted, so this must stay on x9.63.
    ///
    /// (The **private** key is different again: its `rawRepresentation` is the 32-byte scalar,
    /// which is what [rawRepresentation(_:)] intentionally returns.)
    public static func publicKeyBytes(_ key: P256.KeyAgreement.PublicKey) -> Data {
        key.x963Representation
    }

    /// The 32-byte private scalar, used for persistence.
    ///
    /// Named explicitly rather than `rawRepresentation` because the same-looking property on a
    /// **public** key returns a different shape (see [publicKeyBytes]). One of these two is a
    /// trap, so they must not share a name.
    public static func privateKeyScalar(_ key: P256.KeyAgreement.PrivateKey) -> Data {
        key.rawRepresentation
    }

    public static func privateKey(fromRaw raw: Data) throws -> P256.KeyAgreement.PrivateKey {
        try P256.KeyAgreement.PrivateKey(rawRepresentation: raw)
    }

    public static func publicKey(fromRaw raw: Data) throws -> P256.KeyAgreement.PublicKey {
        // Counterpart of publicKeyBytes: 65-byte x9.63, not the 64-byte raw form.
        try P256.KeyAgreement.PublicKey(x963Representation: raw)
    }

    // --------------------------------------------------------------- key agree

    /// Raw ECDH shared secret: the 32-byte X coordinate, matching JCA's `KeyAgreement` output.
    public static func ecdh(
        privateKey: P256.KeyAgreement.PrivateKey,
        peerPublicKey: P256.KeyAgreement.PublicKey
    ) throws -> Data {
        let secret = try privateKey.sharedSecretFromKeyAgreement(with: peerPublicKey)
        return secret.withUnsafeBytes { Data($0) }
    }

    // -------------------------------------------------------------- HKDF

    /// HKDF-SHA256 (RFC 5869). An empty salt is treated as `HashLen` zero bytes, per the RFC.
    public static func hkdfSha256(ikm: Data, salt: Data, info: Data, length: Int) -> Data {
        let effectiveSalt = salt.isEmpty ? Data(repeating: 0, count: 32) : salt
        let derived = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: ikm),
            salt: effectiveSalt,
            info: info,
            outputByteCount: length
        )
        return derived.withUnsafeBytes { Data($0) }
    }

    // ------------------------------------------------------- session key

    public static let hkdfSalt: Data = sha256(hkdfSaltLabel)

    /// Derives the 32-byte session key. Both peers must produce the same value, so the pairing is
    /// ordered purely by deviceId and the public keys follow that same order.
    public static func deriveSessionKey(
        sharedSecret: Data,
        deviceIdA: Data,
        deviceIdB: Data,
        publicKeyA: Data,
        publicKeyB: Data
    ) -> Data {
        let pair = orderedPair(
            deviceIdA: deviceIdA,
            deviceIdB: deviceIdB,
            publicKeyA: publicKeyA,
            publicKeyB: publicKeyB
        )
        let info = ByteOps.concat(
            sessionKeyPrefix,
            pair.firstDevice,
            pair.secondDevice,
            pair.firstKey,
            pair.secondKey
        )
        return hkdfSha256(ikm: sharedSecret, salt: hkdfSalt, info: info, length: 32)
    }

    // ------------------------------------------------------- safety number

    /// 6-digit safety number shown to both users. Identical inputs must yield an identical string
    /// on both platforms; a mismatch means a man in the middle or a broken port.
    public static func safetyNumber(
        deviceIdA: Data,
        deviceIdB: Data,
        publicKeyA: Data,
        publicKeyB: Data,
        initiatorHelloNonce: Data,
        responderHelloNonce: Data
    ) -> String {
        let pair = orderedPair(
            deviceIdA: deviceIdA,
            deviceIdB: deviceIdB,
            publicKeyA: publicKeyA,
            publicKeyB: publicKeyB
        )
        let transcript = ByteOps.concat(
            safetyPrefix,
            pair.firstDevice,
            pair.secondDevice,
            pair.firstKey,
            pair.secondKey,
            initiatorHelloNonce,
            responderHelloNonce
        )
        let digest = [UInt8](sha256(transcript))
        let value20 = (Int(digest[0]) << 12) | (Int(digest[1]) << 4) | (Int(digest[2]) >> 4)
        return String(format: "%06d", value20 % 1_000_000)
    }

    private struct OrderedPair {
        let firstDevice: Data
        let secondDevice: Data
        let firstKey: Data
        let secondKey: Data
    }

    private static func orderedPair(
        deviceIdA: Data,
        deviceIdB: Data,
        publicKeyA: Data,
        publicKeyB: Data
    ) -> OrderedPair {
        if ByteOps.compareUnsigned(deviceIdA, deviceIdB) <= 0 {
            return OrderedPair(
                firstDevice: deviceIdA,
                secondDevice: deviceIdB,
                firstKey: publicKeyA,
                secondKey: publicKeyB
            )
        }
        return OrderedPair(
            firstDevice: deviceIdB,
            secondDevice: deviceIdA,
            firstKey: publicKeyB,
            secondKey: publicKeyA
        )
    }

    // ----------------------------------------------------------- AEAD

    /// Returns `ciphertext || tag`.
    ///
    /// CryptoKit's `SealedBox.combined` prefixes the nonce; AirChat carries the nonce in the
    /// frame header instead, so ciphertext and tag are concatenated explicitly. Getting this
    /// wrong silently breaks interoperability with the Android implementation.
    public static func seal(key: Data, nonce: Data, plaintext: Data, aad: Data) -> Data? {
        guard key.count == 32 else { return nil }
        guard nonce.count == AirChatProtocol.aeadNonceBytes else { return nil }
        do {
            let box = try ChaChaPoly.seal(
                plaintext,
                using: SymmetricKey(data: key),
                nonce: try ChaChaPoly.Nonce(data: nonce),
                authenticating: aad
            )
            var out = Data()
            out.reserveCapacity(box.ciphertext.count + box.tag.count)
            out.append(box.ciphertext)
            out.append(box.tag)
            return out
        } catch {
            return nil
        }
    }

    /// Returns the plaintext, or nil when authentication fails.
    public static func open(key: Data, nonce: Data, ciphertextAndTag: Data, aad: Data) -> Data? {
        guard key.count == 32 else { return nil }
        guard nonce.count == AirChatProtocol.aeadNonceBytes else { return nil }
        guard ciphertextAndTag.count >= AirChatProtocol.aeadTagBytes else { return nil }

        let tagStart = ciphertextAndTag.count - AirChatProtocol.aeadTagBytes
        let bytes = [UInt8](ciphertextAndTag)
        let ciphertext = Data(bytes[0..<tagStart])
        let tag = Data(bytes[tagStart..<bytes.count])

        do {
            let box = try ChaChaPoly.SealedBox(
                nonce: try ChaChaPoly.Nonce(data: nonce),
                ciphertext: ciphertext,
                tag: tag
            )
            return try ChaChaPoly.open(box, using: SymmetricKey(data: key), authenticating: aad)
        } catch {
            return nil
        }
    }

    /// Builds the AAD for a private message: `msgId || senderId || recipientId`.
    public static func privateMessageAad(msgId: Data, senderId: Data, recipientId: Data) -> Data {
        ByteOps.concat(msgId, senderId, recipientId)
    }
}
