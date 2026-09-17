import XCTest
@testable import AirChatProtocol

/// End-to-end tests over the fake BLE transport: two (and three) real `AirChatNode` instances
/// exchanging real frames, with real crypto and real framing.
///
/// Real time is used rather than a controllable clock because the node owns a serial queue and a
/// maintenance timer; polling keeps the assertions independent of scheduling order.
final class AirChatNodeTests: XCTestCase {

    private func waitUntil(
        _ description: String,
        timeout: TimeInterval = 5,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ predicate: () -> Bool
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return }
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTFail("timed out waiting for: \(description)", file: file, line: line)
    }

    private final class Harness {
        let storeA = InMemoryChatStore()
        let storeB = InMemoryChatStore()
        let transportA = FakeTransport()
        let transportB = FakeTransport()
        let nodeA: AirChatNode
        let nodeB: AirChatNode
        var links: (FakeLink, FakeLink)?

        init() {
            nodeA = AirChatNode(store: storeA, transport: transportA)
            nodeB = AirChatNode(store: storeB, transport: transportB)
        }

        func start() {
            nodeA.start()
            nodeB.start()
        }

        func connect(mtu: Int = 185, aIsCentral: Bool = true) {
            links = FakeBle.connect(transportA, transportB, mtu: mtu, aIsCentral: aIsCentral)
        }

        func shutdown() {
            nodeA.stop()
            nodeB.stop()
        }
    }

    private func withHarness(_ body: (Harness) throws -> Void) rethrows {
        let harness = Harness()
        harness.start()
        defer { harness.shutdown() }
        try body(harness)
    }

    private func waitForReady(_ harness: Harness, file: StaticString = #filePath, line: UInt = #line) {
        waitUntil("both nodes have one ready link", file: file, line: line) {
            harness.nodeA.state.readyLinkCount == 1 && harness.nodeB.state.readyLinkCount == 1
        }
    }

    func testTwoNodesHandshakeAndExchangeAChannelMessage() throws {
        try withHarness { harness in
            harness.connect(mtu: 23) // force fragmentation across the whole pipeline
            waitForReady(harness)

            guard case .sent(let posted) = harness.nodeA.postChannelMessage("大家好，我是小明 👋") else {
                return XCTFail("expected the post to be accepted")
            }
            XCTAssertEqual(MessageDirection.outgoing, posted.direction)

            waitUntil("peer stored the channel message") { harness.storeB.messageOrder.count == 1 }
            let received = try XCTUnwrap(
                harness.storeB.listMessages(conversationId: AirChatProtocol.channelConversationId, limit: 10).first
            )
            XCTAssertEqual("大家好，我是小明 👋", received.text)
            XCTAssertEqual(MessageDirection.incoming, received.direction)
            XCTAssertEqual(MessageKind.channel, received.kind)
            XCTAssertEqual(harness.nodeA.deviceIdHex, ByteOps.toHex(received.senderId))

            // The sender stores its own copy with status sent (the channel is best effort).
            let mine = try XCTUnwrap(
                harness.storeA.listMessages(conversationId: AirChatProtocol.channelConversationId, limit: 10).first
            )
            XCTAssertEqual(MessageStatus.sent, mine.status)
            XCTAssertEqual(MessageDirection.outgoing, mine.direction)
        }
    }

    func testAReplayedChannelPostIsStoredOnlyOnce() throws {
        try withHarness { harness in
            harness.connect()
            waitForReady(harness)
            harness.nodeA.postChannelMessage("一次性")
            waitUntil("peer stored the message") { harness.storeB.messageOrder.count == 1 }

            let stored = try XCTUnwrap(
                harness.storeB.listMessages(conversationId: AirChatProtocol.channelConversationId, limit: 10).first
            )
            let replay = try MessageCodec.encodeChannelPost(
                try ChannelPost(
                    msgId: stored.msgId,
                    timestampMillis: stored.timestampMs,
                    senderId: ByteOps.fromHex(harness.nodeA.deviceIdHex),
                    senderNickname: "小明",
                    text: "一次性"
                )
            )
            harness.links?.1.inject(FrameCodec.encode(type: FrameType.channelPost, payload: try XCTUnwrap(replay)))
            Thread.sleep(forTimeInterval: 0.2)

            XCTAssertEqual(1, harness.storeB.messageOrder.count, "replay must be deduped by msgId")
            XCTAssertEqual(2, harness.storeB.insertCalls)
        }
    }

    func testPrivateMessagesAreEncryptedEndToEndAndAcknowledged() throws {
        try withHarness { harness in
            harness.connect()
            waitForReady(harness)

            let result = harness.nodeA.sendPrivateMessage(peerIdHex: harness.nodeB.deviceIdHex, text: "只有你能看到")
            guard case .sent(let record) = result else {
                return XCTFail("expected the private message to be accepted, got \(result)")
            }

            waitUntil("peer stored the private message") { harness.storeB.messageOrder.count == 1 }
            let received = try XCTUnwrap(
                harness.storeB.listMessages(conversationId: harness.nodeA.deviceIdHex, limit: 10).first
            )
            XCTAssertEqual("只有你能看到", received.text)
            XCTAssertEqual(MessageKind.`private`, received.kind)
            XCTAssertEqual(MessageDirection.incoming, received.direction)

            // The delivery ACK upgrades the sender's copy from sent to delivered (double check).
            waitUntil("sender saw the delivery ack") {
                (try? harness.storeA.getMessage(record.msgId))?.status == MessageStatus.delivered
            }
        }
    }

    func testPrivateMessagesToAnUnknownPeerAreRejected() throws {
        withHarness { harness in
            harness.connect()
            waitForReady(harness)
            let result = harness.nodeA.sendPrivateMessage(
                peerIdHex: ByteOps.toHex(AirChatCrypto.randomDeviceId()),
                text: "hi"
            )
            guard case .rejected(let reason) = result else { return XCTFail("expected a rejection") }
            XCTAssertFalse(reason.isEmpty)
        }
    }

    func testConfirmingTheSafetyCodeIsStoredLocallyAndReportedToThePeer() throws {
        withHarness { harness in
            harness.connect()
            waitForReady(harness)

            let codeA = harness.nodeA.state.links.first?.safetyCode
            let codeB = harness.nodeB.state.links.first?.safetyCode
            XCTAssertNotNil(codeA)
            XCTAssertEqual(codeA, codeB, "both users must see the same code")

            harness.nodeB.confirmSafetyCode(peerIdHex: harness.nodeA.deviceIdHex, accepted: true)
            waitUntil("B persisted trusted") {
                (try? harness.storeB.getPeer(ByteOps.fromHex(harness.nodeA.deviceIdHex)))?.trustState == TrustState.trusted
            }
            waitUntil("A learned that B confirmed") {
                harness.nodeA.state.links.first?.peerConfirmedTheCode == true
            }
            // Confirming on B must never auto-trust A's own record: trust is local and per-device.
            XCTAssertEqual(
                TrustState.unverified,
                (try? harness.storeA.getPeer(ByteOps.fromHex(harness.nodeB.deviceIdHex)))?.trustState ?? -1
            )
        }
    }

    func testARejectedSafetyCodeBlocksOutboundPrivateMessages() throws {
        withHarness { harness in
            harness.connect()
            waitForReady(harness)

            harness.nodeA.confirmSafetyCode(peerIdHex: harness.nodeB.deviceIdHex, accepted: false)
            waitUntil("A persisted rejected") {
                (try? harness.storeA.getPeer(ByteOps.fromHex(harness.nodeB.deviceIdHex)))?.trustState == TrustState.rejected
            }
            let result = harness.nodeA.sendPrivateMessage(peerIdHex: harness.nodeB.deviceIdHex, text: "nope")
            guard case .rejected(let reason) = result else { return XCTFail("expected a rejection") }
            XCTAssertTrue(reason.contains("安全码"))
        }
    }

    func testDuplicateLinksAreDedupedDeterministicallyOnBothSides() throws {
        try withHarness { harness in
            // Two connections at once: both nodes must converge on exactly one surviving link.
            harness.connect(aIsCentral: true)
            harness.connect(aIsCentral: false)

            waitUntil("both sides settle on a single link") {
                harness.nodeA.state.linkCount == 1 && harness.nodeB.state.linkCount == 1
            }

            let aId = ByteOps.fromHex(harness.nodeA.deviceIdHex)
            let bId = ByteOps.fromHex(harness.nodeB.deviceIdHex)
            let aIsSmaller = ByteOps.compareUnsigned(aId, bId) < 0

            // Rule 5.4: the survivor is the link whose central owns the smaller deviceId, so the two
            // nodes must report exactly mirrored roles for that same link.
            let linkA = try XCTUnwrap(harness.nodeA.state.links.first)
            let linkB = try XCTUnwrap(harness.nodeB.state.links.first)
            XCTAssertEqual(aIsSmaller, linkA.isCentral)
            XCTAssertEqual(!aIsSmaller, linkB.isCentral)
        }
    }

    func testChannelMessagesFanOutToEveryReadyLink() throws {
        let storeA = InMemoryChatStore()
        let storeB = InMemoryChatStore()
        let storeC = InMemoryChatStore()
        let transportA = FakeTransport()
        let transportB = FakeTransport()
        let transportC = FakeTransport()
        let nodeA = AirChatNode(store: storeA, transport: transportA)
        let nodeB = AirChatNode(store: storeB, transport: transportB)
        let nodeC = AirChatNode(store: storeC, transport: transportC)
        defer {
            nodeA.stop(); nodeB.stop(); nodeC.stop()
        }

        nodeA.start(); nodeB.start(); nodeC.start()
        FakeBle.connect(transportA, transportB, aIsCentral: true, labelPrefix: "ab")
        FakeBle.connect(transportA, transportC, aIsCentral: false, labelPrefix: "ac")
        waitUntil("A has two ready links") { nodeA.state.readyLinkCount == 2 }

        nodeA.postChannelMessage("广播给所有人")
        waitUntil("both peers received the broadcast") {
            storeB.messageOrder.count == 1 && storeC.messageOrder.count == 1
        }
        XCTAssertEqual(
            "广播给所有人",
            try storeB.listMessages(conversationId: AirChatProtocol.channelConversationId, limit: 5).first?.text ?? ""
        )
        XCTAssertEqual(
            "广播给所有人",
            try storeC.listMessages(conversationId: AirChatProtocol.channelConversationId, limit: 5).first?.text ?? ""
        )
        // A's own copy is stored once, not once per link.
        XCTAssertEqual(1, storeA.messageOrder.count)
    }

    func testANewlyConnectedPeerBackfillsChannelHistoryViaSync() throws {
        let storeA = InMemoryChatStore()
        let storeB = InMemoryChatStore()
        let transportA = FakeTransport()
        let transportB = FakeTransport()
        let nodeA = AirChatNode(store: storeA, transport: transportA)
        let nodeB = AirChatNode(store: storeB, transport: transportB)
        defer {
            nodeA.stop(); nodeB.stop()
        }

        nodeA.start(); nodeB.start()
        // A posts while alone: stored locally, marked failed because nothing was reachable.
        nodeA.postChannelMessage("离线时写的 1")
        nodeA.postChannelMessage("离线时写的 2")
        waitUntil("A stored both messages") { storeA.messageOrder.count == 2 }

        FakeBle.connect(transportA, transportB)
        waitUntil("B backfilled the history") { storeB.messageOrder.count == 2 }

        let texts = try storeB
            .listMessages(conversationId: AirChatProtocol.channelConversationId, limit: 10)
            .map { $0.text }
        XCTAssertEqual(["离线时写的 1", "离线时写的 2"], texts)
    }

    func testEmptyAndOversizedChannelMessagesAreRejected() throws {
        withHarness { harness in
            harness.connect()
            waitForReady(harness)

            guard case .rejected(let blankReason) = harness.nodeA.postChannelMessage("   ") else {
                return XCTFail("blank message must be rejected")
            }
            XCTAssertFalse(blankReason.isEmpty)

            guard case .rejected(let longReason) = harness.nodeA.postChannelMessage(
                String(repeating: "x", count: AirChatProtocol.maxTextChars + 1)
            ) else {
                return XCTFail("oversized message must be rejected")
            }
            XCTAssertFalse(longReason.isEmpty)
            XCTAssertEqual(0, harness.storeA.messageOrder.count)
        }
    }

    func testNicknameChangesArePersistedAndAdvertisedInLaterPosts() throws {
        try withHarness { harness in
            harness.connect()
            waitForReady(harness)

            harness.nodeA.setNickname("阿明")
            waitUntil("nickname is published") { harness.nodeA.state.nickname == "阿明" }
            XCTAssertEqual("阿明", try harness.storeA.loadIdentity()?.nickname)

            harness.nodeA.postChannelMessage("换了昵称")
            waitUntil("peer received it") { harness.storeB.messageOrder.count == 1 }
            XCTAssertEqual(
                "阿明",
                try harness.storeB.getPeer(ByteOps.fromHex(harness.nodeA.deviceIdHex))?.nickname ?? ""
            )
        }
    }

    func testADisconnectRemovesTheLinkAndTheNodeKeepsRunning() throws {
        withHarness { harness in
            harness.connect()
            waitForReady(harness)
            harness.links?.0.close()

            waitUntil("both sides dropped the link") {
                harness.nodeA.state.linkCount == 0 && harness.nodeB.state.linkCount == 0
            }

            // Transport-owned status is surfaced verbatim so the UI can explain the situation.
            harness.transportA.reportStatus(.nearbyFull, "附近人数已满")
            waitUntil("status propagates to the node state") {
                harness.nodeA.state.status == .nearbyFull
            }
            XCTAssertEqual("附近人数已满", harness.nodeA.state.statusMessage)

            // The node must still accept local writes after the link disappears.
            guard case .sent(let record) = harness.nodeA.postChannelMessage("断线后仍可本地记录") else {
                return XCTFail("expected a local write to be accepted")
            }
            XCTAssertEqual(MessageStatus.failed, record.status)
        }
    }

    func testIdentityIsGeneratedOnceAndReusedAcrossRestarts() throws {
        let store = InMemoryChatStore()
        let first = AirChatNode(store: store, transport: FakeTransport())
        first.start()
        let firstId = first.deviceIdHex
        XCTAssertFalse(firstId.isEmpty)
        let publicKey = try XCTUnwrap(store.loadIdentity()).publicKey
        first.stop()

        let second = AirChatNode(store: store, transport: FakeTransport())
        second.start()
        defer { second.stop() }
        XCTAssertEqual(firstId, second.deviceIdHex, "identity must be stable across restarts")
        XCTAssertEqual(publicKey, try store.loadIdentity()?.publicKey ?? Data())
    }
}
