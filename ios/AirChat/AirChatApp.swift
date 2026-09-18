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
            // The harness drives the app the way a user does, and a user has to ask for a scan
            // before anybody is discoverable. The window is longer than a person needs so discovery
            // cannot expire halfway through a 90 s run.
            node.startScan(durationMs: 300_000)
            runSelfTest(spec)
        }
        // Taps the first person that shows up, so the harness can drive the same path a user does
        // instead of only the messaging path.
        if ProcessInfo.processInfo.environment["AIRCHAT_CONNECT_FIRST"] == "1" {
            node.startScan(durationMs: 300_000)
            connectFirstPeer()
        }
        // Forget the safety-code verdicts: a confirmed code is deliberately remembered and not
        // offered again, so a suite that wants to observe a *first* comparison needs a device with
        // no stored verdict - and clearing app data instead would drop the Bluetooth permission.
        if ProcessInfo.processInfo.environment["AIRCHAT_CLEAR_TRUST"] == "1" {
            node.clearTrustVerdicts()
        }
        // Scan and nothing else: the harness uses this for the phases that are about the link itself
        // rather than about a scripted message.
        if ProcessInfo.processInfo.environment["AIRCHAT_SCAN"] == "1" {
            logger.log("SelfTest", "debug scan requested")
            node.startScan(durationMs: 300_000)
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

    /// Debug-only: taps the first person that appears in the nearby list, exactly the way a user
    /// would, and stops there. The safety-code prompt that follows is the assertion the harness
    /// makes, so this deliberately does not confirm anything on the user's behalf.
    func connectFirstPeer() {
        Task { [node, logger] in
            let deadline = Date().addingTimeInterval(45)
            while Date() < deadline, node.state.nearby.isEmpty {
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            guard let peer = node.state.nearby.first else {
                logger.log("SelfTest", "connect-first found nobody nearby")
                return
            }
            switch node.requestConnect(peerHandle: peer.label) {
            case .started:
                logger.log("SelfTest", "connect-first -> started with \(peer.label)")
            case .rejected(let reason):
                logger.log("SelfTest", "connect-first rejected: \(reason)")
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
