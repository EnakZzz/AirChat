import AirChatProtocol
import SwiftUI

/// Root view: a `TabView` whose tabs mirror the Android shell's four screens.
///
/// `NavigationStack` gives the direct-message tab its list/detail flow, including the
/// interactive back gesture, instead of hand-rolling navigation state.
struct ContentView: View {

    @ObservedObject var model: ChatViewModel
    @State private var tab: Tab = .nearby
    @State private var verifyingPeer: LinkInfo?
    @State private var isVerifying = false

    enum Tab: Hashable {
        case nearby, channel, direct, settings
    }

    var body: some View {
        TabView(selection: $tab) {
            NavigationStack {
                NearbyView(model: model, onVerify: { verifyingPeer = $0; isVerifying = true })
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
                DirectView(model: model, onVerify: { verifyingPeer = $0; isVerifying = true })
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
        .sheet(isPresented: $isVerifying) {
            SafetyCodeSheet(
                nickname: verifyingPeer?.nickname ?? "对方",
                code: verifyingPeer?.safetyCode,
                onConfirm: {
                    if let peer = verifyingPeer?.peerIdHex {
                        model.confirmSafety(peerIdHex: peer, accepted: true)
                    }
                    isVerifying = false
                },
                onReject: {
                    if let peer = verifyingPeer?.peerIdHex {
                        model.confirmSafety(peerIdHex: peer, accepted: false)
                    }
                    isVerifying = false
                },
                onDismiss: { isVerifying = false }
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
}
