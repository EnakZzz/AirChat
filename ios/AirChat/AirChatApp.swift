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

    init() {
        let logger = FanOutLogger(OsLogger(), diagnostics)
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
