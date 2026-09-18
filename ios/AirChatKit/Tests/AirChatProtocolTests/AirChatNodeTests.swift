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

        func connect(
            mtu: Int = 185,
            aIsCentral: Bool = true,
            labelA: String = "peer-of-a",
            labelB: String = "peer-of-b"
        ) {
            links = FakeBle.connect(
                transportA, transportB, mtu: mtu, aIsCentral: aIsCentral, labelA: labelA, labelB: labelB
            )
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
        // Distinct milliseconds, so the assertion below holds whether the implementation orders by
        // the sender's timestamp or by the local receive time.
        Thread.sleep(forTimeInterval: 0.01)
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

    // ------------------------------------------- 附近页：点人即连、连上核对

    /// Collects node events for the duration of one test. The node notifies from its own serial
    /// queue, so the log has to be safe to append from there and read from the test thread.
    private final class EventLog {
        private let lock = NSLock()
        private var events: [NodeEvent] = []

        func append(_ event: NodeEvent) {
            lock.lock()
            defer { lock.unlock() }
            events.append(event)
        }

        /// deviceIds the node asked the user to verify, in order.
        var prompts: [String] {
            lock.lock()
            defer { lock.unlock() }
            return events.compactMap { event in
                if case .verifyRequested(let peerIdHex) = event { return peerIdHex }
                return nil
            }
        }
    }

    private func recordEvents(_ node: AirChatNode) -> EventLog {
        let log = EventLog()
        node.addEventObserver { log.append($0) }
        return log
    }

    /// Seeds an identity into a store so the tests can control which deviceId is smaller, and with
    /// it which of two duplicate links the dedupe keeps.
    private func seededStore(largerThan floor: LocalIdentity? = nil) -> (InMemoryChatStore, LocalIdentity) {
        var identity = LocalIdentity.generate()
        if let floor {
            // P-256 key generation is cheap and the predicate holds for roughly half of the draws,
            // so this terminates almost immediately.
            while ByteOps.compareUnsigned(identity.deviceId, floor.deviceId) <= 0 {
                identity = LocalIdentity.generate()
            }
        }
        let store = InMemoryChatStore()
        try? store.saveIdentity(identity.toRecord(nickname: "test"))
        return (store, identity)
    }

    func testATapConnectsThroughTheTransportAndAsksForTheSafetyCodeExactlyOnce() throws {
        try withHarness { harness in
            let events = recordEvents(harness.nodeA)
            harness.transportA.reportSeen(label: "AA:BB:CC:DD:EE:FF")
            waitUntil("nodeA shows an anonymous nearby entry") {
                harness.nodeA.state.nearby.first?.label == "AA:BB:CC:DD:EE:FF"
            }

            XCTAssertEqual(
                ConnectResult.started,
                harness.nodeA.requestConnect(peerHandle: "AA:BB:CC:DD:EE:FF")
            )
            waitUntil("the tap reached the transport") {
                harness.transportA.connectRequests == ["AA:BB:CC:DD:EE:FF"]
            }

            harness.connect(labelA: "AA:BB:CC:DD:EE:FF", labelB: "11:22:33:44:55:66")
            waitForReady(harness)

            waitUntil("exactly one verify prompt") { events.prompts.count == 1 }
            XCTAssertEqual(harness.nodeB.deviceIdHex, events.prompts.first)
            // A prompt is a one-shot offer: a second handshake must not re-open it on its own.
            Thread.sleep(forTimeInterval: 0.15)
            XCTAssertEqual(1, events.prompts.count)
        }
    }

    func testAPeerWhoseCodeIsAlreadyTrustedIsNeverPromptedAgain() throws {
        try withHarness { harness in
            let events = recordEvents(harness.nodeA)
            harness.connect(labelA: "AA:BB:CC:DD:EE:FF", labelB: "11:22:33:44:55:66")
            waitForReady(harness)

            let peerHex = harness.nodeB.deviceIdHex
            harness.nodeA.confirmSafetyCode(peerIdHex: peerHex, accepted: true)
            waitUntil("the verdict is stored") {
                harness.nodeA.state.links.first?.trustState == TrustState.trusted
            }

            // Drop the link and tap the same peer again: the handshake repeats, the prompt must not.
            harness.links?.0.close()
            waitUntil("the old link is gone") { harness.nodeA.state.links.isEmpty }
            harness.transportA.reportSeen(label: "AA:BB:CC:DD:EE:FF")
            XCTAssertEqual(
                ConnectResult.started,
                harness.nodeA.requestConnect(peerHandle: "AA:BB:CC:DD:EE:FF")
            )
            harness.connect(labelA: "AA:BB:CC:DD:EE:FF", labelB: "11:22:33:44:55:66")
            waitForReady(harness)

            Thread.sleep(forTimeInterval: 0.2)
            XCTAssertTrue(events.prompts.isEmpty, "a trusted peer must not be re-prompted")
        }
    }

    func testATapThatNeverConnectsExpiresInsteadOfPromptingLater() throws {
        let transportA = FakeTransport()
        let transportB = FakeTransport()
        // A 50 ms deadline stands in for the 20 s one, which is the only way to exercise the
        // expiry without a 20 s test.
        let nodeA = AirChatNode(
            store: InMemoryChatStore(), transport: transportA, pendingConnectMs: 50
        )
        let nodeB = AirChatNode(store: InMemoryChatStore(), transport: transportB)
        nodeA.start()
        nodeB.start()
        defer {
            nodeA.stop()
            nodeB.stop()
        }
        let events = recordEvents(nodeA)

        transportA.reportSeen(label: "AA:BB:CC:DD:EE:FF")
        XCTAssertEqual(ConnectResult.started, nodeA.requestConnect(peerHandle: "AA:BB:CC:DD:EE:FF"))
        Thread.sleep(forTimeInterval: 0.2) // the tap goes stale before anything connects

        FakeBle.connect(
            transportA, transportB, labelA: "AA:BB:CC:DD:EE:FF", labelB: "11:22:33:44:55:66"
        )
        waitUntil("both links are ready") {
            nodeA.state.readyLinkCount == 1 && nodeB.state.readyLinkCount == 1
        }
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertTrue(events.prompts.isEmpty, "a stale tap must stay silent")
    }

    func testATapFollowsTheLinkThatSurvivesLinkDeduplication() throws {
        // Seeding the identities makes the dedupe survivor deterministic. The survivor is the link
        // whose *central* has the smaller deviceId, and the test needs that to be the link the user
        // did not tap - otherwise the prompt would fire before the dedupe and prove nothing.
        let (storeB, identityB) = seededStore()
        let (storeA, identityA) = seededStore(largerThan: identityB)

        let transportA = FakeTransport()
        let transportB = FakeTransport()
        let nodeA = AirChatNode(store: storeA, transport: transportA)
        let nodeB = AirChatNode(store: storeB, transport: transportB)
        nodeA.start()
        nodeB.start()
        defer {
            nodeA.stop()
            nodeB.stop()
        }
        let events = recordEvents(nodeA)
        XCTAssertEqual(identityA.deviceIdHex, nodeA.deviceIdHex)

        // The user taps the handle of the link *A* would initiate.
        XCTAssertEqual(ConnectResult.started, nodeA.requestConnect(peerHandle: "A-SEES-B"))

        // Both sides connect at once: A central (the tapped handle) and B central (which leaves A
        // in the peripheral role, under a different handle). The peer-initiated one completes
        // first, so the tapped link arrives second and loses the dedupe.
        FakeBle.connect(
            transportA,
            transportB,
            aIsCentral: false,
            labelPrefix: "peer",
            labelA: "A-SEES-B-OTHER",
            labelB: "B-SEES-A-OTHER"
        )
        waitUntil("the peer-initiated link is ready first") {
            let links = nodeA.state.links
            return links.count == 1 && links[0].ready && !links[0].isCentral
        }
        FakeBle.connect(
            transportA,
            transportB,
            aIsCentral: true,
            labelPrefix: "tapped",
            labelA: "A-SEES-B",
            labelB: "B-SEES-A"
        )

        waitUntil("the tap still produced a prompt") { events.prompts.count == 1 }
        waitUntil("one link survives on A") { nodeA.state.links.count == 1 }
        // The survivor is the handle the user did *not* tap, so the prompt above could only have
        // come from the tap following the surviving link.
        XCTAssertFalse(nodeA.state.links[0].isCentral)
        XCTAssertEqual(identityB.deviceIdHex, events.prompts.first)
    }

    func testScanningIsABoundedUserActionRatherThanADefault() throws {
        let transport = FakeTransport()
        // A 50 ms window stands in for the 30 s one.
        let node = AirChatNode(store: InMemoryChatStore(), transport: transport, scanWindowMs: 50)
        node.start()
        defer { node.stop() }

        // Starting the node must not start looking: that is the user's decision, and it is the part
        // that costs battery.
        XCTAssertEqual(0, transport.scanStarts)
        XCTAssertFalse(node.state.scanning)

        node.startScan()
        waitUntil("the scan window is open") { transport.scanStarts == 1 && node.state.scanning }
        waitUntil("the window closes by itself") { transport.scanStops == 1 && !node.state.scanning }
    }

    func testEndingAScanLeavesEstablishedLinksAlone() throws {
        try withHarness { harness in
            harness.connect()
            waitForReady(harness)

            harness.nodeA.startScan()
            waitUntil("nodeA is scanning") { harness.nodeA.state.scanning }
            harness.nodeA.stopScan()
            waitUntil("nodeA stopped scanning") { !harness.nodeA.state.scanning }

            // Scanning is about finding people, not about being connected to them.
            Thread.sleep(forTimeInterval: 0.1)
            XCTAssertEqual(1, harness.nodeA.state.readyLinkCount)
        }
    }

    func testTappingAPeerThatIsAlreadyLinkedDoesNotStartASecondConnection() throws {
        try withHarness { harness in
            // The tap names the handle we scanned; the link reports a different handle for the same
            // person. Recognising the existing link by handle alone therefore failed, and the app
            // connected to the same peer twice - which the dedupe resolved with a notice the user
            // could not act on.
            harness.transportA.reportSeen(label: "SCANNED-BY-A")
            harness.connect(labelA: "CONNECTED-AS", labelB: "SOMETHING-ELSE")
            waitForReady(harness)

            XCTAssertEqual(ConnectResult.started, harness.nodeA.requestConnect(peerHandle: "SCANNED-BY-A"))
            Thread.sleep(forTimeInterval: 0.15)
            XCTAssertTrue(harness.transportA.connectRequests.isEmpty, "no second connection may start")
            XCTAssertEqual(1, harness.nodeA.state.links.count)
        }
    }

    func testATapIsResolvedByEliminationWhenTheHandleChangesWithTheRole() throws {
        try withHarness { harness in
            // On iOS the identifier of a peer seen while scanning differs from the identifier of the
            // same peer connecting to us - measured on device - so the handle cannot be compared.
            harness.transportA.reportSeen(label: "SCANNED-BY-A")
            waitUntil("nodeA shows the advertisement") {
                harness.nodeA.state.nearby.first?.label == "SCANNED-BY-A"
            }

            let events = recordEvents(harness.nodeA)
            XCTAssertEqual(ConnectResult.started, harness.nodeA.requestConnect(peerHandle: "SCANNED-BY-A"))

            // The link reports a completely different handle for the same person.
            harness.connect(labelA: "CONNECTED-AS", labelB: "SOMETHING-ELSE")
            waitForReady(harness)

            waitUntil("the prompt fired for the tapped peer") { events.prompts.count == 1 }
            XCTAssertEqual(harness.nodeB.deviceIdHex, events.prompts.first)
            // The attribution is what stops the list from showing that person twice: once by handle
            // and once by deviceId.
            waitUntil("the advertisement is attributed to the peer") {
                harness.nodeA.state.nearby.first?.peerIdHex == harness.nodeB.deviceIdHex
            }
        }
    }

    func testEliminationRefusesToAttributeWhenTwoCandidatesAreUnattributed() throws {
        try withHarness { harness in
            // Two advertisements and one link that matches neither handle: attributing either entry
            // would attach one person's identity to another person's safety code, so nothing is
            // claimed.
            harness.transportA.reportSeen(label: "ENTRY-ONE")
            harness.transportA.reportSeen(label: "ENTRY-TWO")
            waitUntil("nodeA shows both advertisements") { harness.nodeA.state.nearby.count == 2 }

            harness.connect(labelA: "CONNECTED-AS", labelB: "SOMETHING-ELSE")
            waitForReady(harness)

            Thread.sleep(forTimeInterval: 0.15)
            XCTAssertTrue(
                harness.nodeA.state.nearby.allSatisfy { $0.peerIdHex == nil },
                "an ambiguous match must not be guessed"
            )
        }
    }

    func testAtTheLinkCapATapIsRefusedWithoutAskingTheTransport() throws {
        let transportA = FakeTransport()
        let transportB = FakeTransport()
        let nodeA = AirChatNode(store: InMemoryChatStore(), transport: transportA, maxLinks: 1)
        let nodeB = AirChatNode(store: InMemoryChatStore(), transport: transportB)
        nodeA.start()
        nodeB.start()
        defer {
            nodeA.stop()
            nodeB.stop()
        }

        FakeBle.connect(
            transportA, transportB, labelA: "AA:BB:CC:DD:EE:FF", labelB: "11:22:33:44:55:66"
        )
        waitUntil("the only allowed link is ready") { nodeA.state.readyLinkCount == 1 }

        guard case .rejected = nodeA.requestConnect(peerHandle: "77:88:99:AA:BB:CC") else {
            return XCTFail("the cap must be reported, not silently ignored")
        }
        XCTAssertTrue(transportA.connectRequests.isEmpty, "no attempt may start at the cap")
    }

    func testANearbyEntryIsAttributedToThePeerOnceAHandshakeRevealsIt() throws {
        try withHarness { harness in
            harness.transportA.reportSeen(label: "AA:BB:CC:DD:EE:FF")
            waitUntil("the entry starts out anonymous") {
                harness.nodeA.state.nearby.first?.peerIdHex == nil
            }

            harness.connect(labelA: "AA:BB:CC:DD:EE:FF", labelB: "11:22:33:44:55:66")
            waitForReady(harness)

            // Attribution is what lets the UI show one row per person with a real nickname instead
            // of listing the same device twice, once by handle and once by deviceId.
            waitUntil("the entry is attributed") {
                harness.nodeA.state.nearby.first?.peerIdHex == harness.nodeB.deviceIdHex
            }
            XCTAssertEqual("AA:BB:CC:DD:EE:FF", harness.nodeA.state.links.first?.peerHandle)
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
