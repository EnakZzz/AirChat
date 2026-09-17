import Foundation
import os

/// Logging seam so the protocol core stays free of UI and platform frameworks.
public protocol AirChatLogger: AnyObject {
    func log(_ tag: String, _ message: String)
}

public final class NoopLogger: AirChatLogger {
    public init() {}
    public func log(_ tag: String, _ message: String) {}
}

/// Single shared os.Logger instance; `os.Logger` is cheap and privacy-aware.
public final class OsLogger: AirChatLogger {
    private let logger = Logger(subsystem: "app.airchat", category: "protocol")

    public init() {}

    public func log(_ tag: String, _ message: String) {
        logger.debug("[\(tag, privacy: .public)] \(message, privacy: .public)")
    }
}

/// Writes protocol logs to stderr, which is what `xcrun devicectl device process launch
/// --console` captures.
///
/// This is the only way to read a real iPhone's protocol logs from the host: the unified log is
/// not reachable over `devicectl`, and the in-app buffer requires tapping through the UI. Wired in
/// for debug builds only (see `AppContainer`).
public final class ConsoleLogger: AirChatLogger {
    public init() {}

    public func log(_ tag: String, _ message: String) {
        FileHandle.standardError.write(Data("AIRCHAT_LOG [\(tag)] \(message)\n".utf8))
    }
}

/// Bounded in-memory log tail, surfaced by the settings screen for on-device debugging.
public final class BufferLogger: AirChatLogger {
    private let capacity: Int
    private var entries: [String] = []

    public init(capacity: Int = 500) {
        self.capacity = capacity
    }

    public func log(_ tag: String, _ message: String) {
        entries.append("\(tag): \(message)")
        if entries.count > capacity {
            entries.removeFirst(entries.count - capacity)
        }
    }

    public func snapshot() -> [String] { entries }

    public func clear() { entries.removeAll() }
}

public final class FanOutLogger: AirChatLogger {
    private let sinks: [AirChatLogger]

    public init(_ sinks: AirChatLogger...) {
        self.sinks = sinks
    }

    public func log(_ tag: String, _ message: String) {
        for sink in sinks { sink.log(tag, message) }
    }
}
