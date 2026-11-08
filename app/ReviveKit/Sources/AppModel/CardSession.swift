import CardLink
import CardProtocol
import CardService
import Foundation
import Library
import Observation
import SyncEngine

/// Device state as the screens see it (product-spec.md §5.1).
public enum DeviceStatus: Equatable, Sendable {
    case noDevice
    /// Paired, not connected; a pending connect waits for the card to advertise.
    case waiting
    /// Connecting, or connected and still reading the card.
    case connecting
    case idle
    case recording
    case paused
    /// Bluetooth off, not authorized or unsupported; overrides everything else.
    case bluetoothUnavailable
}

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
    /// Cards paired from this phone, oldest first (`Library.pairedDevices`).
    public private(set) var pairedDevices: [Device] = []
    /// The paired card on the link, known once its `0x80` names it; nil for an unpaired card.
    public private(set) var connectedDevice: Device?
    /// Recording state of `connectedDevice`; nil until `0x56` has been read after connecting.
    public private(set) var recordingState: RecordingState?
    /// Card file being recorded (`YYYYMMDDHHmmss.opus`), when the card has named it.
    public private(set) var recordingName: String?
    /// Latest `0x80` of `connectedDevice`: battery and card storage for the home screen.
    public private(set) var cardInfo: DeviceInfo?
    /// Recorded time as of `recordedAt`: the card's `recd`, advanced locally while recording
    /// (product-spec.md P05 RecordingStatusCard). Nil when not known yet.
    public private(set) var recordedMs: Int?
    public private(set) var recordedAt: Date?

    /// Off while the DEBUG card screen is open, so its logs show only the requests it sends
    /// (evidence/v38-card-link). Syncs requested directly on `syncEngine` still run.
    public var autoSyncEnabled = true

    @ObservationIgnored private var listeners: [UUID: (CardEvent) -> Void] = [:]
    @ObservationIgnored private let now: () -> Date

    public init(link: any CardLink, bondStore: any BondStore, library: RecordingLibrary,
                timing: CardService.Timing = CardService.Timing(),
                syncOptions: SyncEngine.Options = SyncEngine.Options(),
                now: @escaping () -> Date = Date.init) throws {
        service = CardService(link: link, bondStore: bondStore, timing: timing)
        syncEngine = try SyncEngine(service: service, library: library, options: syncOptions)
        self.library = library
        self.now = now
        linkState = link.state
        pairedDevices = (try? library.pairedDevices()) ?? []
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

    /// State of one paired card (product-spec.md §5.1); `noDevice` for nil or an unknown id.
    public func status(of deviceId: UUID?) -> DeviceStatus {
        if bluetoothProblem != nil { return .bluetoothUnavailable }
        guard let device = pairedDevices.first(where: { $0.id == deviceId }) else { return .noDevice }
        if connectedDevice?.id == device.id {
            switch recordingState {
            case .idle?: return .idle
            case .recording?: return .recording
            case .paused?: return .paused
            // An unknown code means recording in some form; treat it as such, never as idle.
            case .unknown?: return .recording
            case nil: return .connecting
            }
        }
        let onLink = connectedDevice == nil && service.peripheralId?.uuidString == device.peripheralId
        switch linkState {
        case .connecting where onLink, .connected where onLink: return .connecting
        default: return .waiting
        }
    }

    public func startScan() {
        discovered = []
        service.startScan()
    }

    public func stopScan() { service.stopScan() }

    /// Registers a pending connect to `device`, unless the link is busy with a card or already
    /// has one pending (registered by the link itself after a drop).
    public func connectWhenSeen(_ device: Device) throws {
        switch linkState {
        case .connecting, .connected, .disconnected(.lost): return
        default: break
        }
        guard let id = device.peripheralId.flatMap(UUID.init) else { throw CardServiceError.unknownCard }
        try service.connectWhenSeen(id)
    }

    /// Re-reads the paired cards, after pairing or unpairing. A card just paired on the link
    /// is then recognised: its recording state is read and its first sync starts.
    public func refreshDevices() {
        pairedDevices = (try? library.pairedDevices()) ?? []
        if connectedDevice == nil, linkState == .connected, let info = service.lastInfo { identify(info) }
    }

    // MARK: - Recording control (prd.md §2.3)

    public func startRecording() async throws {
        recordingName = try await service.startRecording()
        setRecording(.recording, ms: 0)
    }

    public func pauseRecording() async throws {
        try await service.pause()
        setRecording(.paused, ms: recordedMs.map { _ in elapsedMs(at: now()) })
        await readRecordingStatus()
    }

    public func resumeRecording() async throws {
        try await service.resume()
        setRecording(.recording, ms: recordedMs)
        await readRecordingStatus()
    }

    public func stopRecording() async throws {
        try await service.stopRecording()
        setRecording(.idle, ms: nil)
    }

    /// Recorded milliseconds at `date`, counting on from the last `recd` while recording.
    public func recordedMs(at date: Date) -> Int? {
        recordedMs == nil ? nil : elapsedMs(at: date)
    }

    // MARK: - Listeners

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
            if state != .connected { forgetCard() }
        case .disconnected(let reason):
            linkState = .disconnected(reason)
            forgetCard()
        case .deviceInfo(let info):
            if connectedDevice == nil, linkState == .connected { identify(info) }
            if connectedDevice != nil { cardInfo = info }
        case .recordingStarted(let name):
            if connectedDevice != nil {
                recordingName = name
                setRecording(.recording, ms: 0)
            }
        case .recordingStopped:
            if connectedDevice != nil { setRecording(.idle, ms: nil) }
        default:
            break
        }
        // Only a paired card is synced: one being paired is not in the library yet, and its
        // first sync starts from `refreshDevices`. Connects reach SyncEngine through `identify`,
        // once the card's 0x80 has named it (#38 E: an unpaired card still serves files, so
        // SyncEngine checks 0xA1 itself too).
        if autoSyncEnabled, connectedDevice != nil { syncEngine.handle(event) }
        for listener in listeners.values { listener(event) }
    }

    /// The first `0x80` after connecting names the card: match it to a paired one by serial,
    /// since a peripheral id can change (another phone, Bluetooth reset).
    private func identify(_ info: DeviceInfo) {
        guard let device = pairedDevices.first(where: { $0.sn == info.serial }) else { return }
        connectedDevice = device
        cardInfo = info
        // The DEBUG card screen sends its own requests; stay silent while it is open.
        guard autoSyncEnabled else { return }
        Task { [weak self] in
            await self?.readRecordingStatus()
            guard let self, self.autoSyncEnabled, self.connectedDevice?.id == device.id else { return }
            self.syncEngine.requestSync()
        }
    }

    private func forgetCard() {
        connectedDevice = nil
        cardInfo = nil
        recordingName = nil
        recordingState = nil
        recordedMs = nil
        recordedAt = nil
    }

    private func readRecordingStatus() async {
        guard let status = try? await service.recordingStatus(), connectedDevice != nil else { return }
        // Without `recd`, keep counting locally rather than dropping the timer.
        let ms = status.recordedMs ?? recordedMs.map { _ in elapsedMs(at: now()) }
        if !status.name.isEmpty { recordingName = status.name }
        setRecording(status.state, ms: status.state == .idle ? nil : ms)
    }

    private func setRecording(_ state: RecordingState, ms: Int?) {
        if state == .idle { recordingName = nil }
        recordingState = state
        recordedMs = ms
        recordedAt = ms == nil ? nil : now()
    }

    private func elapsedMs(at date: Date) -> Int {
        let base = recordedMs ?? 0
        guard recordingState == .recording, let since = recordedAt else { return base }
        return base + max(0, Int(date.timeIntervalSince(since) * 1000))
    }
}
