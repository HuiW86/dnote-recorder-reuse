import CardLink
import CardProtocol
import CardService
import Foundation
import Library
import Observation
import Player
import SyncEngine

/// A short message shown on top for 2 s; a new one replaces the old (product-spec.md §6).
public struct Toast: Equatable, Identifiable, Sendable {
    public let id = UUID()
    public let text: String

    public init(_ text: String) { self.text = text }
}

/// Home screen state: recording list, device status, sync card and recording control
/// (product-spec.md P05, P04).
@MainActor
@Observable
public final class HomeModel {
    public enum Command: Equatable, Sendable {
        case start, pause, resume, stop
    }

    public let session: CardSession
    /// Newest first.
    public private(set) var recordings: [Recording] = []
    /// The library could not be read (product-spec.md §4.3 P05 error state).
    public private(set) var loadError: String?
    /// The recording command waiting for the card's reply; other controls are disabled meanwhile.
    public private(set) var pendingCommand: Command?
    public var toast: Toast?
    /// P04 is shown before the first recording started from the app.
    public var showsConsent = false

    @ObservationIgnored private let preferences: Preferences
    @ObservationIgnored private let player: RecordingPlayer?
    @ObservationIgnored private var observation: LibraryObservation?
    @ObservationIgnored private var listener: UUID?

    public init(session: CardSession, preferences: Preferences, player: RecordingPlayer? = nil) {
        self.session = session
        self.preferences = preferences
        self.player = player
    }

    /// Starts watching the library and asks for the current card to reconnect.
    public func start() {
        if observation == nil {
            observation = session.library.observeRecordings(
                onError: { [weak self] in self?.loadError = String(describing: $0) },
                onChange: { [weak self] in
                    self?.recordings = $0
                    self?.loadError = nil
                })
        }
        if listener == nil {
            listener = session.addListener { [weak self] event in
                // Bluetooth back on: CoreBluetooth forgot the pending connect, so register it again.
                if event == .stateChanged(.idle) { self?.reconnect() }
            }
        }
        reconnect()
    }

    public func stop() {
        observation?.cancel()
        observation = nil
        if let listener { session.removeListener(listener) }
        listener = nil
    }

    // MARK: - Device

    /// The card the home screen is about (product-spec.md §4.4).
    public var currentDevice: Device? {
        let paired = session.pairedDevices
        return paired.first { $0.id == preferences.currentDeviceId } ?? paired.first
    }

    public var status: DeviceStatus { session.status(of: currentDevice?.id) }

    /// Battery in percent while the current card is connected.
    public var battery: Int? {
        session.connectedDevice?.id == currentDevice?.id ? session.cardInfo?.battery : nil
    }

    // MARK: - Sync

    public var syncCard: SyncCard? {
        let engine = session.syncEngine
        let connected = session.connectedDevice != nil && session.connectedDevice?.id == currentDevice?.id
        var input = SyncCard.Input(connected: connected, status: engine.status, isRunning: engine.isRunning,
                                   progress: engine.progress, pendingCount: engine.pendingCount,
                                   lastCompletedAt: engine.lastCompletedAt,
                                   cardFree: session.cardInfo?.freeSpace, cardTotal: session.cardInfo?.totalSpace,
                                   deleteAfterSync: engine.options.deleteAfterSync)
        // Failures only between passes; during a pass the card shows progress anyway.
        if connected, engine.status == .idle, !engine.isRunning { input.failures = engine.failures }
        return SyncCard.make(input)
    }

    /// Pull to refresh (product-spec.md P05).
    public func refresh() async {
        // After "断开连接" on P07, pulling down is how the user asks to connect again.
        if status == .waiting, session.userDisconnected {
            reconnect(force: true)
            return
        }
        guard status == .idle || status == .recording || status == .paused else {
            toast = Toast("录音卡未连接")
            return
        }
        await session.syncEngine.syncNow()
    }

    public func retrySync() { session.syncEngine.requestSync() }

    // MARK: - Recording control

    /// Recorded seconds at `date` while recording or paused; nil until the card has reported it.
    public func recordedSeconds(at date: Date) -> Int? {
        session.recordedMs(at: date).map { $0 / 1000 }
    }

    /// When the current recording started, from the card's file name.
    public var recordingStartedAt: Date? {
        session.recordingName.flatMap { SyncEngine.startDate(fileName: $0) }
    }

    public func startTapped() {
        if preferences.recordingConsentGiven {
            run(.start)
        } else {
            showsConsent = true
        }
    }

    /// "开始录音" on P04, after ticking the consent box.
    public func consentConfirmed() {
        preferences.recordingConsentGiven = true
        showsConsent = false
        run(.start)
    }

    public func pause() { run(.pause) }
    public func resume() { run(.resume) }
    public func stopRecording() { run(.stop) }

    private func run(_ command: Command) {
        guard pendingCommand == nil else { return }
        pendingCommand = command
        Task {
            defer { pendingCommand = nil }
            do {
                switch command {
                case .start: try await session.startRecording()
                case .pause: try await session.pauseRecording()
                case .resume: try await session.resumeRecording()
                case .stop: try await session.stopRecording()
                }
            } catch {
                let text = (error as? CardServiceError)?.userText ?? "操作失败，请重试"
                toast = Toast(text)
            }
        }
    }

    // MARK: - Recordings

    /// Deletes the local recording only; nothing is sent to the card (product-spec.md §3.3).
    public func delete(_ id: UUID) {
        if player?.recordingId == id { player?.stop() }
        do {
            try session.library.deleteRecording(id: id)
            toast = Toast("已删除")
        } catch {
            toast = Toast("删除失败，请重试")
        }
    }

    /// Card name for list rows; only shown when more than one card is paired.
    public func deviceName(for recording: Recording) -> String? {
        let paired = session.pairedDevices
        guard paired.count > 1 else { return nil }
        return paired.first { $0.id == recording.deviceId }?.name
    }

    // MARK: - Reconnect

    private func reconnect(force: Bool = false) {
        guard let device = currentDevice, status == .waiting, force || !session.userDisconnected else { return }
        do {
            try session.connectWhenSeen(device)
        } catch {
            toast = Toast((error as? CardServiceError)?.userText ?? "找不到这张录音卡，请重新搜索")
        }
    }
}
