import CardProtocol
import Foundation

/// A link with no Bluetooth behind it: never scans, never connects, never writes.
///
/// For 先不连卡 (product-spec.md P01): someone without a card uses the app's tabs (phone
/// recording, import, transcripts) before iOS has been asked about Bluetooth. Creating
/// `BluetoothCardLink` creates a `CBCentralManager`, which shows the permission prompt; this
/// link does not, so the prompt still comes only after P01 has said what it is for. Also the
/// card of the DEBUG demo library (screenshots).
@MainActor
public final class NoCardLink: CardLink {
    /// Ready and idle, so a session over it reads as "no card", not as Bluetooth off.
    public let state: LinkState = .idle
    public let peripheralId: UUID? = nil
    public let events: AsyncStream<LinkEvent>
    private let continuation: AsyncStream<LinkEvent>.Continuation

    public init() {
        let pair = AsyncStream<LinkEvent>.makeStream()
        events = pair.stream
        continuation = pair.continuation
    }

    public func startScan() {}
    public func stopScan() {}
    public func connect(_ id: UUID) async throws { throw LinkError.connectFailed }
    public func connectWhenSeen(_ id: UUID) throws {}
    public func disconnect() {}
    public func send(_ request: CardRequest) async throws { throw LinkError.notConnected }
}
