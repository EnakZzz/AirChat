import AirChatBLE
import AirChatData
import AirChatProtocol
import SwiftUI

/// Composition root. The object graph lives for the whole process so an established BLE link is
/// never torn down by a view being recreated.
final class AppContainer {

    /// Bounded in-memory log tail surfaced by the settings screen for on-device debugging.
    let diagnostics = BufferLogger()

    let node: AirChatNode
    private let store: SqliteChatStore

    /// Machine-readable heartbeat consumed by tools/cross_device_test.py.
    private let reporter: DiagnosticStateReporter

    private let logger: AirChatLogger

    init() {
        #if DEBUG
        // Debug builds also stream protocol logs to stderr so `devicectl --console` can read them.
        let logger = FanOutLogger(OsLogger(), ConsoleLogger(), diagnostics)
        #else
        let logger = FanOutLogger(OsLogger(), diagnostics)
        #endif
        self.logger = logger
        let store: SqliteChatStore
        do {
            store = try SqliteChatStore(path: try SqliteChatStore.defaultPath())
        } catch {
            // Storage is the one dependency that cannot be absent: without it identity and message
            // history would silently reset on every launch.
            fatalError("cannot open the AirChat database: \(error)")
        }
        self.store = store
        let node = AirChatNode(store: store, transport: BleTransport(logger: logger), logger: logger)
        self.node = node
        self.reporter = DiagnosticStateReporter(node: node)
        // Started in init so the heartbeat also runs before the transport is up: that lets the
        // harness distinguish a dead app from a not-yet-connected one.
        reporter.start()

        #if DEBUG
        // Host-driven message injection for tools/cross_device_test.py:
        //   devicectl ... -e '{"AIRCHAT_SELFTEST":"channel:hi,private:secret"}'
        // Debug only, so a release build has no way to be told to send anything.
        if let spec = ProcessInfo.processInfo.environment["AIRCHAT_SELFTEST"], !spec.isEmpty {
            runSelfTest(spec)
        }
        #endif
    }

    /// Waits for a ready link, then sends whatever the host asked for.
    ///
    /// Deliberately waits rather than requiring the caller to time it: the link is established by two
    /// radios negotiating, so the only reliable trigger is "as soon as we are connected".
    func runSelfTest(_ spec: String) {
        // The received spec is logged because a truncated argument is otherwise invisible: it only
        // shows up much later as a message that never arrived.
        logger.log("SelfTest", "selftest spec received: \(spec)")
        Task { [node] in
            let deadline = Date().addingTimeInterval(45)
            while Date() < deadline, node.state.readyLinkCount == 0 {
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            guard node.state.readyLinkCount > 0 else { return }

            // The separator is `,` and not `|` on purpose: the Android side receives this same
            // script through `adb shell`, whose shell reads an unquoted `|` as a pipe and truncates
            // the extra. Both platforms must therefore agree on a separator with no shell meaning.
            for part in spec.split(separator: ",") {
                let pieces = part.split(separator: ":", maxSplits: 1)
                guard pieces.count == 2 else { continue }
                let kind = pieces[0].trimmingCharacters(in: .whitespaces)
                let text = String(pieces[1])
                if kind == "channel" {
                    switch node.postChannelMessage(text) {
                    case .sent: logger.log("SelfTest", "channel send accepted")
                    case .rejected(let reason): logger.log("SelfTest", "channel send rejected: \(reason)")
                    }
                } else if kind == "private" {
                    guard let peer = node.state.links.first(where: { $0.ready })?.peerIdHex else {
                        logger.log("SelfTest", "private send skipped: no ready link")
                        continue
                    }
                    switch node.sendPrivateMessage(peerIdHex: peer, text: text) {
                    case .sent: logger.log("SelfTest", "private send accepted to \(peer)")
                    case .rejected(let reason): logger.log("SelfTest", "private send rejected: \(reason)")
                    }
                }
            }
        }
    }

    var chatStore: ChatStore { store }

    func start() { node.start() }
    func stop() { node.stop() }

    func logTail() -> [String] { diagnostics.snapshot() }
}

@main
struct AirChatApp: App {

    @StateObject private var model: ChatViewModel

    // `App` is main-actor isolated in the iOS 17+ SDKs, and `ChatViewModel` is a `@MainActor`
    // type, so the initialiser is annotated explicitly rather than relying on inference.
    @MainActor
    init() {
        let container = AppContainer()
        _model = StateObject(wrappedValue: ChatViewModel(container: container))
    }

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .onAppear { model.start() }
        }
    }
}
