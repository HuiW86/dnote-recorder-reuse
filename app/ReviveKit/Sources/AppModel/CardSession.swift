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
    /// Paired, not connected; a pending connect waits for the card to advertise. CoreBluetooth
    /// reports a pending connect as `.connecting` for as long as the card sleeps.
    case waiting
    /// On the link and still reading the card (0x80, 0x56).
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
    /// The user tapped "断开连接" on P07: no pending connect until they pull to refresh on P05 or
    /// reopen the app (product-spec.md P07).
    public private(set) var userDisconnected = false

    /// Whether a card deletes its files once stored (per card, set from Preferences). Applied to
    /// SyncEngine when the card connects.
    @ObservationIgnored public var deleteAfterSync: (UUID) -> Bool = { _ in false }

    /// Off while the DEBUG card screen is open, so its logs show only the requests it sends
    /// (evidence/v38-card-link). Syncs requested directly on `syncEngine` still run.
    public var autoSyncEnabled = true {
        didSet {
            // Turned back on after the card connected silently: catch up on what identify skipped.
            guard autoSyncEnabled, !oldValue, let device = connectedDevice else { return }
            Task { [weak self] in await self?.catchUp(device) }
        }
    }

    /// Exported from P09; nil in tests that do not check it.
    @ObservationIgnored public let diagnostics: DiagnosticLog?

    @ObservationIgnored private var listeners: [UUID: (CardEvent) -> Void] = [:]
    @ObservationIgnored private let now: () -> Date
    /// A recording command is waiting for its reply or for the `0x56` read after a timeout.
    @ObservationIgnored private var commandRunning = false
    /// Bumped on every recording state change, so a late fallback can tell it is stale.
    @ObservationIgnored private var stateRevision = 0
    /// Counts `0x80`s of the connected card; a newer one supersedes an older one's fallback.
    @ObservationIgnored private var deviceInfoCount = 0
    /// When the sync pass being logged started.
    @ObservationIgnored private var passStartedAt: Date?

    public init(link: any CardLink, bondStore: any BondStore, library: RecordingLibrary,
                timing: CardService.Timing = CardService.Timing(),
                syncOptions: SyncEngine.Options = SyncEngine.Options(),
                diagnostics: DiagnosticLog? = nil,
                now: @escaping () -> Date = Date.init) throws {
        service = CardService(link: link, bondStore: bondStore, timing: timing)
        syncEngine = try SyncEngine(service: service, library: library, options: syncOptions)
        self.library = library
        self.diagnostics = diagnostics
        self.now = now
        linkState = link.state
        pairedDevices = (try? library.pairedDevices()) ?? []
        // Each pass stamps the card's row; re-read only the list here, not `refreshDevices`,
        // which would also forget or identify the card on the link.
        syncEngine.onDeviceSaved = { [weak self] _ in
            guard let self else { return }
            self.pairedDevices = (try? self.library.pairedDevices()) ?? self.pairedDevices
        }
        let events = service.events
        Task { [weak self] in
            for await event in events { self?.handle(event) }
        }
        diagnostics?.add("app", "session started, \(pairedDevices.count) paired, link \(linkState)")
        if diagnostics != nil { observeSyncStatus() }
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
        // Connected but not named by its 0x80 yet. `.connecting` is not enough: it also covers a
        // pending connect to a sleeping card, which must read as waiting (press the card button).
        let onLink = connectedDevice == nil && service.peripheralId?.uuidString == device.peripheralId
        return linkState == .connected && onLink ? .connecting : .waiting
    }

    public func startScan() {
        discovered = []
        service.startScan()
    }

    public func stopScan() { service.stopScan() }

    /// Registers a pending connect to `device`, unless the link is busy with a card or already
    /// has one pending (registered by the link itself after a drop).
    public func connectWhenSeen(_ device: Device) throws {
        diagnostics?.add("link", "connect when seen, link \(linkState)")
        userDisconnected = false
        switch linkState {
        case .connecting, .connected, .disconnected(.lost): return
        default: break
        }
        guard let id = device.peripheralId.flatMap(UUID.init) else { throw CardServiceError.unknownCard }
        try service.connectWhenSeen(id)
    }

    /// Switching cards on P08: drop the card on the link (or the pending connect) and wait for
    /// `device` instead. `connectWhenSeen` would keep the old card, as it never replaces a link.
    public func switchTo(_ device: Device) throws {
        userDisconnected = false
        guard connectedDevice?.id != device.id else { return }
        guard let id = device.peripheralId.flatMap(UUID.init) else { throw CardServiceError.unknownCard }
        diagnostics?.add("link", "switch card, link \(linkState)")
        service.disconnect()
        try service.connectWhenSeen(id)
    }

    /// "断开连接" on P07.
    public func disconnect() {
        diagnostics?.add("link", "disconnect requested")
        userDisconnected = true
        service.disconnect()
    }

    /// Unbonds the connected card (`0xA0 [0]`, checked by `0xA1`), marks it unpaired and drops the
    /// link so it advertises again. Recordings on the card and on the phone are kept.
    public func unpair(_ device: Device) async throws {
        guard connectedDevice?.id == device.id else { throw CardServiceError.disconnected }
        try await service.unpair()
        diagnostics?.add("card", "unpaired")
        try library.markUnpaired(id: device.id)
        disconnect()
        refreshDevices()
    }

    /// Applies a change of the per-card "同步后删除" to the card on the link.
    public func deleteAfterSyncChanged(for deviceId: UUID) {
        guard connectedDevice?.id == deviceId else { return }
        syncEngine.options.deleteAfterSync = deleteAfterSync(deviceId)
    }

    /// Re-reads the paired cards, after pairing or unpairing. A card just paired on the link
    /// is then recognised: its recording state is read and its first sync starts.
    public func refreshDevices() {
        pairedDevices = (try? library.pairedDevices()) ?? []
        // Unpaired while on the link: stop treating it as a paired card (no more syncs).
        if let device = connectedDevice, !pairedDevices.contains(where: { $0.id == device.id }) { forgetCard() }
        if connectedDevice == nil, linkState == .connected, let info = service.lastInfo { identify(info) }
    }

    // MARK: - Recording control (prd.md §2.3)

    public func startRecording() async throws {
        try await recordingCommand {
            recordingName = try await service.startRecording()
            setRecording(.recording, ms: 0)
        }
    }

    public func pauseRecording() async throws {
        try await recordingCommand {
            try await service.pause()
            setRecording(.paused, ms: recordedMs.map { _ in elapsedMs(at: now()) })
            await readRecordingStatus()
        }
    }

    public func resumeRecording() async throws {
        try await recordingCommand {
            try await service.resume()
            setRecording(.recording, ms: recordedMs)
            await readRecordingStatus()
        }
    }

    public func stopRecording() async throws {
        try await recordingCommand {
            try await service.stopRecording()
            setRecording(.idle, ms: nil)
        }
    }

    /// Runs one recording command. A timeout may hide a command that took effect with only the
    /// reply lost, so `0x56` then decides the state (#47); the timeout is passed on only when
    /// `0x56` cannot be read either. The command is never sent again.
    private func recordingCommand(_ body: () async throws -> Void) async throws {
        commandRunning = true
        defer { commandRunning = false }
        do {
            try await body()
        } catch CardServiceError.requestTimeout(let command) {
            diagnostics?.add("card", "\(command) timed out, reading 0x56")
            // An unrecognised code says nothing about whether the command took effect.
            guard await readRecordingStatus(), !(recordingState?.isUnknown ?? true) else {
                throw CardServiceError.requestTimeout(command)
            }
            diagnostics?.add("card", "0x56 after timeout: \(recordingState.map { "\($0)" } ?? "none")")
        }
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
            diagnostics?.add("link", "state \(state)")
            linkState = state
            if state != .connected { forgetCard() }
        case .disconnected(let reason):
            diagnostics?.add("link", "disconnected: \(reason)")
            linkState = .disconnected(reason)
            forgetCard()
        case .deviceInfo(let info):
            if connectedDevice == nil, linkState == .connected {
                identify(info)
            } else if connectedDevice != nil {
                cardInfo = info
                deviceInfoCount += 1
                correctRecordingState(info.recordingState)
            }
        case .recordingStarted(let name):
            diagnostics?.add("card", "recording started \(name)")
            if connectedDevice != nil {
                recordingName = name
                setRecording(.recording, ms: 0)
            }
        case .recordingStopped:
            diagnostics?.add("card", "recording stopped")
            if connectedDevice != nil { setRecording(.idle, ms: nil) }
        case .firmwareUnverified(let version):
            diagnostics?.add("card", "firmware \(version) not verified")
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
        // Not logged for an unpaired card: its periodic 0x80 would repeat the line; pairing logs its own.
        guard let device = pairedDevices.first(where: { $0.sn == info.serial }) else { return }
        diagnostics?.add("card", "paired card on the link: \(DiagnosticLog.describe(info))")
        connectedDevice = device
        // A paired card is on the link again (re-paired on P03): the P07 disconnect is over.
        userDisconnected = false
        cardInfo = info
        syncEngine.options.deleteAfterSync = deleteAfterSync(device.id)
        // 0x80 carries the recording state too; 0x56 then adds recd. Without this, a failed 0x56
        // would leave the card showing as connecting with recording disabled until a reconnect.
        if case .unknown = info.recordingState {} else { setRecording(info.recordingState, ms: nil) }
        // The DEBUG card screen sends its own requests; stay silent while it is open.
        guard autoSyncEnabled else { return }
        Task { [weak self] in await self?.catchUp(device) }
    }

    /// Logs each sync pass: when it starts, how it ends and how long it took.
    private func observeSyncStatus() {
        withObservationTracking { _ = syncEngine.status } onChange: {
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.logSyncStatus(self.syncEngine.status)
                self.observeSyncStatus()
            }
        }
    }

    private func logSyncStatus(_ status: SyncStatus) {
        switch status {
        case .syncing:
            // One line per pass, not per chunk.
            guard passStartedAt == nil else { return }
            passStartedAt = now()
            diagnostics?.add("sync", "downloading, \(syncEngine.pendingCount) pending")
        default:
            let took = passStartedAt.map { String(format: " after %.1f s", now().timeIntervalSince($0)) } ?? ""
            passStartedAt = nil
            let failures = syncEngine.failures
            diagnostics?.add("sync", "\(status)\(took), failures retryable \(failures.retryable) "
                + "undecryptable \(failures.undecryptable)")
        }
    }

    private func catchUp(_ device: Device) async {
        await readRecordingStatus()
        guard autoSyncEnabled, connectedDevice?.id == device.id else { return }
        syncEngine.requestSync()
    }

    private func forgetCard() {
        stateRevision += 1
        connectedDevice = nil
        cardInfo = nil
        recordingName = nil
        recordingState = nil
        recordedMs = nil
        recordedAt = nil
    }

    /// Reads `0x56` and applies it; false when the card did not answer or has left the link.
    /// The answer may be handled after a newer push (a button press): when the state changed
    /// during the read, it is dropped, and so it is when a command started if asked (still true,
    /// the card did answer).
    @discardableResult
    private func readRecordingStatus(droppedIfCommandStarts: Bool = false) async -> Bool {
        let revision = stateRevision
        guard let status = try? await service.recordingStatus(), connectedDevice != nil else { return false }
        if stateRevision != revision || droppedIfCommandStarts && commandRunning { return true }
        // Without `recd`, keep counting locally rather than dropping the timer.
        let ms = status.recordedMs ?? recordedMs.map { _ in elapsedMs(at: now()) }
        if !status.name.isEmpty { recordingName = status.name }
        let stopped = isActive && status.state == .idle
        setRecording(status.state, ms: status.state == .idle ? nil : ms)
        if stopped { syncAfterRecoveredStop() }
        return true
    }

    /// A later `0x80` (polled or the periodic push) that disagrees with the recording state,
    /// e.g. after a command timeout that `0x56` could not settle (#47). Its event may be handled
    /// after a newer command reply, so `0x56` decides; the `0x80` state only when that fails.
    /// Not while the DEBUG card screen is open: it sends its own requests only.
    private func correctRecordingState(_ state: RecordingState) {
        guard autoSyncEnabled, !commandRunning, state != recordingState, !state.isUnknown else { return }
        diagnostics?.add("card", "0x80 says \(state), reading 0x56")
        let revision = stateRevision, infoCount = deviceInfoCount
        Task { [weak self] in
            // Anything newer that arrived during the read (a push, a command) beats this 0x80.
            guard let self, await !self.readRecordingStatus(droppedIfCommandStarts: true),
                  self.stateRevision == revision, self.deviceInfoCount == infoCount,
                  !self.commandRunning else { return }
            let stopped = self.isActive && state == .idle
            self.setRecording(state, ms: state == .idle ? nil : self.recordedMs.map { _ in self.elapsedMs(at: self.now()) })
            if stopped { self.syncAfterRecoveredStop() }
        }
    }

    private var isActive: Bool { recordingState != nil && recordingState != .idle }

    /// A stop found by reading the state instead of from the card's `0x56`/`0x55` pushes: those
    /// are what start the sync after recording, so start it here.
    private func syncAfterRecoveredStop() {
        diagnostics?.add("card", "stop found without its push, syncing")
        guard autoSyncEnabled, connectedDevice != nil else { return }
        syncEngine.requestSync()
    }

    private func setRecording(_ state: RecordingState, ms: Int?) {
        stateRevision += 1
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

private extension RecordingState {
    var isUnknown: Bool {
        if case .unknown = self { true } else { false }
    }
}
