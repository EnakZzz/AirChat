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

/// The five states a person's row can be in, declared in display order: whoever needs a decision
/// comes first, then whoever is reachable, then whoever is merely visible.
enum NearbyState: Int, CaseIterable {
    case unverified
    case rejected
    case trusted
    case connecting
    case nearby

    var label: String {
        switch self {
        case .unverified: return "待核对"
        case .rejected: return "已拒绝"
        case .trusted: return "已连接"
        case .connecting: return "连接中…"
        case .nearby: return "可连接"
        }
    }
}

/// One row of the nearby list: one person, whatever state their link is in.
///
/// Keyed by deviceId once a handshake has revealed it, and by the platform handle before that, so
/// the same person cannot appear twice - once as an advertisement and once as a link - which is
/// what the old two-section layout did.
struct NearbyRow: Identifiable, Equatable {
    /// Stable identity for the row: the deviceId when known, otherwise `h:<handle>`.
    let id: String
    /// Platform handle, which is what a connect request has to name.
    let label: String
    /// Nickname once known, otherwise an anonymous short name.
    let title: String
    let state: NearbyState
    let rssi: Int?
    let peerIdHex: String?
}

/// The peer whose safety code the user is being asked to compare.
struct VerifyRequest: Equatable {
    let peerIdHex: String
    let nickname: String
    let code: String?
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
    /// The nearby list, already merged into one row per person.
    @Published private(set) var nearby: [NearbyRow] = []
    /// Non-nil while the safety-code sheet should be on screen.
    @Published private(set) var verifyRequest: VerifyRequest?
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

    /// Asks the transport to reach a person the user tapped, and remembers the tap so the safety
    /// code is offered automatically once their handshake completes.
    func requestConnect(peerHandle: String) {
        switch container.node.requestConnect(peerHandle: peerHandle) {
        case .started:
            reload()
        case .rejected(let reason):
            notice = reason
        }
    }

    /// Opens the safety-code sheet for a peer we are already connected to.
    func requestVerification(peerIdHex: String) {
        let link = nodeState.links.first { $0.peerIdHex == peerIdHex }
        verifyRequest = VerifyRequest(
            peerIdHex: peerIdHex,
            nickname: link?.nickname ?? String(peerIdHex.prefix(8)),
            code: link?.safetyCode
        )
    }

    func dismissVerification() {
        verifyRequest = nil
    }

    func confirmSafety(peerIdHex: String, accepted: Bool) {
        // Dismiss first: the sheet's own confirm button is the last thing the user touched, and the
        // navigation that may follow should not race a still-visible sheet.
        verifyRequest = nil
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
        case .verifyRequested(let peerIdHex):
            // The node only ever asks for a comparison for the peer the user tapped, and only once,
            // so this needs no extra bookkeeping here.
            requestVerification(peerIdHex: peerIdHex)
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

        nearby = buildNearbyRows()

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
        // Drop the sheet if the peer left, so it cannot outlive the link it describes.
        if let request = verifyRequest,
           !nodeState.links.contains(where: { $0.peerIdHex == request.peerIdHex && $0.ready }) {
            verifyRequest = nil
        }
    }

    /// Merges the three sources of "who is around" into one row per person.
    ///
    /// A person is reachable in up to three ways at once - advertising, mid-handshake, and linked -
    /// and the list has to show exactly one of them, with the most progressed state winning.
    private func buildNearbyRows() -> [NearbyRow] {
        let peers = (try? store.listPeers()) ?? []
        var nicknameByHex: [String: String] = [:]
        for peer in peers {
            let hex = ByteOps.toHex(peer.deviceId)
            if !peer.nickname.isEmpty { nicknameByHex[hex] = peer.nickname }
        }

        var rows: [String: NearbyRow] = [:]
        var claimedHandles: Set<String> = []

        // Linked: one row per person, keyed by deviceId so a reconnect cannot duplicate it.
        for link in nodeState.links where link.ready {
            guard let peerHex = link.peerIdHex else { continue }
            if let handle = link.peerHandle { claimedHandles.insert(handle) }
            let state: NearbyState
            switch link.trustState {
            case TrustState.trusted: state = .trusted
            case TrustState.rejected: state = .rejected
            default: state = .unverified
            }
            rows[peerHex] = NearbyRow(
                id: peerHex,
                label: link.peerHandle ?? peerHex,
                title: link.nickname.flatMap { $0.isEmpty ? nil : $0 }
                    ?? nicknameByHex[peerHex]
                    ?? anonymousName(handle: link.peerHandle ?? peerHex),
                state: state,
                rssi: nil,
                peerIdHex: peerHex
            )
        }

        // Mid-handshake: only visible on the side that initiated, because the handle of a link the
        // peer opened is the peer's view of us, not the handle we scanned.
        for link in nodeState.links where !link.ready {
            guard let handle = link.peerHandle else { continue }
            let key = "h:\(handle)"
            if claimedHandles.contains(handle) || rows[key] != nil { continue }
            claimedHandles.insert(handle)
            rows[key] = NearbyRow(
                id: key,
                label: handle,
                title: anonymousName(handle: handle),
                state: .connecting,
                rssi: nil,
                peerIdHex: nil
            )
        }

        // Merely visible. Skipped when a link already speaks for that handle, or when the node has
        // already attributed the advertisement to a person we are showing.
        for peer in nodeState.nearby {
            if claimedHandles.contains(peer.label) { continue }
            if let known = peer.peerIdHex, rows[known] != nil { continue }
            let key = "h:\(peer.label)"
            rows[key] = NearbyRow(
                id: key,
                label: peer.label,
                title: peer.peerIdHex.flatMap { nicknameByHex[$0] } ?? anonymousName(handle: peer.label),
                state: .nearby,
                rssi: peer.rssi,
                peerIdHex: peer.peerIdHex
            )
        }

        // Display order is the enum's declaration order: a decision the user owes comes before one
        // they have already made, and anyone reachable comes before anyone merely visible.
        return rows.values.sorted { lhs, rhs in
            if lhs.state != rhs.state { return lhs.state.rawValue < rhs.state.rawValue }
            if lhs.rssi != rhs.rssi { return (lhs.rssi ?? -127) > (rhs.rssi ?? -127) }
            return lhs.title < rhs.title
        }
    }

    private static let channelWindow = 500
    private static let threadWindow = 500
}

/// `附近设备 · 9B42`: a platform handle is a CoreBluetooth UUID or a BLE address, which tells a
/// person nothing, so it is reduced to a short tail that is at least stable and distinguishable.
func anonymousName(handle: String) -> String {
    let tail = String(handle.filter { $0.isLetter || $0.isNumber }.suffix(4)).uppercased()
    return tail.isEmpty ? "附近设备" : "附近设备 · \(tail)"
}
