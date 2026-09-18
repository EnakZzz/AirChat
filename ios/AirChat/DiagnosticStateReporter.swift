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

    // Counters proving messages actually crossed the link. Inbound counts come from stored messages
    // and `delivered` from the DELIVERY_ACK that upgrades an outgoing message, so a non-zero
    // `delivered` on both sides exercises the notification path in both directions.
    private var channelInbound = 0
    private var privateInbound = 0
    private var deliveredOutbound = 0
    private var verifyPrompts = 0
    private var lastChannelText = ""
    private var lastPrivateText = ""

    init(node: AirChatNode) {
        self.node = node
        node.addEventObserver { [weak self] event in
            guard let self else { return }
            switch event {
            case .messageStored(let record):
                let text = String(record.text.prefix(40))
                if record.direction == MessageDirection.incoming {
                    if record.kind == MessageKind.channel {
                        self.channelInbound += 1
                        self.lastChannelText = text
                    } else if record.kind == MessageKind.private {
                        self.privateInbound += 1
                        self.lastPrivateText = text
                    }
                }
            case .messageStatusChanged(_, let status):
                if status == MessageStatus.delivered { self.deliveredOutbound += 1 }
            case .verifyRequested:
                // Proves the tap-driven prompt path ran, which the message counters cannot.
                self.verifyPrompts += 1
            default:
                break
            }
        }
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
                + "\"mtu\":\(link.mtu),\"trust\":\(link.trustState),\"code\":\(code)}"
        }
        let line = "AIRCHAT_STATE {\"platform\":\"ios\","
            + "\"self\":\"\(state.deviceIdHex)\","
            + "\"status\":\"\(statusName(state.status))\","
            + "\"nearby\":\(state.nearby.count),"
            + "\"scanning\":\(state.scanning),"
            + "\"nearbyLabels\":["
            + state.nearby.map { "\"\(self.escaped($0.label))\"" }.joined(separator: ",")
            + "],"
            + "\"verifyPrompts\":\(verifyPrompts),"
            + "\"channel\":\(channelInbound),"
            + "\"private\":\(privateInbound),"
            + "\"delivered\":\(deliveredOutbound),"
            + "\"lastChannel\":\(quoted(lastChannelText)),"
            + "\"lastPrivate\":\(quoted(lastPrivateText)),"
            + "\"links\":[\(links.joined(separator: ","))]}\n"
        FileHandle.standardError.write(Data(line.utf8))
    }

    /// Escapes a value for embedding in the heartbeat JSON.
    private func escaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// The same value as a JSON string literal.
    private func quoted(_ value: String) -> String { "\"\(escaped(value))\"" }

    private func statusName(_ status: ChatStatus) -> String {
        switch status {
        case .stopped: return "stopped"
        case .idle: return "idle"
        case .bluetoothUnavailable: return "bluetoothunavailable"
        case .permissionMissing: return "permissionmissing"
        case .scanning: return "scanning"
        case .nearbyFull: return "nearbyfull"
        case .failed: return "failed"
        }
    }
}
