import AirChatProtocol
import Foundation
import SwiftUI

/// One row in the direct-message list.
struct Conversation: Identifiable, Equatable {
    let peerIdHex: String
    let nickname: String
    let lastText: String
    let lastAtMs: Int64
    let connected: Bool
    let trustState: Int

    var id: String { peerIdHex }
}

/// Single source of truth for the SwiftUI layer.
///
/// The node owns all protocol state; this model only projects persisted messages plus the node's
/// state into renderable shapes and forwards user intents. Storage reads are synchronous because
/// SQLite access is local and the tables are small.
@MainActor
final class ChatViewModel: ObservableObject {

    @Published private(set) var nodeState: NodeState = .empty
    @Published private(set) var channel: [MessageRecord] = []
    @Published private(set) var conversations: [Conversation] = []
    @Published private(set) var thread: [MessageRecord] = []
    @Published private(set) var selectedPeerHex: String?
    @Published private(set) var selectedNickname: String?
    @Published private(set) var selectedTrustState: Int = TrustState.unverified
    @Published private(set) var selectedSafetyCode: String?
    @Published private(set) var selectedConnected: Bool = false
    @Published private(set) var selectedConnectionState: SessionState = .new
    @Published var notice: String?

    private let container: AppContainer
    private let store: ChatStore

    init(container: AppContainer) {
        self.container = container
        store = container.chatStore

        container.node.onStateChanged = { [weak self] state in
            Task { @MainActor in
                self?.nodeState = state
                self?.reload()
            }
        }
        container.node.addEventObserver { [weak self] event in
            Task { @MainActor in
                self?.handle(event)
            }
        }
    }

    // ------------------------------------------------------------- lifecycle

    func start() {
        container.start()
        reload()
    }

    func stop() {
        container.stop()
    }

    var localNickname: String { nodeState.nickname }
    var deviceIdHex: String { nodeState.deviceIdHex }

    // ---------------------------------------------------------------- intents

    func postToChannel(_ text: String) {
        switch container.node.postChannelMessage(text) {
        case .sent:
            reload()
        case .rejected(let reason):
            notice = reason
        }
    }

    func sendPrivate(_ text: String) {
        guard let peer = selectedPeerHex else { return }
        switch container.node.sendPrivateMessage(peerIdHex: peer, text: text) {
        case .sent:
            reload()
        case .rejected(let reason):
            notice = reason
        }
    }

    func select(_ peerIdHex: String?) {
        selectedPeerHex = peerIdHex
        reload()
    }

    func setNickname(_ nickname: String) {
        container.node.setNickname(nickname)
        reload()
    }

    func confirmSafety(peerIdHex: String, accepted: Bool) {
        container.node.confirmSafetyCode(peerIdHex: peerIdHex, accepted: accepted)
        reload()
    }

    func requestChannelSync() {
        container.node.requestChannelSync()
    }

    func logs() -> [String] { container.logTail() }

    // --------------------------------------------------------------- loading

    private func handle(_ event: NodeEvent) {
        switch event {
        case .notice(let message), .failure(let message):
            notice = message
        default:
            break
        }
        reload()
    }

    private func reload() {
        nodeState = container.node.state

        channel = (try? store.listMessages(
            conversationId: AirChatProtocol.channelConversationId,
            limit: Self.channelWindow
        )) ?? []

        let peers = (try? store.listPeers()) ?? []
        conversations = peers.compactMap { peer in
            let peerHex = ByteOps.toHex(peer.deviceId)
            guard let last = (try? store.listMessages(conversationId: peerHex, limit: 1))?.last else {
                return nil
            }
            return Conversation(
                peerIdHex: peerHex,
                nickname: peer.nickname.isEmpty ? String(peerHex.prefix(8)) : peer.nickname,
                lastText: last.text,
                lastAtMs: last.receivedMs,
                connected: nodeState.links.contains { $0.peerIdHex == peerHex && $0.ready },
                trustState: peer.trustState
            )
        }.sorted { $0.lastAtMs > $1.lastAtMs }

        guard let selected = selectedPeerHex else {
            thread = []
            selectedNickname = nil
            selectedSafetyCode = nil
            selectedTrustState = TrustState.unverified
            selectedConnected = false
            selectedConnectionState = .new
            return
        }

        thread = (try? store.listMessages(conversationId: selected, limit: Self.threadWindow)) ?? []
        let link = nodeState.links.first { $0.peerIdHex == selected }
        let peer = try? store.getPeer(ByteOps.fromHex(selected))
        selectedNickname = link?.nickname ?? peer?.nickname
        selectedSafetyCode = link?.safetyCode
        selectedTrustState = peer?.trustState ?? TrustState.unverified
        selectedConnected = link?.ready == true
        selectedConnectionState = selectedConnected ? .ready : .new
    }

    private static let channelWindow = 500
    private static let threadWindow = 500
}
