import CryptoKit
import XCTest
@testable import AirChatProtocol

/// Cross-checks the Swift crypto against vectors produced by an independent Python implementation
/// (`tools/gen_testvectors.py`). The RFC 5869 and RFC 8439 cases pin the primitives; the AirChat
/// cases pin the composition.
final class CryptoVectorsTests: XCTestCase {

    func testConstantsMatchTheProtocolModule() throws {
        let object = try TestVectors.load("frames.json")
        let constants = object["constants"] as? [String: Any] ?? [:]
        XCTAssertEqual(AirChatProtocol.version, TestVectors.int(constants["protocolVersion"]))
        XCTAssertEqual(AirChatProtocol.maxPayloadBytes, TestVectors.int(constants["maxPayloadBytes"]))
        XCTAssertEqual(AirChatProtocol.maxChunkBytes, TestVectors.int(constants["maxChunkBytes"]))
        XCTAssertEqual(AirChatProtocol.maxNicknameBytes, TestVectors.int(constants["maxNicknameBytes"]))
        XCTAssertEqual(AirChatProtocol.maxTextBytes, TestVectors.int(constants["maxTextBytes"]))
        XCTAssertEqual(AirChatProtocol.maxLinks, TestVectors.int(constants["maxLinks"]))
    }

    func testHkdfSha256MatchesRfc5869Vectors() throws {
        let cases = try TestVectors.array(try TestVectors.load("hkdf-sha256-rfc5869.json"), "cases")
        XCTAssertGreaterThanOrEqual(cases.count, 3)
        for item in cases {
            let name = TestVectors.string(item["name"])
            let ikm = TestVectors.hex(item["ikmHex"])
            let salt = TestVectors.hex(item["saltHex"])
            let info = TestVectors.hex(item["infoHex"])
            let length = TestVectors.int(item["length"])
            let expected = ByteOps.toHex(TestVectors.hex(item["okmHex"]))

            let actual = AirChatCrypto.hkdfSha256(ikm: ikm, salt: salt, info: info, length: length)
            XCTAssertEqual(expected, ByteOps.toHex(actual), "HKDF case \(name)")
        }
    }

    func testChaChaPolyMatchesRfc8439AndTheAirChatShape() throws {
        let cases = try TestVectors.array(try TestVectors.load("chacha20poly1305-rfc8439.json"), "cases")
        XCTAssertGreaterThanOrEqual(cases.count, 2)
        for item in cases {
            let name = TestVectors.string(item["name"])
            let key = TestVectors.hex(item["keyHex"])
            let nonce = TestVectors.hex(item["nonceHex"])
            let aad = TestVectors.hex(item["aadHex"])
            let plaintext = TestVectors.hex(item["plaintextHex"])
            let expectedSealed = ByteOps.toHex(TestVectors.hex(item["ciphertextAndTagHex"]))

            // The wire format carries the nonce separately, so the sealed output must be exactly
            // ciphertext followed by the tag (CryptoKit's `combined` would prepend the nonce).
            let sealed = try XCTUnwrap(AirChatCrypto.seal(key: key, nonce: nonce, plaintext: plaintext, aad: aad))
            XCTAssertEqual(expectedSealed, ByteOps.toHex(sealed), "seal \(name)")
            XCTAssertEqual(plaintext.count + AirChatProtocol.aeadTagBytes, sealed.count)

            let opened = try XCTUnwrap(
                AirChatCrypto.open(key: key, nonce: nonce, ciphertextAndTag: sealed, aad: aad),
                "open \(name)"
            )
            XCTAssertEqual(ByteOps.toHex(plaintext), ByteOps.toHex(opened))
        }
    }

    func testAeadRejectsTamperedTagOrAad() throws {
        let cases = try TestVectors.array(try TestVectors.load("chacha20poly1305-rfc8439.json"), "cases")
        let item = try XCTUnwrap(cases.first)
        let key = TestVectors.hex(item["keyHex"])
        let nonce = TestVectors.hex(item["nonceHex"])
        let aad = TestVectors.hex(item["aadHex"])
        let plaintext = TestVectors.hex(item["plaintextHex"])
        let sealed = try XCTUnwrap(AirChatCrypto.seal(key: key, nonce: nonce, plaintext: plaintext, aad: aad))

        // Mutate through byte arrays: Data indices are only guaranteed to start at zero for the
        // values we build ourselves, so this stays valid regardless of the backing storage.
        var tamperedTagBytes = [UInt8](sealed)
        tamperedTagBytes[tamperedTagBytes.count - 1] ^= 0x01
        XCTAssertNil(
            AirChatCrypto.open(key: key, nonce: nonce, ciphertextAndTag: Data(tamperedTagBytes), aad: aad)
        )

        var tamperedAadBytes = [UInt8](aad)
        tamperedAadBytes[0] ^= 0x01
        XCTAssertNil(
            AirChatCrypto.open(key: key, nonce: nonce, ciphertextAndTag: sealed, aad: Data(tamperedAadBytes))
        )
    }

    func testP256EcdhMatchesTheVectorAndIsSymmetric() throws {
        let object = try TestVectors.load("p256-ecdh.json")
        let alice = try XCTUnwrap(object["alice"] as? [String: Any])
        let bob = try XCTUnwrap(object["bob"] as? [String: Any])

        let alicePrivate = try AirChatCrypto.privateKey(fromRaw: TestVectors.hex(alice["privateKeyHex"]))
        let bobPrivate = try AirChatCrypto.privateKey(fromRaw: TestVectors.hex(bob["privateKeyHex"]))
        let alicePublicRaw = TestVectors.hex(alice["publicKeyHex"])
        let bobPublicRaw = TestVectors.hex(bob["publicKeyHex"])
        let expectedShared = ByteOps.toHex(TestVectors.hex(object["sharedSecretHex"]))

        // Deriving the public key from the raw scalar must reproduce the published point, which is
        // the exact byte layout the Android side encodes.
        XCTAssertEqual(ByteOps.toHex(alicePublicRaw), ByteOps.toHex(AirChatCrypto.publicKeyBytes(alicePrivate.publicKey)))
        XCTAssertEqual(65, alicePublicRaw.count)

        let bobPublic = try AirChatCrypto.publicKey(fromRaw: bobPublicRaw)
        let alicePublic = try AirChatCrypto.publicKey(fromRaw: alicePublicRaw)
        XCTAssertEqual(expectedShared, ByteOps.toHex(try AirChatCrypto.ecdh(privateKey: alicePrivate, peerPublicKey: bobPublic)))
        XCTAssertEqual(expectedShared, ByteOps.toHex(try AirChatCrypto.ecdh(privateKey: bobPrivate, peerPublicKey: alicePublic)))
    }

    func testSessionKeyDerivationMatchesTheVectorForBothPeers() throws {
        let object = try TestVectors.load("session-key.json")
        let aliceDevice = TestVectors.hex(object["aliceDeviceIdHex"])
        let bobDevice = TestVectors.hex(object["bobDeviceIdHex"])
        let alicePublic = TestVectors.hex(object["alicePublicKeyHex"])
        let bobPublic = TestVectors.hex(object["bobPublicKeyHex"])
        let expectedKey = ByteOps.toHex(TestVectors.hex(object["expectedSessionKeyHex"]))
        let shared = TestVectors.hex(object["expectedSharedSecretHex"])

        // The salt and info prefixes are part of the frozen contract.
        XCTAssertEqual(ByteOps.toHex(TestVectors.hex(object["hkdfSaltHex"])), ByteOps.toHex(AirChatCrypto.hkdfSalt))
        XCTAssertEqual(
            TestVectors.string(object["hkdfInfoPrefixHex"]),
            ByteOps.toHex(Data("AirChat-v1-session-key".utf8))
        )

        let fromAlice = AirChatCrypto.deriveSessionKey(
            sharedSecret: shared,
            deviceIdA: aliceDevice,
            deviceIdB: bobDevice,
            publicKeyA: alicePublic,
            publicKeyB: bobPublic
        )
        // Argument order must not matter: the pairing is ordered by deviceId internally.
        let fromBob = AirChatCrypto.deriveSessionKey(
            sharedSecret: shared,
            deviceIdA: bobDevice,
            deviceIdB: aliceDevice,
            publicKeyA: bobPublic,
            publicKeyB: alicePublic
        )
        XCTAssertEqual(expectedKey, ByteOps.toHex(fromAlice))
        XCTAssertEqual(expectedKey, ByteOps.toHex(fromBob))
    }

    func testSafetyNumberMatchesTheVectorAndIgnoresArgumentOrder() throws {
        let object = try TestVectors.load("safety-number.json")
        let aliceDevice = TestVectors.hex(object["aliceDeviceIdHex"])
        let bobDevice = TestVectors.hex(object["bobDeviceIdHex"])
        let alicePublic = TestVectors.hex(object["alicePublicKeyHex"])
        let bobPublic = TestVectors.hex(object["bobPublicKeyHex"])
        let initiatorNonce = TestVectors.hex(object["initiatorHelloNonceHex"])
        let responderNonce = TestVectors.hex(object["responderHelloNonceHex"])
        let expectedCode = TestVectors.string(object["expectedCode"])

        let code = AirChatCrypto.safetyNumber(
            deviceIdA: aliceDevice,
            deviceIdB: bobDevice,
            publicKeyA: alicePublic,
            publicKeyB: bobPublic,
            initiatorHelloNonce: initiatorNonce,
            responderHelloNonce: responderNonce
        )
        XCTAssertEqual(expectedCode, code)
        XCTAssertEqual(6, code.count)
        XCTAssertTrue(code.allSatisfy { $0.isNumber })

        // Swapping the device/key argument order must not change the code.
        let swapped = AirChatCrypto.safetyNumber(
            deviceIdA: bobDevice,
            deviceIdB: aliceDevice,
            publicKeyA: bobPublic,
            publicKeyB: alicePublic,
            initiatorHelloNonce: initiatorNonce,
            responderHelloNonce: responderNonce
        )
        XCTAssertEqual(expectedCode, swapped)

        // Swapping initiator/responder nonces must change the code.
        let swappedNonces = AirChatCrypto.safetyNumber(
            deviceIdA: aliceDevice,
            deviceIdB: bobDevice,
            publicKeyA: alicePublic,
            publicKeyB: bobPublic,
            initiatorHelloNonce: responderNonce,
            responderHelloNonce: initiatorNonce
        )
        XCTAssertNotEqual(expectedCode, swappedNonces)

        let secondPair = try XCTUnwrap(object["secondPair"] as? [String: Any])
        XCTAssertEqual(
            TestVectors.string(secondPair["expectedCode"]),
            AirChatCrypto.safetyNumber(
                deviceIdA: aliceDevice,
                deviceIdB: bobDevice,
                publicKeyA: alicePublic,
                publicKeyB: bobPublic,
                initiatorHelloNonce: TestVectors.hex(secondPair["initiatorHelloNonceHex"]),
                responderHelloNonce: TestVectors.hex(secondPair["responderHelloNonceHex"])
            )
        )
    }
}
