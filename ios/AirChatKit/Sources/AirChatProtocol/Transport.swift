import Foundation

/// One established BLE GATT connection, seen from the local side.
///
/// Implemented by `AirChatBLE`. The session layer only needs framed byte transport plus the link
/// metadata, which keeps it testable with a fake.
public protocol Link: AnyObject {
    /// Stable identifier for this specific connection attempt (not the peer deviceId).
    var linkId: String { get }

    /// True when the local side initiated the GATT connection (the handshake initiator).
    var isCentral: Bool { get }

    /// Negotiated ATT MTU. `AirChatProtocol.defaultMtu` until the MTU exchange completes.
    var mtu: Int { get }

    /// Platform peer handle for diagnostics (CoreBluetooth identifier or BLE address).
    var peerLabel: String? { get }

    /// Queues `bytes` on the control channel when `control` is true, otherwise on the data
    /// channel. Returns false when the link is closed or its queue is saturated.
    ///
    /// Contract: implementations must not discard bytes that arrive before
    /// `setInboundHandler(_:)` is called; they queue them and flush once the handler is set.
    func send(_ bytes: Data, control: Bool) -> Bool

    /// Registers the single consumer for inbound bytes.
    func setInboundHandler(_ handler: @escaping (Data) -> Void)

    func close()
}

public enum TransportEvent {
    case linkOpened(Link)
    case linkClosed(linkId: String, reason: String)
    /// A peer is advertising nearby. Purely informational; authoritative data comes from HELLO.
    case peerSeen(peerLabel: String, protocolVersion: Int, capabilities: Int, ticket: Int, rssi: Int?)
    case peerLost(peerLabel: String)
    case status(ChatStatus, String)
}

/// Platform BLE transport. Owns advertising, scanning, connection management and the GATT server
/// (peripheral role), and applies the connection-direction and link-cap rules from
/// `docs/protocol.md` sections 5.3 to 5.5.
///
/// Events are delivered on the transport's own serial queue; the node hops them onto its queue.
public protocol Transport: AnyObject {
    /// Random 16-bit connect ticket currently advertised (protocol section 5.3).
    var ticket: Int { get }

    func start()
    func stop()

    /// Refreshes the presence block carried in the advertising packet.
    func updatePresence(protocolVersion: Int, capabilities: Int)

    /// Connection explicitly asked for by the user, for the peer advertising under `peerLabel`.
    ///
    /// Bypasses the connection-direction policy (protocol section 5.3) because the user outranks
    /// the ticket comparison, but not the link cap or the reconnect backoff. Outcomes are reported
    /// through state rather than a return value: a link for that peer appearing (or not) is the
    /// only truthful signal early enough to be useful.
    func connectTo(peerLabel: String)

    /// Registers the event consumer. Called once, before `start()`.
    func setEventHandler(_ handler: @escaping (TransportEvent) -> Void)
}
