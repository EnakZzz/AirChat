package com.airchat.protocol

import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Cross-checks the Kotlin crypto against vectors produced by an independent Python
 * implementation (`tools/gen_testvectors.py`). RFC 5869 and RFC 8439 cases pin the
 * primitives; the AirChat cases pin the composition.
 */
class CryptoVectorsTest {

    @Test
    fun `hkdf-sha256 matches RFC 5869 vectors`() {
        val cases = TestVectors.load("hkdf-sha256-rfc5869.json")["cases"]!!.jsonArray
        assertTrue("expected at least 3 HKDF cases", cases.size >= 3)
        for (case in cases) {
            val obj = case.jsonObject
            val name = obj["name"]!!.jsonPrimitive.content
            val ikm = TestVectors.hex(obj["ikmHex"]!!)
            val salt = TestVectors.hex(obj["saltHex"]!!)
            val info = TestVectors.hex(obj["infoHex"]!!)
            val length = TestVectors.int(obj["length"]!!)
            val expected = TestVectors.hex(obj["okmHex"]!!)

            val actual = AirChatCrypto.hkdfSha256(ikm, salt, info, length)
            assertEquals("HKDF case $name", ByteOps.toHex(expected), ByteOps.toHex(actual))
        }
    }

    @Test
    fun `chacha20-poly1305 matches RFC 8439 and the AirChat shape`() {
        val cases = TestVectors.load("chacha20poly1305-rfc8439.json")["cases"]!!.jsonArray
        assertTrue(cases.size >= 2)
        for (case in cases) {
            val obj = case.jsonObject
            val name = obj["name"]!!.jsonPrimitive.content
            val key = TestVectors.hex(obj["keyHex"]!!)
            val nonce = TestVectors.hex(obj["nonceHex"]!!)
            val aad = TestVectors.hex(obj["aadHex"]!!)
            val plaintext = TestVectors.hex(obj["plaintextHex"]!!)
            val expectedSealed = TestVectors.hex(obj["ciphertextAndTagHex"]!!)

            val sealed = AirChatCrypto.seal(key, nonce, plaintext, aad)
            assertEquals("seal $name", ByteOps.toHex(expectedSealed), ByteOps.toHex(sealed))

            val opened = AirChatCrypto.open(key, nonce, sealed, aad)
            assertNotNull("open $name", opened)
            assertEquals("open $name", ByteOps.toHex(plaintext), ByteOps.toHex(opened!!))
        }
    }

    @Test
    fun `aead rejects a tampered tag or aad`() {
        val vector = TestVectors.load("chacha20poly1305-rfc8439.json")["cases"]!!.jsonArray[0].jsonObject
        val key = TestVectors.hex(vector["keyHex"]!!)
        val nonce = TestVectors.hex(vector["nonceHex"]!!)
        val aad = TestVectors.hex(vector["aadHex"]!!)
        val plaintext = TestVectors.hex(vector["plaintextHex"]!!)
        val sealed = AirChatCrypto.seal(key, nonce, plaintext, aad)

        val tamperedTag = sealed.copyOf()
        tamperedTag[tamperedTag.size - 1] = (tamperedTag[tamperedTag.size - 1].toInt() xor 0x01).toByte()
        assertNull("flipped tag bit must fail authentication", AirChatCrypto.open(key, nonce, tamperedTag, aad))

        val tamperedAad = aad.copyOf()
        tamperedAad[0] = (tamperedAad[0].toInt() xor 0x01).toByte()
        assertNull("tampered AAD must fail authentication", AirChatCrypto.open(key, nonce, sealed, tamperedAad))
    }

    @Test
    fun `p256 ecdh matches the vector and is symmetric`() {
        val vector = TestVectors.load("p256-ecdh.json")
        val alicePrivate = AirChatCrypto.privateKeyFromScalar(TestVectors.hex(vector["alice"]!!.jsonObject["privateKeyHex"]!!))
        val bobPrivate = AirChatCrypto.privateKeyFromScalar(TestVectors.hex(vector["bob"]!!.jsonObject["privateKeyHex"]!!))
        val alicePublicRaw = TestVectors.hex(vector["alice"]!!.jsonObject["publicKeyHex"]!!)
        val bobPublicRaw = TestVectors.hex(vector["bob"]!!.jsonObject["publicKeyHex"]!!)
        val expectedShared = TestVectors.hex(vector["sharedSecretHex"]!!)

        // Public key encoding must round-trip the published uncompressed point exactly.
        val roundTripped = AirChatCrypto.encodePublicKey(AirChatCrypto.decodePublicKey(alicePublicRaw))
        assertEquals(ByteOps.toHex(alicePublicRaw), ByteOps.toHex(roundTripped))
        assertEquals(65, alicePublicRaw.size)

        val sharedFromAlice = AirChatCrypto.ecdh(alicePrivate, AirChatCrypto.decodePublicKey(bobPublicRaw))
        val sharedFromBob = AirChatCrypto.ecdh(bobPrivate, AirChatCrypto.decodePublicKey(alicePublicRaw))
        assertEquals(ByteOps.toHex(expectedShared), ByteOps.toHex(sharedFromAlice))
        assertEquals(ByteOps.toHex(expectedShared), ByteOps.toHex(sharedFromBob))
    }

    @Test
    fun `session key derivation matches the vector for both peers`() {
        val vector = TestVectors.load("session-key.json")
        val aliceDevice = TestVectors.hex(vector["aliceDeviceIdHex"]!!)
        val bobDevice = TestVectors.hex(vector["bobDeviceIdHex"]!!)
        val alicePublic = TestVectors.hex(vector["alicePublicKeyHex"]!!)
        val bobPublic = TestVectors.hex(vector["bobPublicKeyHex"]!!)
        val expectedKey = TestVectors.hex(vector["expectedSessionKeyHex"]!!)

        // salt / info prefixes are part of the frozen contract: assert the published values.
        assertEquals(
            ByteOps.toHex(TestVectors.hex(vector["hkdfSaltHex"]!!)),
            ByteOps.toHex(AirChatCrypto.hkdfSalt),
        )
        assertEquals(
            vector["hkdfInfoPrefixHex"]!!.jsonPrimitive.content,
            ByteOps.toHex("AirChat-v1-session-key".toByteArray(Charsets.UTF_8)),
        )

        val shared = TestVectors.hex(vector["expectedSharedSecretHex"]!!)

        val fromAlice = AirChatCrypto.deriveSessionKey(shared, aliceDevice, bobDevice, alicePublic, bobPublic)
        // Argument order must not matter: the pairing is ordered by deviceId internally.
        val fromBob = AirChatCrypto.deriveSessionKey(shared, bobDevice, aliceDevice, bobPublic, alicePublic)

        assertEquals(ByteOps.toHex(expectedKey), ByteOps.toHex(fromAlice))
        assertEquals(ByteOps.toHex(expectedKey), ByteOps.toHex(fromBob))
    }

    @Test
    fun `safety number matches the vector and ignores argument order`() {
        val vector = TestVectors.load("safety-number.json")
        val aliceDevice = TestVectors.hex(vector["aliceDeviceIdHex"]!!)
        val bobDevice = TestVectors.hex(vector["bobDeviceIdHex"]!!)
        val alicePublic = TestVectors.hex(vector["alicePublicKeyHex"]!!)
        val bobPublic = TestVectors.hex(vector["bobPublicKeyHex"]!!)
        val expectedCode = vector["expectedCode"]!!.jsonPrimitive.content

        val code = AirChatCrypto.safetyNumber(aliceDevice, bobDevice, alicePublic, bobPublic)
        assertEquals(expectedCode, code)
        assertEquals(6, code.length)
        assertTrue("code must be numeric", code.all { it.isDigit() })

        // Swapping the device/key argument order must not change the code.
        assertEquals(
            expectedCode,
            AirChatCrypto.safetyNumber(bobDevice, aliceDevice, bobPublic, alicePublic),
        )

        // A different pair must produce a different code, or the vector would hold even for a
        // function that ignored its inputs.
        val other = vector["otherPair"]!!.jsonObject
        val otherCode = AirChatCrypto.safetyNumber(
            TestVectors.hex(other["aliceDeviceIdHex"]!!),
            TestVectors.hex(other["bobDeviceIdHex"]!!),
            alicePublic,
            bobPublic,
        )
        assertEquals(other["expectedCode"]!!.jsonPrimitive.content, otherCode)
        assertFalse("a different pair must not share a code", otherCode == expectedCode)
    }
}
