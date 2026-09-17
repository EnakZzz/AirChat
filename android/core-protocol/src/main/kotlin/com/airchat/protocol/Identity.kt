package com.airchat.protocol

import java.security.PrivateKey
import java.security.interfaces.ECPublicKey

/**
 * The device's long-lived identity: a P-256 key pair plus a random 16-byte deviceId.
 *
 * The key pair is generated exactly once and persisted. Changing it would invalidate every
 * peer's stored public key and force a fresh safety-number comparison, so [toRecord] and
 * [fromRecord] must round-trip losslessly.
 *
 * Both halves of the key pair are persisted. Deriving the public point from a private scalar
 * is not available through JCA, and the iOS port additionally needs the raw 32-byte scalar, so
 * the stored record carries the private key, the public point and the deviceId.
 */
class LocalIdentity private constructor(
    val deviceId: ByteArray,
    val privateKey: PrivateKey,
    val publicKeyBytes: ByteArray,
) {
    val publicKey: ECPublicKey get() = AirChatCrypto.decodePublicKey(publicKeyBytes)

    val deviceIdHex: String get() = ByteOps.toHex(deviceId)

    fun toRecord(nickname: String): IdentityRecord =
        IdentityRecord(deviceId, privateKey.encoded, publicKeyBytes, nickname)

    companion object {
        fun generate(): LocalIdentity {
            val pair = AirChatCrypto.generateKeyPair()
            return LocalIdentity(
                deviceId = AirChatCrypto.randomDeviceId(),
                privateKey = pair.private,
                publicKeyBytes = AirChatCrypto.encodePublicKey(pair.public as ECPublicKey),
            )
        }

        /** Rebuilds an identity from the bytes produced by [toRecord]. */
        fun fromRecord(record: IdentityRecord): LocalIdentity {
            require(record.deviceId.size == AirChatProtocol.DEVICE_ID_BYTES) {
                "stored deviceId must be ${AirChatProtocol.DEVICE_ID_BYTES} bytes"
            }
            require(record.publicKeyEncoded.size == AirChatProtocol.PUBLIC_KEY_BYTES) {
                "stored public key must be ${AirChatProtocol.PUBLIC_KEY_BYTES} bytes"
            }
            // Validate the stored point before trusting it; a corrupt row must fail loudly
            // rather than silently producing a bogus identity.
            AirChatCrypto.decodePublicKey(record.publicKeyEncoded)
            return LocalIdentity(
                deviceId = record.deviceId,
                privateKey = AirChatCrypto.privateKeyFromPkcs8(record.privateKeyEncoded),
                publicKeyBytes = record.publicKeyEncoded,
            )
        }
    }
}
