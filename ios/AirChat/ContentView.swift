import AirChatProtocol
import SwiftUI

/// Root view: a `TabView` whose tabs mirror the Android shell's four screens.
///
/// `NavigationStack` gives the direct-message tab its list/detail flow, including the
/// interactive back gesture, instead of hand-rolling navigation state.
struct ContentView: View {

    @ObservedObject var model: ChatViewModel
    @State private var tab: Tab = .nearby

    enum Tab: Hashable {
        case nearby, channel, direct, settings
    }

    var body: some View {
        TabView(selection: $tab) {
            NavigationStack {
                NearbyView(model: model, onRowClick: handleRowTap)
                    .navigationTitle("附近")
            }
            .tabItem { Label("附近", systemImage: "dot.radiowaves.left.and.right") }
            .tag(Tab.nearby)

            NavigationStack {
                ChannelView(model: model)
                    .navigationTitle("公共频道")
            }
            .tabItem { Label("公共频道", systemImage: "person.3") }
            .tag(Tab.channel)

            NavigationStack {
                DirectView(model: model, onVerify: { model.requestVerification(peerIdHex: $0) })
                    .navigationTitle("私聊")
            }
            .tabItem { Label("私聊", systemImage: "person") }
            .tag(Tab.direct)

            NavigationStack {
                SettingsView(model: model)
                    .navigationTitle("设置")
            }
            .tabItem { Label("设置", systemImage: "gearshape") }
            .tag(Tab.settings)
        }
        .sheet(
            isPresented: Binding(
                get: { model.verifyRequest != nil },
                set: { if !$0 { model.dismissVerification() } }
            )
        ) {
            SafetyCodeSheet(
                nickname: model.verifyRequest?.nickname ?? "对方",
                code: model.verifyRequest?.code,
                onConfirm: { resolveSafetyCode(accepted: true) },
                onReject: { resolveSafetyCode(accepted: false) },
                onDismiss: { model.dismissVerification() }
            )
        }
        .alert(
            "提示",
            isPresented: Binding(
                get: { model.notice != nil },
                set: { if !$0 { model.notice = nil } }
            ),
            actions: { Button("好", role: .cancel) { model.notice = nil } },
            message: { Text(model.notice ?? "") }
        )
    }

    /// One tap means three different things depending on state, which is what keeps the screen free
    /// of buttons: reach out, compare the code, or open the conversation.
    private func handleRowTap(_ row: NearbyRow) {
        switch row.state {
        case .nearby:
            model.requestConnect(peerHandle: row.label)
        case .unverified, .rejected:
            if let peer = row.peerIdHex { model.requestVerification(peerIdHex: peer) }
        case .trusted:
            if let peer = row.peerIdHex { openThread(peer) }
        case .connecting:
            break
        }
    }

    private func resolveSafetyCode(accepted: Bool) {
        guard let peer = model.verifyRequest?.peerIdHex else {
            model.dismissVerification()
            return
        }
        model.confirmSafety(peerIdHex: peer, accepted: accepted)
        // Confirming in person is the end of the connection flow: land the user in the conversation
        // rather than dropping them back on the list.
        if accepted { openThread(peer) }
    }

    private func openThread(_ peerIdHex: String) {
        tab = .direct
        model.select(peerIdHex)
    }
}
