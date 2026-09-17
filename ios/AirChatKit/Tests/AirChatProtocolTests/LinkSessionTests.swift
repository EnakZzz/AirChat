import XCTest
@testable import AirChatProtocol

/// Records everything a `LinkSession` reports.
final class RecordingSessionListener: LinkSessionListener {
    private(set) var readyPeers: [(String, String)] = []
    private(set) var channelPosts: [ChannelPost] = []
    private(set) var privateMessages: [ReceivedPrivateMessage] = []
    private(set) var acks: [DeliveryAck] = []
    private(set) var typing: [Typing] = []
    private(set) var syncRequests: [SyncRequest] = []
    private(set) var syncResponses: [SyncResponse] = []
    private(set) var keyVerifyRequests = 0
    private(set) var keyVerifyResponses: [Bool] = []
    private(set) var failures: [String] = []

    func onReady(session: LinkSession, peer: Hello) {
        readyPeers.append((peer.deviceIdHex, session.safetyCode ?? ""))
    }

    func onChannelPost(session: LinkSession, post: ChannelPost) { channelPosts.append(post) }
    func onPrivateMessage(session: LinkSession, received: ReceivedPrivateMessage) {
        privateMessages.append(received)
    }
    func onDeliveryAck(session: LinkSession, ack: DeliveryAck) { acks.append(ack) }
    func onTyping(session: LinkSession, typing: Typing) { self.typing.append(typing) }
    func onSyncRequest(session: LinkSession, request: SyncRequest) { syncRequests.append(request) }
    func onSyncResponse(session: LinkSession, response: SyncResponse) { syncResponses.append(response) }
    func onKeyVerifyRequest(session: LinkSession) { keyVerifyRequests += 1 }
    func onKeyVerifyResponse(session: LinkSession, accepted: Bool) { keyVerifyResponses.append(accepted) }
    func onFailed(session: LinkSession, reason: String) { failures.append(reason) }
}

/// Wires two `LinkSession`s back to back over a `FakeLink` pair.
final class SessionPair {
    let identityA: LocalIdentity
    let identityB: LocalIdentity
    let linkA: FakeLink
    let linkB: FakeLink
    let listenerA: RecordingSessionListener
    let listenerB: RecordingSessionListener
    let sessionA: LinkSession
    let sessionB: LinkSession

    init(mtu: Int = 185, aIsCentral: Bool = true, nicknameA: String = "小明", nicknameB: String = "Bob") {
        // Build every object in locals first: a designated initialiser may not touch `self` until
        // all stored properties are assigned.
        let identityA = LocalIdentity.generate()
        let identityB = LocalIdentity.generate()
        let listenerA = RecordingSessionListener()
        let listenerB = RecordingSessionListener()
        let linkA = FakeLink(linkId: "link-a", isCentral: aIsCentral, mtu: mtu, peerLabel: "peer-b")
        let linkB = FakeLink(linkId: "link-b", isCentral: !aIsCentral, mtu: mtu, peerLabel: "peer-a")
        let sessionA = LinkSession(
            link: linkA,
            localIdentity: identityA,
            nicknameProvider: { nicknameA },
            capabilities: Capabilities.all,
            listener: listenerA
        )
        let sessionB = LinkSession(
            link: linkB,
            localIdentity: identityB,
            nicknameProvider: { nicknameB },
            capabilities: Capabilities.all,
            listener: listenerB
        )
        linkA.peer = linkB
        linkB.peer = linkA

        self.identityA = identityA
        self.identityB = identityB
        self.listenerA = listenerA
        self.listenerB = listenerB
        self.linkA = linkA
        self.linkB = linkB
        self.sessionA = sessionA
        self.sessionB = sessionB

        // Weak captures, so the handlers hold neither the pair nor a retain cycle on the sessions.
        linkA.setInboundHandler { [weak sessionA] bytes in sessionA?.onBytes(bytes) }
        linkB.setInboundHandler { [weak sessionB] bytes in sessionB?.onBytes(bytes) }
    }

    /// Starts the handshake from the initiator, which the protocol defines as the GATT central.
    /// Delivery is synchronous, so both sides are READY when this returns.
    func shakeHands() {
        if sessionA.isInitiator {
            sessionA.start()
        } else {
            sessionB.start()
        }
    }
}

final class LinkSessionTests: XCTestCase {

    func testHandshakeReachesReadyOnBothSidesWithMtu23Fragmentation() {
        // MTU 23 gives 20-byte chunks, so the HELLO frame is split across many writes.
        let pair = SessionPair(mtu: 23)
        pair.shakeHands()

        XCTAssertEqual(SessionState.ready, pair.sessionA.state)
        XCTAssertEqual(SessionState.ready, pair.sessionB.state)
        XCTAssertGreaterThan(pair.linkA.sentChunks.count, 1, "HELLO must have been fragmented")
        XCTAssertTrue(pair.linkA.sentChunks.allSatisfy { $0.bytes.count <= 20 }, "chunks must respect the MTU")
        XCTAssertEqual(FrameType.hello, pair.linkA.framesSentToPeer().first?.type ?? -1)
    }

    func testBothSidesDeriveTheSameSessionKeyAndSafetyNumber() {
        let pair = SessionPair()
        pair.shakeHands()

        let keyA = pair.sessionA.sessionKey
        let keyB = pair.sessionB.sessionKey
        XCTAssertNotNil(keyA)
        XCTAssertEqual(keyA, keyB)
        XCTAssertEqual(pair.sessionA.safetyCode, pair.sessionB.safetyCode)

        let code = pair.sessionA.safetyCode ?? ""
        XCTAssertEqual(6, code.count)
        XCTAssertTrue(code.allSatisfy { $0.isNumber })

        // Both listeners must have observed the same peer ids.
        XCTAssertEqual(pair.identityB.deviceIdHex, pair.listenerA.readyPeers.first?.0)
        XCTAssertEqual(pair.identityA.deviceIdHex, pair.listenerB.readyPeers.first?.0)
    }

    func testHandshakeWorksWithEitherSideActingAsTheGattCentral() {
        let pair = SessionPair(aIsCentral: false)
        pair.shakeHands()

        XCTAssertEqual(SessionState.ready, pair.sessionA.state)
        XCTAssertEqual(SessionState.ready, pair.sessionB.state)
        XCTAssertEqual(pair.sessionA.sessionKey, pair.sessionB.sessionKey)
        XCTAssertEqual(pair.sessionA.safetyCode, pair.sessionB.safetyCode)
        XCTAssertEqual(FrameType.hello, pair.linkB.framesSentToPeer().first?.type ?? -1)
    }

    func testAPeripheralStartIsANoOpUntilThePeerSpeaks() {
        let pair = SessionPair(aIsCentral: false)
        pair.sessionA.start()

        XCTAssertEqual(SessionState.handshaking, pair.sessionA.state)
        XCTAssertTrue(pair.linkA.sentChunks.isEmpty, "a peripheral must not send anything first")

        pair.sessionB.start()
        XCTAssertEqual(SessionState.ready, pair.sessionA.state)
        XCTAssertEqual(SessionState.ready, pair.sessionB.state)
    }

    func testADifferentPeerYieldsADifferentSessionKeyAndSafetyNumber() {
        let first = SessionPair()
        first.shakeHands()
        let second = SessionPair()
        second.shakeHands()

        XCTAssertNotEqual(first.sessionA.sessionKey, second.sessionA.sessionKey)
        XCTAssertNotEqual(first.sessionA.safetyCode, second.sessionA.safetyCode)
    }

    func testChannelPostsTravelWithTheRealSenderAndNickname() throws {
        let pair = SessionPair()
        pair.shakeHands()

        let post = try ChannelPost(
            msgId: AirChatCrypto.randomMessageId(),
            timestampMillis: 1_758_000_000_000,
            senderId: pair.identityA.deviceId,
            senderNickname: "小明",
            text: "大家好 👋"
        )
        XCTAssertTrue(pair.sessionA.sendChannelPost(post))

        let received = try XCTUnwrap(pair.listenerB.channelPosts.first)
        XCTAssertEqual("大家好 👋", received.text)
        XCTAssertEqual("小明", received.senderNickname)
        XCTAssertEqual(pair.identityA.deviceId, received.senderId)
    }

    func testChannelPostsWithASpoofedSenderIdAreDropped() throws {
        let pair = SessionPair()
        pair.shakeHands()

        let forged = try MessageCodec.encodeChannelPost(
            ChannelPost(
                msgId: AirChatCrypto.randomMessageId(),
                timestampMillis: 1,
                senderId: AirChatCrypto.randomDeviceId(),
                senderNickname: "impostor",
                text: "I am someone else"
            )
        )
        pair.linkB.inject(FrameCodec.encode(type: FrameType.channelPost, payload: try XCTUnwrap(forged)))

        XCTAssertTrue(pair.listenerB.channelPosts.isEmpty, "spoofed post must be dropped")
        XCTAssertEqual(SessionState.ready, pair.sessionB.state, "the link must stay usable")
    }

    func testPrivateMessagesRoundTripAndAreBoundToIdsAndAad() throws {
        let pair = SessionPair()
        pair.shakeHands()

        let msgId = AirChatCrypto.randomMessageId()
        let sent = pair.sessionA.sendPrivateMessage(
            msgId: msgId,
            timestampMillis: 42,
            recipientId: pair.identityB.deviceId,
            plaintext: "只有你能看到 🔒"
        )
        XCTAssertNotNil(sent)

        let received = try XCTUnwrap(pair.listenerB.privateMessages.first)
        XCTAssertTrue(received.decrypted)
        XCTAssertEqual("只有你能看到 🔒", received.plaintext)
        XCTAssertEqual(msgId, received.message.msgId)
        XCTAssertFalse(
            String(decoding: received.message.ciphertext, as: UTF8.self).contains("只有你"),
            "ciphertext must not contain the plaintext"
        )

        // AAD binds the ciphertext to the header fields: changing the recipient must break it.
        let tampered = try MessageCodec.encodePrivateMessage(
            PrivateMessage(
                msgId: received.message.msgId,
                timestampMillis: received.message.timestampMillis,
                senderId: received.message.senderId,
                recipientId: received.message.senderId,
                nonce: received.message.nonce,
                ciphertext: received.message.ciphertext
            )
        )
        let listener = RecordingSessionListener()
        let probe = LinkSession(
            link: FakeLink(linkId: "probe", isCentral: true),
            localIdentity: pair.identityB,
            nicknameProvider: { "probe" },
            capabilities: Capabilities.all,
            listener: listener
        )
        probe.onBytes(FrameCodec.encode(type: FrameType.privateMsg, payload: try XCTUnwrap(tampered)))
        XCTAssertTrue(listener.privateMessages.isEmpty, "a message addressed elsewhere must be dropped")
    }

    func testAnUndecryptablePrivateMessageIsSurfacedAsSuch() throws {
        let pair = SessionPair()
        pair.shakeHands()

        let corrupted = try MessageCodec.encodePrivateMessage(
            PrivateMessage(
                msgId: AirChatCrypto.randomMessageId(),
                timestampMillis: 1,
                senderId: pair.identityA.deviceId,
                recipientId: pair.identityB.deviceId,
                nonce: AirChatCrypto.randomNonce(),
                ciphertext: Data(repeating: 0x5A, count: 32)
            )
        )
        pair.linkB.inject(FrameCodec.encode(type: FrameType.privateMsg, payload: try XCTUnwrap(corrupted)))

        let received = try XCTUnwrap(pair.listenerB.privateMessages.first)
        XCTAssertFalse(received.decrypted)
        XCTAssertNil(received.plaintext)
    }

    func testUnknownFrameTypesAreIgnoredWithoutDisturbingTheLink() throws {
        let pair = SessionPair()
        pair.shakeHands()

        pair.linkB.inject(FrameCodec.encode(type: 0x66, payload: Data(repeating: 0x11, count: 64)))
        XCTAssertEqual(SessionState.ready, pair.sessionB.state)
        XCTAssertTrue(pair.listenerB.failures.isEmpty)

        XCTAssertTrue(
            pair.sessionA.sendChannelPost(
                try ChannelPost(
                    msgId: AirChatCrypto.randomMessageId(),
                    timestampMillis: 5,
                    senderId: pair.identityA.deviceId,
                    senderNickname: "小明",
                    text: "after"
                )
            )
        )
        XCTAssertEqual("after", pair.listenerB.channelPosts.first?.text ?? "")
    }

    func testSyncResponseEntriesFromThirdPartiesAreFilteredOut() throws {
        let pair = SessionPair()
        pair.shakeHands()

        // sessionA's peer is B, so only posts attributed to B may be relayed to A.
        let forged = MessageCodec.encodeSyncResponse(
            SyncResponse(posts: [
                try ChannelPost(
                    msgId: AirChatCrypto.randomMessageId(),
                    timestampMillis: 1,
                    senderId: pair.identityB.deviceId,
                    senderNickname: "Bob",
                    text: "legit"
                ),
                try ChannelPost(
                    msgId: AirChatCrypto.randomMessageId(),
                    timestampMillis: 2,
                    senderId: AirChatCrypto.randomDeviceId(),
                    senderNickname: "ghost",
                    text: "forged"
                ),
            ])
        )
        pair.linkA.inject(FrameCodec.encode(type: FrameType.syncResp, payload: forged))

        let response = try XCTUnwrap(pair.listenerA.syncResponses.first)
        XCTAssertEqual(1, response.posts.count, "only the peer's own posts may be relayed")
        XCTAssertEqual("legit", response.posts.first?.text ?? "")
    }

    func testKeyVerificationIsExchangedButNeverAutoTrusts() {
        let pair = SessionPair()
        pair.shakeHands()

        XCTAssertTrue(pair.sessionA.sendKeyVerifyRequest())
        XCTAssertEqual(1, pair.listenerB.keyVerifyRequests)
        // The responder answers with its own local state, which defaults to unverified.
        XCTAssertEqual([false], pair.listenerA.keyVerifyResponses)
    }

    func testVersionMismatchFailsTheHandshake() throws {
        let pair = SessionPair()
        let foreign = try MessageCodec.encodeHello(
            Hello(
                protocolVersion: 2,
                deviceId: pair.identityB.deviceId,
                nickname: "future",
                publicKey: pair.identityB.publicKeyBytes,
                capabilities: Capabilities.all,
                helloNonce: AirChatCrypto.randomData(AirChatProtocol.helloNonceBytes)
            )
        )
        pair.linkA.inject(FrameCodec.encode(type: FrameType.hello, payload: try XCTUnwrap(foreign)))

        XCTAssertEqual(SessionState.failed, pair.sessionA.state)
        XCTAssertEqual(1, pair.listenerA.failures.count)
        XCTAssertNil(pair.sessionA.sessionKey)
    }

    func testFramingErrorTearsTheLinkDown() {
        let pair = SessionPair()
        pair.shakeHands()

        pair.linkA.inject(Data([2, UInt8(FrameType.ping), 0, 0]))
        XCTAssertEqual(SessionState.failed, pair.sessionA.state)
        XCTAssertTrue(pair.listenerA.failures.first?.contains("version") ?? false)
    }

    func testDataFramesAreRefusedBeforeReadyAndAfterFailure() throws {
        let pair = SessionPair()
        XCTAssertFalse(
            pair.sessionA.sendChannelPost(
                try ChannelPost(
                    msgId: AirChatCrypto.randomMessageId(),
                    timestampMillis: 1,
                    senderId: pair.identityA.deviceId,
                    senderNickname: "小明",
                    text: "too early"
                )
            )
        )
        XCTAssertNil(
            pair.sessionA.sendPrivateMessage(
                msgId: AirChatCrypto.randomMessageId(),
                timestampMillis: 1,
                recipientId: pair.identityB.deviceId,
                plaintext: "too early"
            )
        )

        pair.shakeHands()
        XCTAssertTrue(pair.sessionA.isReady)

        pair.linkA.inject(Data([2, UInt8(FrameType.ping), 0, 0]))
        XCTAssertFalse(
            pair.sessionA.sendChannelPost(
                try ChannelPost(
                    msgId: AirChatCrypto.randomMessageId(),
                    timestampMillis: 1,
                    senderId: pair.identityA.deviceId,
                    senderNickname: "小明",
                    text: "too late"
                )
            )
        )
    }

    func testOversizedPrivateMessagesAreRefused() {
        let pair = SessionPair()
        pair.shakeHands()
        let tooLong = String(repeating: "x", count: AirChatProtocol.maxTextBytes + 1)
        XCTAssertNil(
            pair.sessionA.sendPrivateMessage(
                msgId: AirChatCrypto.randomMessageId(),
                timestampMillis: 1,
                recipientId: pair.identityB.deviceId,
                plaintext: tooLong
            )
        )
    }

    func testPingIsAnsweredWithPong() {
        let pair = SessionPair()
        pair.shakeHands()

        XCTAssertTrue(pair.sessionA.ping())
        let types = pair.linkB.framesSentToPeer().map { $0.type }
        XCTAssertTrue(types.contains(FrameType.pong), "expected a PONG from the responder")
        XCTAssertEqual(SessionState.ready, pair.sessionA.state)
    }
}
