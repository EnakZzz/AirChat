#!/usr/bin/env python3
"""Generate cross-platform golden test vectors for the AirChat wire protocol.

This generator is an INDEPENDENT implementation (Python `cryptography`), so the
vectors it emits are genuine cross-checks for the Kotlin and Swift ports rather
than self-fulfilling assertions.

Usage:  python tools/gen_testvectors.py
Output: testdata/*.json
"""

import hashlib
import json
import os
import struct

from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.ciphers.aead import ChaCha20Poly1305
from cryptography.hazmat.primitives.kdf.hkdf import HKDF
from cryptography.hazmat.primitives import hashes

OUT_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "testdata")

# ---------------------------------------------------------------------------
# Protocol constants - mirrors docs/protocol.md section 2
# ---------------------------------------------------------------------------
PROTOCOL_VERSION = 1
MAX_PAYLOAD_BYTES = 6144
MAX_CHUNK_BYTES = 512
MAX_NICKNAME_BYTES = 32
MAX_TEXT_BYTES = 4000
MAX_LINKS = 8

SAFETY_PREFIX = b"AirChat-v1-safety"
SESSION_KEY_PREFIX = b"AirChat-v1-session-key"
HKDF_SALT_LABEL = b"AirChat-v1-salt"

TYPE_HELLO = 0x01
TYPE_HELLO_ACK = 0x02
TYPE_CHANNEL_POST = 0x10
TYPE_PRIVATE_MSG = 0x11
TYPE_DELIVERY_ACK = 0x12
TYPE_TYPING = 0x13
TYPE_SYNC_REQ = 0x20
TYPE_SYNC_RESP = 0x21
TYPE_KEY_VERIFY_REQ = 0x30
TYPE_KEY_VERIFY_RESP = 0x31
TYPE_PONG = 0x7E
TYPE_PING = 0x7F

CAP_PRIVATE = 0x01
CAP_SYNC = 0x02


def h(b: bytes) -> str:
    return b.hex()


def frame_hex(msg_type: int, payload: bytes) -> str:
    return (bytes([PROTOCOL_VERSION, msg_type]) + struct.pack(">H", len(payload)) + payload).hex()


def pub_raw(priv: ec.EllipticCurvePrivateKey) -> bytes:
    nums = priv.public_key().public_numbers()
    return (
        b"\x04"
        + nums.x.to_bytes(32, "big")
        + nums.y.to_bytes(32, "big")
    )


def sorted_pair(dev_a: bytes, dev_b: bytes):
    """Order two participants by unsigned lexicographic deviceId."""
    return (dev_a, dev_b) if dev_a <= dev_b else (dev_b, dev_a)


def session_key(my_priv, peer_pub_raw: bytes, dev_a: bytes, dev_b: bytes,
                pub_a: bytes, pub_b: bytes) -> bytes:
    first_dev, second_dev = sorted_pair(dev_a, dev_b)
    by_dev = {dev_a: pub_a, dev_b: pub_b}
    first_pub, second_pub = by_dev[first_dev], by_dev[second_dev]

    peer_pub = ec.EllipticCurvePublicKey.from_encoded_point(ec.SECP256R1(), peer_pub_raw)
    ikm = my_priv.exchange(ec.ECDH(), peer_pub)
    salt = hashlib.sha256(HKDF_SALT_LABEL).digest()
    info = (
        SESSION_KEY_PREFIX
        + first_dev + second_dev
        + first_pub + second_pub
    )
    return HKDF(algorithm=hashes.SHA256(), length=32, salt=salt, info=info).derive(ikm)


def safety_number(dev_a: bytes, dev_b: bytes, pub_a: bytes, pub_b: bytes,
                  initiator_nonce: bytes, responder_nonce: bytes) -> str:
    first_dev, second_dev = sorted_pair(dev_a, dev_b)
    by_dev = {dev_a: pub_a, dev_b: pub_b}
    first_pub, second_pub = by_dev[first_dev], by_dev[second_dev]
    transcript = (
        SAFETY_PREFIX
        + first_dev + second_dev
        + first_pub + second_pub
        + initiator_nonce + responder_nonce
    )
    digest = hashlib.sha256(transcript).digest()
    value20 = (digest[0] << 12) | (digest[1] << 4) | (digest[2] >> 4)
    return "%06d" % (value20 % 1000000)


# ---------------------------------------------------------------------------
# Fixture identities (fixed, so vectors are reproducible)
# ---------------------------------------------------------------------------
ALICE_DEV = bytes.fromhex("0f1e2d3c4b5a69788796a5b4c3d2e1f0")
BOB_DEV = bytes.fromhex("a0b1c2d3e4f50112233445566778899a")
ALICE_PRIV = bytes.fromhex("1a2b3c4d5e6f708192a3b4c5d6e7f8091a2b3c4d5e6f708192a3b4c5d6e7f809")
BOB_PRIV = bytes.fromhex("f0e1d2c3b4a5968778695a4b3c2d1e0ff0e1d2c3b4a5968778695a4b3c2d1e0f")
ALICE_NAME = "\u5c0f\u660e".encode("utf-8")        # 小明
BOB_NAME = b"Bob"

# Bob has the larger deviceId, so Bob is the initiator: this proves the transcript
# uses initiator/responder nonce order independently of the deviceId sort order.
INITIATOR_NONCE = bytes.fromhex("b0b1b2b3b4b5b6b7")
RESPONDER_NONCE = bytes.fromhex("a0a1a2a3a4a5a6a7")


def build_identities():
    a_priv = ec.derive_private_key(int.from_bytes(ALICE_PRIV, "big"), ec.SECP256R1())
    b_priv = ec.derive_private_key(int.from_bytes(BOB_PRIV, "big"), ec.SECP256R1())
    return a_priv, b_priv, pub_raw(a_priv), pub_raw(b_priv)


# ---------------------------------------------------------------------------
# 1. HKDF-SHA256 (RFC 5869)
# ---------------------------------------------------------------------------
def gen_hkdf():
    cases = [
        {
            "name": "rfc5869_case1",
            "ikmHex": (b"\x0b" * 22).hex(),
            "saltHex": bytes.fromhex("000102030405060708090a0b0c").hex(),
            "infoHex": bytes.fromhex("f0f1f2f3f4f5f6f7f8f9").hex(),
            "length": 42,
        },
        {
            "name": "rfc5869_case2",
            "ikmHex": bytes(range(0x00, 0x50)).hex(),
            "saltHex": bytes(range(0x60, 0xB0)).hex(),
            "infoHex": bytes(range(0xB0, 0x100)).hex(),
            "length": 82,
        },
        {
            "name": "rfc5869_case3_empty_salt_info",
            "ikmHex": (b"\x0b" * 22).hex(),
            "saltHex": "",
            "infoHex": "",
            "length": 42,
        },
    ]
    for c in cases:
        salt = bytes.fromhex(c["saltHex"]) or b"\x00" * 32
        okm = HKDF(
            algorithm=hashes.SHA256(),
            length=c["length"],
            salt=salt,
            info=bytes.fromhex(c["infoHex"]),
        ).derive(bytes.fromhex(c["ikmHex"]))
        c["okmHex"] = okm.hex()
    # Sanity check case 1 against the value published in RFC 5869 section A.1.
    expected = ("3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf"
                "34007208d5b887185865")
    assert cases[0]["okmHex"] == expected, "HKDF case1 mismatch: " + cases[0]["okmHex"]
    return {"cases": cases}


# ---------------------------------------------------------------------------
# 2. ChaCha20-Poly1305 (RFC 8439 2.8.2)
# ---------------------------------------------------------------------------
def gen_aead():
    plaintext = (b"Ladies and Gentlemen of the class of '99: If I could offer you "
                 b"only one tip for the future, sunscreen would be it.")
    aad = bytes.fromhex("50515253c0c1c2c3c4c5c6c7")
    key = bytes.fromhex("808182838485868788898a8b8c8d8e8f909192939495969798999a9b9c9d9e9f")
    nonce = bytes.fromhex("070000004041424344454647")
    ct_and_tag = ChaCha20Poly1305(key).encrypt(nonce, plaintext, aad)
    cases = [{
        "name": "rfc8439_2_8_2",
        "keyHex": key.hex(),
        "nonceHex": nonce.hex(),
        "aadHex": aad.hex(),
        "plaintextHex": plaintext.hex(),
        "ciphertextAndTagHex": ct_and_tag.hex(),
        "ciphertextHex": ct_and_tag[:-16].hex(),
        "tagHex": ct_and_tag[-16:].hex(),
    }]
    # Sanity check against the tag published in RFC 8439 section 2.8.2.
    assert ct_and_tag[-16:].hex() == "1ae10b594f09e26a7e902ecbd0600691", "AEAD tag mismatch"

    # An AirChat-shaped case: AAD = msgId || senderId || recipientId
    msg_id = bytes.fromhex("00112233445566778899aabbccddeeff")
    aad2 = msg_id + ALICE_DEV + BOB_DEV
    key2 = bytes.fromhex("00" * 31 + "07")
    nonce2 = bytes.fromhex("000102030405060708090a0b")
    pt2 = "\u4f60\u597d\uff0c\u4e16\u754c".encode("utf-8")   # 你好，世界
    out2 = ChaCha20Poly1305(key2).encrypt(nonce2, pt2, aad2)
    cases.append({
        "name": "airchat_private_msg",
        "keyHex": key2.hex(),
        "nonceHex": nonce2.hex(),
        "aadHex": aad2.hex(),
        "plaintextHex": pt2.hex(),
        "ciphertextAndTagHex": out2.hex(),
        "ciphertextHex": out2[:-16].hex(),
        "tagHex": out2[-16:].hex(),
    })
    return {"cases": cases}


# ---------------------------------------------------------------------------
# 3. P-256 ECDH
# ---------------------------------------------------------------------------
def gen_ecdh(pub_a, pub_b):
    return {
        "alice": {"privateKeyHex": ALICE_PRIV.hex(), "publicKeyHex": pub_a.hex()},
        "bob": {"privateKeyHex": BOB_PRIV.hex(), "publicKeyHex": pub_b.hex()},
        "curve": "secp256r1",
        "sharedSecretHex": None,  # filled below
    }


def gen_ecdh_full(a_priv, b_priv, pub_a, pub_b):
    peer_b = ec.EllipticCurvePublicKey.from_encoded_point(ec.SECP256R1(), pub_b)
    peer_a = ec.EllipticCurvePublicKey.from_encoded_point(ec.SECP256R1(), pub_a)
    s_ab = a_priv.exchange(ec.ECDH(), peer_b)
    s_ba = b_priv.exchange(ec.ECDH(), peer_a)
    assert s_ab == s_ba, "ECDH must be symmetric"
    return {
        "curve": "secp256r1",
        "alice": {"privateKeyHex": ALICE_PRIV.hex(), "publicKeyHex": pub_a.hex()},
        "bob": {"privateKeyHex": BOB_PRIV.hex(), "publicKeyHex": pub_b.hex()},
        "sharedSecretHex": s_ab.hex(),
    }


# ---------------------------------------------------------------------------
# 4. AirChat session key + safety number
# ---------------------------------------------------------------------------
def gen_session(a_priv, b_priv, pub_a, pub_b):
    key_from_a = session_key(a_priv, pub_b, ALICE_DEV, BOB_DEV, pub_a, pub_b)
    key_from_b = session_key(b_priv, pub_a, ALICE_DEV, BOB_DEV, pub_a, pub_b)
    assert key_from_a == key_from_b, "session key must be symmetric"
    first_dev, second_dev = sorted_pair(ALICE_DEV, BOB_DEV)
    salt = hashlib.sha256(HKDF_SALT_LABEL).digest()
    return {
        "aliceDeviceIdHex": ALICE_DEV.hex(),
        "bobDeviceIdHex": BOB_DEV.hex(),
        "alicePublicKeyHex": pub_a.hex(),
        "bobPublicKeyHex": pub_b.hex(),
        "aliceNicknameHex": ALICE_NAME.hex(),
        "bobNicknameHex": BOB_NAME.hex(),
        "sortedFirstDeviceIdHex": first_dev.hex(),
        "sortedSecondDeviceIdHex": second_dev.hex(),
        "hkdfSaltLabelHex": HKDF_SALT_LABEL.hex(),
        "hkdfSaltHex": salt.hex(),
        "hkdfInfoPrefixHex": SESSION_KEY_PREFIX.hex(),
        "expectedSessionKeyHex": key_from_a.hex(),
        "expectedSharedSecretHex": a_priv.exchange(
            ec.ECDH(), ec.EllipticCurvePublicKey.from_encoded_point(ec.SECP256R1(), pub_b)
        ).hex(),
    }


def gen_safety():
    return {
        "aliceDeviceIdHex": ALICE_DEV.hex(),
        "bobDeviceIdHex": BOB_DEV.hex(),
        "alicePublicKeyHex": pub_raw(
            ec.derive_private_key(int.from_bytes(ALICE_PRIV, "big"), ec.SECP256R1())
        ).hex(),
        "bobPublicKeyHex": pub_raw(
            ec.derive_private_key(int.from_bytes(BOB_PRIV, "big"), ec.SECP256R1())
        ).hex(),
        "initiatorDeviceIdHex": BOB_DEV.hex(),
        "responderDeviceIdHex": ALICE_DEV.hex(),
        "initiatorHelloNonceHex": INITIATOR_NONCE.hex(),
        "responderHelloNonceHex": RESPONDER_NONCE.hex(),
        "transcriptPrefixHex": SAFETY_PREFIX.hex(),
        "expectedCode": safety_number(
            ALICE_DEV, BOB_DEV,
            pub_raw(ec.derive_private_key(int.from_bytes(ALICE_PRIV, "big"), ec.SECP256R1())),
            pub_raw(ec.derive_private_key(int.from_bytes(BOB_PRIV, "big"), ec.SECP256R1())),
            INITIATOR_NONCE, RESPONDER_NONCE,
        ),
        "secondPair": {
            "initiatorHelloNonceHex": bytes.fromhex("0000000000000001").hex(),
            "responderHelloNonceHex": bytes.fromhex("0000000000000002").hex(),
            "expectedCode": safety_number(
                ALICE_DEV, BOB_DEV,
                pub_raw(ec.derive_private_key(int.from_bytes(ALICE_PRIV, "big"), ec.SECP256R1())),
                pub_raw(ec.derive_private_key(int.from_bytes(BOB_PRIV, "big"), ec.SECP256R1())),
                bytes.fromhex("0000000000000001"), bytes.fromhex("0000000000000002"),
            ),
        },
    }


# ---------------------------------------------------------------------------
# 5. Frame encode / decode + stream reassembly
# ---------------------------------------------------------------------------
def hello_payload(dev: bytes, name: bytes, pub: bytes, caps: int, nonce: bytes) -> bytes:
    assert len(name) <= MAX_NICKNAME_BYTES
    return (
        struct.pack(">H", PROTOCOL_VERSION)
        + dev
        + bytes([len(name)]) + name
        + pub
        + bytes([caps])
        + nonce
    )


def channel_post_payload(msg_id, ts, sender, nick: bytes, text: bytes) -> bytes:
    return (
        msg_id
        + struct.pack(">q", ts)
        + sender
        + bytes([len(nick)]) + nick
        + struct.pack(">H", len(text)) + text
    )


def private_msg_payload(msg_id, ts, sender, recipient, nonce, ciphertext) -> bytes:
    return (
        msg_id
        + struct.pack(">q", ts)
        + sender + recipient
        + nonce
        + struct.pack(">H", len(ciphertext)) + ciphertext
    )


def chunk_stream(frames_hex, chunk_size):
    stream = b"".join(bytes.fromhex(f) for f in frames_hex)
    return [stream[i:i + chunk_size].hex() for i in range(0, len(stream), chunk_size)] or [""]


def gen_frames(pub_a, pub_b):
    a_hello = hello_payload(ALICE_DEV, ALICE_NAME, pub_a, CAP_PRIVATE | CAP_SYNC, RESPONDER_NONCE)
    b_hello = hello_payload(BOB_DEV, BOB_NAME, pub_b, CAP_PRIVATE | CAP_SYNC, INITIATOR_NONCE)

    post_text = "\u665a\u4e0a\u597d\uff0c\u4eca\u5929\u6c14\u6e29 26\u00b0C \U0001F44D".encode(
        "utf-8")
    post = channel_post_payload(
        bytes.fromhex("11111111222233334444555566667777"),
        1758000000123,
        ALICE_DEV,
        ALICE_NAME,
        post_text,
    )
    msg_id = bytes.fromhex("00112233445566778899aabbccddeeff")
    key2 = bytes.fromhex("00" * 31 + "07")
    nonce2 = bytes.fromhex("000102030405060708090a0b")
    aad2 = msg_id + ALICE_DEV + BOB_DEV
    pt2 = "\u4f60\u597d\uff0c\u4e16\u754c".encode("utf-8")
    ct2 = ChaCha20Poly1305(key2).encrypt(nonce2, pt2, aad2)
    pmsg = private_msg_payload(msg_id, 1758000000999, ALICE_DEV, BOB_DEV, nonce2, ct2)
    ack = bytes.fromhex("00112233445566778899aabbccddeeff") + bytes([0])
    typing = bytes([1, 1]) + BOB_DEV
    sync_req = ALICE_DEV + struct.pack(">HH", 10, 50)

    encodes = [
        {"name": "hello_alice", "type": TYPE_HELLO, "payloadHex": a_hello.hex(),
         "frameHex": frame_hex(TYPE_HELLO, a_hello), "expectedPayloadLength": len(a_hello)},
        {"name": "hello_ack_bob", "type": TYPE_HELLO_ACK, "payloadHex": b_hello.hex(),
         "frameHex": frame_hex(TYPE_HELLO_ACK, b_hello), "expectedPayloadLength": len(b_hello)},
        {"name": "channel_post", "type": TYPE_CHANNEL_POST, "payloadHex": post.hex(),
         "frameHex": frame_hex(TYPE_CHANNEL_POST, post), "expectedPayloadLength": len(post)},
        {"name": "private_msg", "type": TYPE_PRIVATE_MSG, "payloadHex": pmsg.hex(),
         "frameHex": frame_hex(TYPE_PRIVATE_MSG, pmsg), "expectedPayloadLength": len(pmsg)},
        {"name": "delivery_ack", "type": TYPE_DELIVERY_ACK, "payloadHex": ack.hex(),
         "frameHex": frame_hex(TYPE_DELIVERY_ACK, ack), "expectedPayloadLength": len(ack)},
        {"name": "typing", "type": TYPE_TYPING, "payloadHex": typing.hex(),
         "frameHex": frame_hex(TYPE_TYPING, typing), "expectedPayloadLength": len(typing)},
        {"name": "sync_req", "type": TYPE_SYNC_REQ, "payloadHex": sync_req.hex(),
         "frameHex": frame_hex(TYPE_SYNC_REQ, sync_req), "expectedPayloadLength": len(sync_req)},
        {"name": "ping", "type": TYPE_PING, "payloadHex": "",
         "frameHex": frame_hex(TYPE_PING, b""), "expectedPayloadLength": 0},
        {"name": "pong", "type": TYPE_PONG, "payloadHex": "",
         "frameHex": frame_hex(TYPE_PONG, b""), "expectedPayloadLength": 0},
        {"name": "key_verify_req", "type": TYPE_KEY_VERIFY_REQ, "payloadHex": "",
         "frameHex": frame_hex(TYPE_KEY_VERIFY_REQ, b""), "expectedPayloadLength": 0},
        {"name": "key_verify_resp", "type": TYPE_KEY_VERIFY_RESP, "payloadHex": "01",
         "frameHex": frame_hex(TYPE_KEY_VERIFY_RESP, bytes([1])), "expectedPayloadLength": 1},
    ]

    hello_frame = frame_hex(TYPE_HELLO, a_hello)
    post_frame = frame_hex(TYPE_CHANNEL_POST, post)
    unknown_frame = frame_hex(0x55, b"\xde\xad\xbe\xef")
    big_payload = bytes(range(256)) * 5          # 1280 bytes
    big_frame = frame_hex(TYPE_CHANNEL_POST, big_payload)

    stream_cases = [
        {
            "name": "single_frame_one_chunk",
            "chunkSize": 514,
            "inputChunksHex": chunk_stream([hello_frame], 514),
            "expectedFrames": [{"type": TYPE_HELLO, "payloadHex": a_hello.hex()}],
            "expectedFatal": False,
        },
        {
            "name": "two_frames_sticky_one_chunk",
            "chunkSize": 514,
            "inputChunksHex": chunk_stream([hello_frame, post_frame], 514),
            "expectedFrames": [
                {"type": TYPE_HELLO, "payloadHex": a_hello.hex()},
                {"type": TYPE_CHANNEL_POST, "payloadHex": post.hex()},
            ],
            "expectedFatal": False,
        },
        {
            "name": "hello_split_at_mtu_20",
            "chunkSize": 20,
            "inputChunksHex": chunk_stream([hello_frame], 20),
            "expectedFrames": [{"type": TYPE_HELLO, "payloadHex": a_hello.hex()}],
            "expectedFatal": False,
        },
        {
            "name": "multi_frame_split_at_mtu_185",
            "chunkSize": 182,
            "inputChunksHex": chunk_stream([hello_frame, post_frame, hello_frame], 182),
            "expectedFrames": [
                {"type": TYPE_HELLO, "payloadHex": a_hello.hex()},
                {"type": TYPE_CHANNEL_POST, "payloadHex": post.hex()},
                {"type": TYPE_HELLO, "payloadHex": a_hello.hex()},
            ],
            "expectedFatal": False,
        },
        {
            "name": "large_frame_split_at_mtu_517",
            "chunkSize": min(517 - 3, MAX_CHUNK_BYTES),
            "inputChunksHex": chunk_stream([big_frame], min(517 - 3, MAX_CHUNK_BYTES)),
            "expectedFrames": [{"type": TYPE_CHANNEL_POST, "payloadHex": big_payload.hex()}],
            "expectedFatal": False,
        },
        {
            "name": "byte_by_byte_20",
            "chunkSize": 1,
            "inputChunksHex": chunk_stream([post_frame], 1)[:40],
            "expectedFrames": [],
            "expectedFatal": False,
            "note": "partial stream must not emit a frame and must not error",
        },
        {
            "name": "sticky_across_three_chunks_25",
            "chunkSize": 25,
            "inputChunksHex": chunk_stream([post_frame, unknown_frame, ack_frame_hex()], 25),
            "expectedFrames": [
                {"type": TYPE_CHANNEL_POST, "payloadHex": post.hex()},
                {"type": 0x55, "payloadHex": "deadbeef"},
                {"type": TYPE_DELIVERY_ACK, "payloadHex": ack.hex()},
            ],
            "expectedFatal": False,
            "note": "the framer surfaces unknown types and stays in sync; the session drops them",
        },
        {
            "name": "oversize_declared_length",
            "chunkSize": 514,
            "inputChunksHex": [bytes([PROTOCOL_VERSION, TYPE_CHANNEL_POST]).hex()
                               + struct.pack(">H", MAX_PAYLOAD_BYTES + 1).hex()],
            "expectedFrames": [],
            "expectedFatal": True,
        },
        {
            "name": "bad_version",
            "chunkSize": 514,
            "inputChunksHex": [bytes([2, TYPE_PING]).hex() + struct.pack(">H", 0).hex()],
            "expectedFrames": [],
            "expectedFatal": True,
        },
        {
            "name": "truncated_frame_no_emit",
            "chunkSize": 514,
            "inputChunksHex": [frame_hex(TYPE_CHANNEL_POST, post)[:-8]],
            "expectedFrames": [],
            "expectedFatal": False,
        },
    ]

    return {
        "constants": {
            "protocolVersion": PROTOCOL_VERSION,
            "maxPayloadBytes": MAX_PAYLOAD_BYTES,
            "maxChunkBytes": MAX_CHUNK_BYTES,
            "maxNicknameBytes": MAX_NICKNAME_BYTES,
            "maxTextBytes": MAX_TEXT_BYTES,
            "maxLinks": MAX_LINKS,
        },
        "channelPostTextHex": post_text.hex(),
        "encodes": encodes,
        "streamCases": stream_cases,
    }


def ack_frame_hex() -> str:
    return frame_hex(TYPE_DELIVERY_ACK,
                     bytes.fromhex("00112233445566778899aabbccddeeff") + bytes([0]))


# ---------------------------------------------------------------------------
def write(name, obj):
    os.makedirs(OUT_DIR, exist_ok=True)
    path = os.path.join(OUT_DIR, name)
    with open(path, "w", encoding="utf-8", newline="\n") as fh:
        json.dump(obj, fh, ensure_ascii=False, indent=2, sort_keys=False)
        fh.write("\n")
    print("wrote", os.path.relpath(path), os.path.getsize(path), "bytes")


def main():
    a_priv, b_priv, pub_a, pub_b = build_identities()
    print("alice pub :", pub_a.hex())
    print("bob   pub :", pub_b.hex())
    write("hkdf-sha256-rfc5869.json", gen_hkdf())
    write("chacha20poly1305-rfc8439.json", gen_aead())
    write("p256-ecdh.json", gen_ecdh_full(a_priv, b_priv, pub_a, pub_b))
    write("session-key.json", gen_session(a_priv, b_priv, pub_a, pub_b))
    write("safety-number.json", gen_safety())
    write("frames.json", gen_frames(pub_a, pub_b))
    print("done")


if __name__ == "__main__":
    main()