import CardLink
import CardProtocol
import CardService
import Foundation
import Library
import Observation

/// A card in the P03 list.
public struct CardCandidate: Identifiable, Equatable, Sendable {
    public var id: UUID
    /// "录音卡 ·· 3F2A": the last 4 hex digits of the advertised SID tell cards apart
    /// (product-spec.md P03). The Bluetooth name is not shown (CLAUDE.md rule 5).
    public var displayName: String
    public var battery: Int
    public var firmware: String
    /// Firmware outside the verified table: warn, still allow pairing (features.md X1).
    public var firmwareUnverified: Bool

    public init(_ card: DiscoveredCard) {
        id = card.id
        displayName = Self.name(sid: card.advertisement.sid)
        battery = card.advertisement.battery
        firmware = card.advertisement.firmware
        firmwareUnverified = Firmware.check(card.advertisement.firmware) != .verified
    }

    public static func name(sid: Int) -> String {
        "录音卡 ·· " + String(format: "%04X", sid & 0xFFFF)
    }
}

/// P03 scan and pair (product-spec.md §3.1, §4.2): scan → pick a card → connect → read
/// info → pair → done. Pairing is offline (prd.md §3).
@MainActor
@Observable
public final class PairingModel {
    public enum Step: Int, CaseIterable, Sendable {
        case connecting, readingInfo, pairing
    }

    public enum Phase: Equatable, Sendable {
        /// Looking for cards; the list may already have some.
        case scanning
        /// Nothing found within the scan timeout.
        case notFound
        case working(Step)
        case failed(Step, CardServiceError)
        /// Paired and saved; the value is the library's device id.
        case done(deviceId: UUID)
    }

    public private(set) var phase: Phase = .scanning
    /// Set while pairing waits for the user to confirm re-binding a card bonded elsewhere.
    public private(set) var rebindPending = false
    /// The card being connected or paired.
    public private(set) var selected: CardCandidate?

    public var candidates: [CardCandidate] { session.discovered.map(CardCandidate.init) }
    /// Bluetooth off or not allowed; the page shows this instead of the list.
    public var bluetoothProblem: CardServiceError? { session.bluetoothProblem }

    private let session: CardSession
    private let preferences: Preferences
    private let scanTimeout: Duration
    private let now: () -> Date
    @ObservationIgnored private var scanTimer: Task<Void, Never>?
    @ObservationIgnored private var rebindAnswer: CheckedContinuation<Bool, Never>?
    @ObservationIgnored private var listener: UUID?
    @ObservationIgnored private var started = false
    /// One pairing at a time: a second tap must not write a second bondId (prd.md §3).
    @ObservationIgnored private var pairTask: Task<Void, Never>?

    public init(session: CardSession, preferences: Preferences, scanTimeout: Duration = .seconds(15),
                now: @escaping () -> Date = Date.init) {
        self.session = session
        self.preferences = preferences
        self.scanTimeout = scanTimeout
        self.now = now
    }

    // MARK: - Scanning

    /// Called when the page appears. Scanning resumes by itself when Bluetooth comes back.
    public func start() {
        guard !started else { return }
        started = true
        listener = session.addListener { [weak self] event in
            if case .stateChanged(let state) = event { self?.linkStateChanged(state) }
        }
        scan()
    }

    /// Called when the page goes away: stop scanning, and drop a link that never finished pairing.
    public func stop() {
        started = false
        if let listener { session.removeListener(listener) }
        listener = nil
        scanTimer?.cancel()
        scanTimer = nil
        session.stopScan()
        if rebindPending { answerRebind(false) }
        // A pairing still under way must not write a bond or switch the card once the page is gone.
        pairTask?.cancel()
        if case .done = phase { return }
        if selected != nil { session.service.disconnect() }
    }

    /// "再试一次" after nothing was found, and "重试" back to the list.
    public func scan() {
        guard pairTask == nil else { return }
        selected = nil
        phase = .scanning
        scanTimer?.cancel()
        guard session.bluetoothProblem == nil else { return }
        // A card on the link that is not paired here (unpaired on P07 or elsewhere, a pairing given
        // up) does not advertise, so the scan would never find it. Not `session.disconnect()`: that
        // would also stop the home screen reconnecting once this card is paired.
        if session.linkState == .connected, session.connectedDevice == nil { session.service.disconnect() }
        session.startScan()
        let timeout = scanTimeout
        scanTimer = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled, let self, self.phase == .scanning, self.session.discovered.isEmpty else { return }
            self.session.stopScan()
            self.phase = .notFound
        }
    }

    private func linkStateChanged(_ state: LinkState) {
        guard phase == .scanning || phase == .notFound else { return }
        // Bluetooth is back on: CoreBluetooth drops scans while it is off, so start again.
        if state == .idle, session.bluetoothProblem == nil, phase == .scanning { scan() }
    }

    // MARK: - Pairing

    public func select(_ card: CardCandidate) {
        guard pairTask == nil else { return }
        scanTimer?.cancel()
        session.stopScan()
        selected = card
        startPairing(card)
    }

    /// "重试" on a failed step: starts over from connecting, on a fresh link.
    public func retry() {
        guard pairTask == nil else { return }
        guard let card = selected else { return scan() }
        startPairing(card)
    }

    private func startPairing(_ card: CardCandidate) {
        // Set before the task runs, so the list and the retry button are gone on the next frame.
        phase = .working(.connecting)
        pairTask = Task { [weak self] in
            let declined = await self?.pair(card) ?? false
            guard let self else { return }
            self.pairTask = nil
            // Declined re-binding: back to the list, if the page is still shown.
            if declined, self.started { self.scan() }
        }
    }

    public func answerRebind(_ yes: Bool) {
        rebindPending = false
        rebindAnswer?.resume(returning: yes)
        rebindAnswer = nil
    }

    /// Returns true when the user declined re-binding a card bonded elsewhere.
    private func pair(_ card: CardCandidate) async -> Bool {
        let service = session.service
        var step = Step.connecting
        do {
            try Task.checkCancellation()
            let info = try await service.connect(card.id)
            try Task.checkCancellation()

            step = .readingInfo
            phase = .working(.readingInfo)
            let alreadyPaired = try await service.isPairedWithThisPhone()
            try Task.checkCancellation()

            if !alreadyPaired {
                step = .pairing
                phase = .working(.pairing)
                _ = try await service.pair { [weak self] in
                    await withCheckedContinuation { c in
                        guard let self else { return c.resume(returning: false) }
                        self.rebindAnswer = c
                        self.rebindPending = true
                    }
                }
            }

            try Task.checkCancellation()
            let device = try save(card, info: service.lastInfo ?? info)
            preferences.currentDeviceId = device.id
            phase = .done(deviceId: device.id)
            session.diagnostics?.add("pair", alreadyPaired ? "already paired" : "paired")
            // The session holds back sync for unknown cards; this card is known now.
            session.refreshDevices()
        } catch is CancellationError {
            session.diagnostics?.add("pair", "left the page at \(step)")
            service.disconnect()
        } catch CardServiceError.pairCancelled {
            session.diagnostics?.add("pair", "re-bind declined")
            service.disconnect()
            return true
        } catch {
            session.diagnostics?.add("pair", "failed at \(step): \(error)")
            service.disconnect()
            phase = .failed(step, (error as? CardServiceError) ?? .bondStorageFailed)
        }
        return false
    }

    /// Writes the paired card to the library. A storage error is reported like a Keychain one.
    private func save(_ card: CardCandidate, info: DeviceInfo) throws -> Device {
        let peripheral = card.id.uuidString
        let seen = now()
        do {
            return try session.library.upsertDevice(sn: info.serial) { d in
                if d.name.isEmpty { d.name = card.displayName }
                d.firmware = info.firmware
                d.peripheralId = peripheral
                d.pairedAt = d.pairedAt ?? seen
                d.lastSeenAt = seen
                d.battery = info.battery
                d.freeMb = info.freeSpace
                d.totalMb = info.totalSpace
            }
        } catch {
            throw CardServiceError.bondStorageFailed
        }
    }
}
