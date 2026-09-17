import AirChatProtocol
import Foundation

/// Emits one machine-readable status line per second so a host-side harness can verify a
/// two-device session without screenshots or UI automation.
///
/// Written to **stderr**: that is what `xcrun devicectl device process launch --console` captures,
/// and it is unbuffered, so lines appear immediately rather than when some buffer fills.
///
/// The format is byte-identical to the Android reporter (see
/// android/app/src/main/kotlin/com/airchat/app/DiagnosticStateReporter.kt) so one parser reads both:
///
/// `AIRCHAT_STATE {"platform":"ios","self":"<32 hex>","status":"scanning","nearby":1,
///                  "links":[{"peer":"<32 hex>","ready":true,"central":false,"mtu":185,"code":"123456"}]}`
final class DiagnosticStateReporter {

    private let node: AirChatNode
    private var task: Task<Void, Never>?

    init(node: AirChatNode) {
        self.node = node
    }

    func start(interval: TimeInterval = 1) {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.emit()
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    private func emit() {
        let state = node.state
        let links = state.links.map { link -> String in
            let peer = link.peerIdHex.map { "\"\($0)\"" } ?? "null"
            let code = link.safetyCode.map { "\"\($0)\"" } ?? "null"
            return "{\"peer\":\(peer),\"ready\":\(link.ready),\"central\":\(link.isCentral),"
                + "\"mtu\":\(link.mtu),\"code\":\(code)}"
        }
        let line = "AIRCHAT_STATE {\"platform\":\"ios\","
            + "\"self\":\"\(state.deviceIdHex)\","
            + "\"status\":\"\(statusName(state.status))\","
            + "\"nearby\":\(state.nearby.count),"
            + "\"links\":[\(links.joined(separator: ","))]}\n"
        FileHandle.standardError.write(Data(line.utf8))
    }

    private func statusName(_ status: ChatStatus) -> String {
        switch status {
        case .stopped: return "stopped"
        case .bluetoothUnavailable: return "bluetoothunavailable"
        case .permissionMissing: return "permissionmissing"
        case .scanning: return "scanning"
        case .nearbyFull: return "nearbyfull"
        case .failed: return "failed"
        }
    }
}
