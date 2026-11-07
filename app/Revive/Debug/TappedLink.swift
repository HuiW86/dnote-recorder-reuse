#if DEBUG
import CardLink
import CardProtocol
import Foundation

/// Passes everything through to the real link and logs each frame, redacted, so the
/// replies assumed in test-spec.md §2 can be checked against the card.
@MainActor
final class TappedLink: CardLink {
    let events: AsyncStream<LinkEvent>
    var state: LinkState { inner.state }
    var peripheralId: UUID? { inner.peripheralId }

    private let inner: any CardLink
    private let log: DebugLog

    init(_ inner: any CardLink, log: DebugLog) {
        self.inner = inner
        self.log = log
        let (stream, continuation) = AsyncStream.makeStream(of: LinkEvent.self)
        events = stream
        let innerEvents = inner.events
        Task { @MainActor in
            for await event in innerEvents {
                switch event {
                case .notification(let data): log.add("rx " + Redactor.describe(data, .rx))
                case .state(let s): log.add("link \(s)")
                case .discovered: break
                }
                continuation.yield(event)
            }
            continuation.finish()
        }
    }

    func startScan() { inner.startScan() }
    func stopScan() { inner.stopScan() }
    func connect(_ id: UUID) async throws { try await inner.connect(id) }
    func connectWhenSeen(_ id: UUID) throws { try inner.connectWhenSeen(id) }
    func disconnect() { inner.disconnect() }

    func send(_ request: CardRequest) async throws {
        log.add("tx " + Redactor.describe(try request.encode(), .tx))
        try await inner.send(request)
    }
}
#endif
