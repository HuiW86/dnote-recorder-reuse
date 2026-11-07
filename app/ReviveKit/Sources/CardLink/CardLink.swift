import CardProtocol
import Foundation

// Transport contract (prd.md §2.1). `BluetoothCardLink` talks to a real card; the fake
// card in CardTestSupport implements the same protocol for integration tests.

public enum LinkState: Equatable, Sendable {
    case poweredOff
    case unauthorized
    /// Bluetooth LE unavailable on this device, or still resetting.
    case unsupported
    case idle
    case connecting
    case connected
    case disconnected(DisconnectReason)
}

public enum DisconnectReason: Equatable, Sendable {
    /// `disconnect()` was called; no pending reconnect.
    case requested
    /// Link dropped; a pending connect has been registered (`connectWhenSeen`).
    case lost
}

public enum LinkError: Error, Equatable, Sendable {
    case bluetoothOff
    case bluetoothUnauthorized
    case bluetoothUnsupported
    case connectTimeout
    case connectFailed
    case notConnected
    /// The peripheral id is not known to the system (never seen, or Bluetooth was reset).
    case unknownPeripheral
    case writeFailed
}

public struct DiscoveredCard: Equatable, Sendable {
    public var id: UUID
    public var name: String?
    public var advertisement: Advertisement
    public var rssi: Int

    public init(id: UUID, name: String?, advertisement: Advertisement, rssi: Int) {
        self.id = id
        self.name = name
        self.advertisement = advertisement
        self.rssi = rssi
    }
}

public enum LinkEvent: Equatable, Sendable {
    case state(LinkState)
    case discovered(DiscoveredCard)
    /// A raw notification from characteristic 6003, in arrival order.
    case notification(Data)
}

@MainActor
public protocol CardLink: AnyObject {
    var state: LinkState { get }
    /// Id of the connected (or pending) card.
    var peripheralId: UUID? { get }
    /// All link events. Single consumer: CardService owns the link and re-publishes.
    var events: AsyncStream<LinkEvent> { get }

    /// Scans for cards by manufacturer company ID 0x22A3 (foreground only: the card's
    /// advertisement carries no service UUID, so background scans cannot find it, H6).
    func startScan()
    func stopScan()
    /// Connects, discovers service 6001 and subscribes to 6003; times out after 10 s.
    func connect(_ id: UUID) async throws
    /// Pending connect: the system connects whenever the card advertises again, also in
    /// the background. Registered automatically after an unexpected drop.
    func connectWhenSeen(_ id: UUID) throws
    /// Disconnects without registering a pending connect.
    func disconnect()
    /// Writes one frame with response. Only whitelisted requests can be expressed.
    func send(_ request: CardRequest) async throws
}

public enum CardLinkTiming {
    public static let connectTimeout: Duration = .seconds(10)
}
