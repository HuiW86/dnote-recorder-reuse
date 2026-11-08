import CardLink
import CardProtocol
import CardService
import Foundation
import Library
import Observation
import SyncEngine

/// One Bluetooth stack for the whole app: owns CardService and SyncEngine, consumes
/// `CardService.events` (single consumer) and re-publishes what the screens need.
@MainActor
@Observable
public final class CardSession {
    public let service: CardService
    public let syncEngine: SyncEngine
    public let library: RecordingLibrary
    public private(set) var linkState: LinkState
    /// Cards seen since the last `startScan`, in order of discovery.
    public private(set) var discovered: [DiscoveredCard] = []

    /// Off while the DEBUG card screen is open, so its logs show only the requests it sends
    /// (evidence/v38-card-link). Syncs requested directly on `syncEngine` still run.
    public var autoSyncEnabled = true

    @ObservationIgnored private var listeners: [UUID: (CardEvent) -> Void] = [:]

    public init(link: any CardLink, bondStore: any BondStore, library: RecordingLibrary,
                timing: CardService.Timing = CardService.Timing(),
                syncOptions: SyncEngine.Options = SyncEngine.Options()) throws {
        service = CardService(link: link, bondStore: bondStore, timing: timing)
        syncEngine = try SyncEngine(service: service, library: library, options: syncOptions)
        self.library = library
        linkState = link.state
        let events = service.events
        Task { [weak self] in
            for await event in events { self?.handle(event) }
        }
    }

    /// Bluetooth itself is unusable (off, no permission, unsupported); nil when it is on.
    public var bluetoothProblem: CardServiceError? {
        switch linkState {
        case .poweredOff: .bluetoothOff
        case .unauthorized: .bluetoothUnauthorized
        case .unsupported: .bluetoothUnsupported
        default: nil
        }
    }

    public func startScan() {
        discovered = []
        service.startScan()
    }

    public func stopScan() { service.stopScan() }

    /// Every CardEvent, after the session has applied it. Returns a token for `removeListener`.
    @discardableResult
    public func addListener(_ listener: @escaping (CardEvent) -> Void) -> UUID {
        let token = UUID()
        listeners[token] = listener
        return token
    }

    public func removeListener(_ token: UUID) { listeners[token] = nil }

    // MARK: - Events

    private func handle(_ event: CardEvent) {
        switch event {
        case .discovered(let card):
            if let i = discovered.firstIndex(where: { $0.id == card.id }) {
                discovered[i] = card
            } else {
                discovered.append(card)
            }
        case .stateChanged(let state):
            linkState = state
        case .disconnected(let reason):
            linkState = .disconnected(reason)
        default:
            break
        }
        // A card being paired is not in the library yet: its first sync starts when pairing
        // completes, not on connect. SyncEngine also checks 0xA1 itself, because an unpaired
        // card still serves files (#38 E).
        if autoSyncEnabled, isPairedCardConnected { syncEngine.handle(event) }
        for listener in listeners.values { listener(event) }
    }

    private var isPairedCardConnected: Bool {
        guard let id = service.peripheralId?.uuidString,
              let devices = try? library.pairedDevices() else { return false }
        return devices.contains { $0.peripheralId == id }
    }
}
