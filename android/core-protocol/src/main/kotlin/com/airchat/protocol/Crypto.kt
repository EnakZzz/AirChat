package com.airchat.protocol

import java.math.BigInteger
import java.security.AlgorithmParameters
import java.security.KeyFactory
import java.security.KeyPair
import java.security.KeyPairGenerator
import java.security.MessageDigest
import java.security.PrivateKey
import java.security.SecureRandom
import java.security.interfaces.ECPublicKey
import java.security.spec.ECGenParameterSpec
import java.security.spec.ECParameterSpec
import java.security.spec.ECPrivateKeySpec
import java.security.spec.ECPoint
import java.security.spec.ECPublicKeySpec
import java.security.spec.PKCS8EncodedKeySpec
import javax.crypto.Cipher
import javax.crypto.KeyAgreement
import javax.crypto.Mac
import javax.crypto.spec.IvParameterSpec
import javax.crypto.spec.SecretKeySpec

/**
 * Cryptography for the AirChat wire protocol, implemented directly on JCA so that the exact
 * same source compiles for Android and runs under a plain JVM (which is what makes the
 * protocol module unit-testable without a device).
 *
 * See `docs/protocol.md` section 10 for the specification. The iOS side uses CryptoKit
 * (`P256.KeyAgreement` + `HKDF<SHA256>` + `ChaChaPoly`) and must produce identical bytes;
 * `testdata/` holds the golden vectors that prove it.
 */
object AirChatCrypto {
    private const val CURVE = "secp256r1"
    private const val ECDH = "ECDH"
    private const val HMAC = "HmacSHA256"
    private const val AEAD = "ChaCha20-Poly1305"
    private const val HASH = "SHA-256"

    private const val SESSION_KEY_PREFIX = "AirChat-v1-session-key"
    private const val SAFETY_PREFIX = "AirChat-v1-safety"
    private const val HKDF_SALT_LABEL = "AirChat-v1-salt"

    private val secureRandom = SecureRandom()

    private val ecParameterSpec: ECParameterSpec by lazy {
        AlgorithmParameters.getInstance("EC").apply {
            init(ECGenParameterSpec(CURVE))
        }.getParameterSpec(ECParameterSpec::class.java)
    }

    // ------------------------------------------------------------- randomness

    fun randomBytes(count: Int): ByteArray {
        val out = ByteArray(count)
        secureRandom.nextBytes(out)
        return out
    }

    fun randomNonce(): ByteArray = randomBytes(AirChatProtocol.AEAD_NONCE_BYTES)

    fun randomDeviceId(): ByteArray = randomBytes(AirChatProtocol.DEVICE_ID_BYTES)

    fun randomMessageId(): ByteArray = randomBytes(AirChatProtocol.MSG_ID_BYTES)

    /** Random connect ticket advertised in the presence block (protocol section 5.3). */
    fun randomTicket(): Int = secureRandom.nextInt(0x10000)

    // --------------------------------------------------------------- hashing

    fun sha256(data: ByteArray): ByteArray =
        MessageDigest.getInstance(HASH).digest(data)

    // ------------------------------------------------------------ identities

    fun generateKeyPair(): KeyPair {
        val generator = KeyPairGenerator.getInstance("EC")
        generator.initialize(ECGenParameterSpec(CURVE), secureRandom)
        return generator.generateKeyPair()
    }

    fun privateKeyFromPkcs8(encoded: ByteArray): PrivateKey =
        KeyFactory.getInstance("EC").generatePrivate(PKCS8EncodedKeySpec(encoded))

    /**
     * Rebuilds a private key from its raw 32-byte scalar. The iOS side persists keys as raw
     * scalars (CryptoKit `rawRepresentation`), and the golden vectors are stored the same way.
     */
    fun privateKeyFromScalar(scalar: ByteArray): PrivateKey =
        KeyFactory.getInstance("EC").generatePrivate(
            ECPrivateKeySpec(BigInteger(1, scalar), ecParameterSpec),
        )

    /** Serialises a public key as the uncompressed point `0x04 || X || Y` (65 bytes). */
    fun encodePublicKey(publicKey: ECPublicKey): ByteArray {
        val point = publicKey.w
        return ByteOps.concat(
            byteArrayOf(0x04),
            fixedWidth(point.affineX, 32),
            fixedWidth(point.affineY, 32),
        )
    }

    fun decodePublicKey(encoded: ByteArray): ECPublicKey {
        require(encoded.size == AirChatProtocol.PUBLIC_KEY_BYTES) {
            "public key must be ${AirChatProtocol.PUBLIC_KEY_BYTES} bytes"
        }
        require(encoded[0] == 0x04.toByte()) { "public key must be an uncompressed point" }
        val x = BigInteger(1, encoded.copyOfRange(1, 33))
        val y = BigInteger(1, encoded.copyOfRange(33, 65))
        return KeyFactory.getInstance("EC")
            .generatePublic(ECPublicKeySpec(ECPoint(x, y), ecParameterSpec)) as ECPublicKey
    }

    private fun fixedWidth(value: BigInteger, width: Int): ByteArray {
        val raw = value.toByteArray()
        val out = ByteArray(width)
        when {
            raw.size == width -> System.arraycopy(raw, 0, out, 0, width)
            raw.size > width -> System.arraycopy(raw, raw.size - width, out, 0, width)
            else -> System.arraycopy(raw, 0, out, width - raw.size, raw.size)
        }
        return out
    }

    // --------------------------------------------------------------- key agree

    /** Raw ECDH shared secret (the 32-byte X coordinate). */
    fun ecdh(privateKey: PrivateKey, peerPublicKey: ECPublicKey): ByteArray {
        val agreement = KeyAgreement.getInstance(ECDH)
        agreement.init(privateKey)
        agreement.doPhase(peerPublicKey, true)
        return agreement.generateSecret()
    }

    // -------------------------------------------------------------- HKDF

    /**
     * HKDF-SHA256 (RFC 5869). An empty salt is treated as `HashLen` zero bytes, per the RFC.
     */
    fun hkdfSha256(ikm: ByteArray, salt: ByteArray, info: ByteArray, length: Int): ByteArray {
        require(length > 0 && length <= 255 * 32) { "invalid HKDF output length $length" }
        val effectiveSalt = if (salt.isEmpty()) ByteArray(32) else salt
        val prk = hmac(effectiveSalt, ikm)

        val okm = ByteArray(length)
        var previous = ByteArray(0)
        var generated = 0
        var counter = 1
        while (generated < length) {
            val mac = Mac.getInstance(HMAC)
            mac.init(SecretKeySpec(prk, HMAC))
            mac.update(previous)
            mac.update(info)
            mac.update(counter.toByte())
            previous = mac.doFinal()
            val take = minOf(previous.size, length - generated)
            System.arraycopy(previous, 0, okm, generated, take)
            generated += take
            counter++
        }
        return okm
    }

    private fun hmac(key: ByteArray, data: ByteArray): ByteArray {
        val mac = Mac.getInstance(HMAC)
        // HmacSHA256 rejects empty keys; an all-zero block keeps the output identical either way.
        mac.init(SecretKeySpec(if (key.isEmpty()) ByteArray(32) else key, HMAC))
        return mac.doFinal(data)
    }

    // ------------------------------------------------------- session key

    val hkdfSalt: ByteArray by lazy { sha256(HKDF_SALT_LABEL.toByteArray(Charsets.UTF_8)) }

    /**
     * Derives the 32-byte session key. Both peers must produce the same value, so the pairing
     * is ordered purely by deviceId and the public keys follow that same order.
     */
    fun deriveSessionKey(
        sharedSecret: ByteArray,
        deviceIdA: ByteArray,
        deviceIdB: ByteArray,
        publicKeyA: ByteArray,
        publicKeyB: ByteArray,
    ): ByteArray {
        val (firstDevice, secondDevice, firstKey, secondKey) = orderedPair(
            deviceIdA, deviceIdB, publicKeyA, publicKeyB,
        )
        val info = ByteOps.concat(
            SESSION_KEY_PREFIX.toByteArray(Charsets.UTF_8),
            firstDevice,
            secondDevice,
            firstKey,
            secondKey,
        )
        return hkdfSha256(sharedSecret, hkdfSalt, info, 32)
    }

    // ------------------------------------------------------- safety number

    /**
     * 6-digit safety number shown to both users. Identical inputs must yield an identical
     * string on both platforms; a mismatch means a man in the middle or a broken port.
     */
    fun safetyNumber(
        deviceIdA: ByteArray,
        deviceIdB: ByteArray,
        publicKeyA: ByteArray,
        publicKeyB: ByteArray,
        initiatorHelloNonce: ByteArray,
        responderHelloNonce: ByteArray,
    ): String {
        val (firstDevice, secondDevice, firstKey, secondKey) = orderedPair(
            deviceIdA, deviceIdB, publicKeyA, publicKeyB,
        )
        val transcript = ByteOps.concat(
            SAFETY_PREFIX.toByteArray(Charsets.UTF_8),
            firstDevice,
            secondDevice,
            firstKey,
            secondKey,
            initiatorHelloNonce,
            responderHelloNonce,
        )
        val digest = sha256(transcript)
        val value20 = ((digest[0].toInt() and 0xFF) shl 12) or
            ((digest[1].toInt() and 0xFF) shl 4) or
            ((digest[2].toInt() and 0xFF) ushr 4)
        return (value20 % 1_000_000).toString().padStart(6, '0')
    }

    private data class OrderedPair(
        val firstDevice: ByteArray,
        val secondDevice: ByteArray,
        val firstKey: ByteArray,
        val secondKey: ByteArray,
    )

    private fun orderedPair(
        deviceIdA: ByteArray,
        deviceIdB: ByteArray,
        publicKeyA: ByteArray,
        publicKeyB: ByteArray,
    ): OrderedPair = if (ByteOps.compareUnsigned(deviceIdA, deviceIdB) <= 0) {
        OrderedPair(deviceIdA, deviceIdB, publicKeyA, publicKeyB)
    } else {
        OrderedPair(deviceIdB, deviceIdA, publicKeyB, publicKeyA)
    }

    // ----------------------------------------------------------- AEAD

    /** Returns `ciphertext || tag`. */
    fun seal(key: ByteArray, nonce: ByteArray, plaintext: ByteArray, aad: ByteArray): ByteArray {
        require(key.size == 32) { "session key must be 32 bytes" }
        require(nonce.size == AirChatProtocol.AEAD_NONCE_BYTES) { "nonce must be 12 bytes" }
        val cipher = Cipher.getInstance(AEAD)
        cipher.init(Cipher.ENCRYPT_MODE, SecretKeySpec(key, AEAD), IvParameterSpec(nonce))
        cipher.updateAAD(aad)
        return cipher.doFinal(plaintext)
    }

    /** Returns the plaintext, or null when authentication fails. */
    fun open(key: ByteArray, nonce: ByteArray, ciphertextAndTag: ByteArray, aad: ByteArray): ByteArray? {
        if (key.size != 32) return null
        if (nonce.size != AirChatProtocol.AEAD_NONCE_BYTES) return null
        if (ciphertextAndTag.size < AirChatProtocol.AEAD_TAG_BYTES) return null
        return runCatching {
            val cipher = Cipher.getInstance(AEAD)
            cipher.init(Cipher.DECRYPT_MODE, SecretKeySpec(key, AEAD), IvParameterSpec(nonce))
            cipher.updateAAD(aad)
            cipher.doFinal(ciphertextAndTag)
        }.getOrNull()
    }

    /** Builds the AAD for a private message: `msgId || senderId || recipientId`. */
    fun privateMessageAad(msgId: ByteArray, senderId: ByteArray, recipientId: ByteArray): ByteArray =
        ByteOps.concat(msgId, senderId, recipientId)
}
