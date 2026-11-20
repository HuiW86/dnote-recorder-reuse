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
    /// Title of a button on the toast ("撤销"); nil for a plain message.
    public let action: String?

    public init(_ text: String, action: String? = nil) {
        self.text = text
        self.action = action
    }
}

/// An error the user has to act on, shown as a Modal (product-spec.md §7.1).
public enum HomePrompt: Equatable, Sendable {
    /// `notPaired`: "重新配对" → P03.
    case repair
    /// `unknownCard`: "重新搜索" → P02.
    case rescan

    public var title: String {
        switch self {
        case .repair: CardServiceError.notPaired.userText ?? ""
        case .rescan: CardServiceError.unknownCard.userText ?? ""
        }
    }

    public var message: String { "卡上的录音和已同步到手机的录音都会保留。" }

    public var actionTitle: String {
        switch self {
        case .repair: "重新配对"
        case .rescan: "重新搜索"
        }
    }
}

/// One card on P08 (product-spec.md P08).
public struct DeviceRow: Equatable, Identifiable, Sendable {
    public let id: UUID
    public let name: String
    public let isCurrent: Bool
    public let status: DeviceStatus
    /// When a sync last reached the card (`Device.lastSeenAt`).
    public let lastSeenAt: Date?
    /// When a sync last finished on the card (`Device.lastSyncedAt`).
    public let lastSyncedAt: Date?

    /// "已连接 · 上次同步 11月7日 14:02" on P08: the last finished sync, else the last time a
    /// sync reached the card, else the state alone.
    public var subtitle: String {
        let state = switch status {
        case .connecting: "正在连接"
        case .idle: "已连接"
        case .recording: "录音中"
        case .paused: "已暂停"
        default: "未连接"
        }
        if let synced = lastSyncedAt { return "\(state) · 上次同步 \(RecordingText.dateTime(synced))" }
        if let seen = lastSeenAt { return "\(state) · 上次连接 \(RecordingText.dateTime(seen))" }
        return state
    }
}

/// Switching away from a card that is busy asks first (product-spec.md §3.3, §5.3).
public struct PendingSwitch: Equatable, Sendable {
    public enum Reason: Equatable, Sendable {
        case recording, syncing
    }

    public let deviceId: UUID
    public let reason: Reason

    public var title: String { "切换到另一张卡？" }

    public var message: String {
        switch reason {
        case .recording: "卡会继续录音，切回来后再同步。"
        case .syncing: "同步会在下次连接时继续。"
        }
    }
}

/// Home screen state: recording list, device status, sync card and recording control
/// (product-spec.md P05, P04).
@MainActor
@Observable
public final class HomeModel {
    public enum Command: Equatable, Sendable {
        case start, pause, resume, stop

        /// Whether the card is where this command takes it.
        func isReached(by status: DeviceStatus) -> Bool {
            switch self {
            case .start, .resume: status == .recording
            case .pause: status == .paused
            case .stop: status == .idle
            }
        }
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
    public var prompt: HomePrompt?
    /// The recording that just ended, while "留着 / 不要" is offered (features.md X10).
    public private(set) var justRecorded: FinishedRecording?

    @ObservationIgnored private let preferences: Preferences
    @ObservationIgnored private let player: RecordingPlayer?
    @ObservationIgnored private var observation: LibraryObservation?
    @ObservationIgnored private var listener: UUID?
    /// The recording the last delete moved to 最近删除, for "撤销".
    @ObservationIgnored private var lastTrashed: UUID?
    /// The recording "不要" was last chosen for, for "撤销".
    @ObservationIgnored private var lastDiscarded: FinishedRecording?
    @ObservationIgnored private var offerTask: Task<Void, Never>?
    /// How long "留着 / 不要" stays before the recording is simply kept.
    @ObservationIgnored public var keepOfferDuration: Duration = .seconds(10)
    /// The live sync status watch; an older one stops at its next change.
    @ObservationIgnored private var syncWatch: UUID?

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
                // Bluetooth is ready and there is no connection to restore. Connect the selected card.
                if event == .stateChanged(.idle) { self?.reconnect() }
            }
            let watch = UUID()
            syncWatch = watch
            observeSyncStatus(watch)
            observeFinished(watch)
        }
        reconnect()
    }

    public func stop() {
        observation?.cancel()
        observation = nil
        if let listener { session.removeListener(listener) }
        listener = nil
        syncWatch = nil
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

    // MARK: - Switch cards (P08)

    public var pendingSwitch: PendingSwitch?
    /// `unknownCard` while switching, shown on P08 itself: home cannot present a Modal while
    /// the sheet is up (product-spec.md §7.1, P08).
    public var switcherPrompt: HomePrompt?

    /// Paired cards, oldest first, from the local database only (product-spec.md P08).
    public var deviceRows: [DeviceRow] {
        let current = currentDevice?.id
        return session.pairedDevices.map {
            DeviceRow(id: $0.id, name: $0.name, isCurrent: $0.id == current, status: session.status(of: $0.id),
                      lastSeenAt: $0.lastSeenAt, lastSyncedAt: $0.lastSyncedAt)
        }
    }

    /// A tap on a row. Returns true when P08 can close; false when a Modal on P08 has to answer
    /// first (`pendingSwitch`, `switcherPrompt`).
    public func selectDevice(_ id: UUID) -> Bool {
        guard let current = currentDevice, id != current.id else { return true }
        switch status {
        case .recording, .paused:
            pendingSwitch = PendingSwitch(deviceId: id, reason: .recording)
            return false
        case .idle where session.syncEngine.isRunning:
            pendingSwitch = PendingSwitch(deviceId: id, reason: .syncing)
            return false
        default:
            return switchDevice(to: id)
        }
    }

    /// "切换" in the Modal; returns true when P08 can close, like `selectDevice`.
    public func confirmSwitch() -> Bool {
        guard let pending = pendingSwitch else { return true }
        pendingSwitch = nil
        return switchDevice(to: pending.deviceId)
    }

    /// Drops the current card and waits for the new one (product-spec.md §3.3). The new card
    /// is current even when CoreBluetooth does not know it: "重新搜索" then finds it again.
    private func switchDevice(to id: UUID) -> Bool {
        guard let device = session.pairedDevices.first(where: { $0.id == id }) else { return true }
        preferences.currentDeviceId = id
        do {
            try session.switchTo(device)
        } catch CardServiceError.unknownCard {
            session.diagnostics?.add("home", "switch failed: unknownCard")
            switcherPrompt = .rescan
            return false
        } catch {
            session.diagnostics?.add("home", "switch failed: \(error)")
            toast = Toast((error as? CardServiceError)?.userText ?? "连接失败，请重试")
        }
        return true
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

    /// A pass that finds the card no longer paired with this phone raises the Modal once.
    private func observeSyncStatus(_ watch: UUID) {
        withObservationTracking { _ = session.syncEngine.status } onChange: {
            Task { @MainActor [weak self] in
                guard let self, self.syncWatch == watch else { return }
                if self.session.syncEngine.status == .stopped(SyncFailure.notPaired.rawValue) {
                    self.session.diagnostics?.add("home", "sync found the card not paired")
                    self.prompt = .repair
                }
                self.observeSyncStatus(watch)
            }
        }
    }

    // MARK: - Prompts

    /// "重新配对": the card is still on the link but does not advertise there, so drop it for
    /// P03's scan. Home does not reconnect meanwhile; pairing it again connects it.
    public func repairTapped() {
        prompt = nil
        session.disconnect()
    }

    // MARK: - Recording control

    /// Recorded seconds at `date` while recording or paused; nil until the card has reported it.
    public func recordedSeconds(at date: Date) -> Int? {
        session.recordedMs(at: date).map { $0 / 1000 }
    }

    /// When the current recording started, from the card's file name.
    public var recordingStartedAt: Date? {
        session.recordingName.flatMap { SyncEngine.startDate(fileName: $0) }
    }

    // MARK: - Marks (features.md X7)

    /// Bumped by `markNow`, so views that show `markCount` redraw.
    private var markTick = 0

    /// Marks set in the recording that is running now.
    public var markCount: Int {
        _ = markTick
        guard let device = currentDevice, let name = session.recordingName else { return 0 }
        return ((try? session.library.marks(deviceId: device.id, cardFileName: name)) ?? []).count
    }

    /// "标重点": remembers the current position of the running recording. The position is the
    /// card's own recorded time, so pauses do not shift it; nothing is sent to the card.
    public func markNow(at date: Date = Date()) {
        guard status == .recording, let device = currentDevice, let name = session.recordingName,
              let offset = session.recordedMs(at: date) else {
            toast = Toast("现在还不能标重点")
            return
        }
        do {
            try session.library.addMark(deviceId: device.id, cardFileName: name, offsetMs: offset, now: date)
            markTick += 1
        } catch {
            toast = Toast("标记失败，请重试")
        }
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
                // After a timeout 0x56 decided the state (#47): the command did not take effect,
                // so repeating it is safe.
                if !command.isReached(by: status) {
                    session.diagnostics?.add("home", "\(command) not taken effect, card is \(status)")
                    toast = Toast("录音卡没有响应，请重试")
                }
            } catch CardServiceError.notPaired {
                session.diagnostics?.add("home", "\(command) failed: notPaired")
                prompt = .repair
            } catch CardServiceError.requestTimeout {
                // The command may have taken effect with only the reply lost; resending is
                // unverified, so do not ask the user to repeat it (product-spec.md §7.1).
                session.diagnostics?.add("home", "\(command) failed: requestTimeout")
                toast = Toast("录音卡没有响应，录音状态未确认")
            } catch {
                session.diagnostics?.add("home", "\(command) failed: \(error)")
                let text = (error as? CardServiceError)?.userText ?? "操作失败，请重试"
                toast = Toast(text)
            }
        }
    }

    // MARK: - Recordings

    /// Moves the local recording to 最近删除, where it stays 7 days (features.md D1b); nothing is
    /// sent to the card (product-spec.md §3.3).
    public func delete(_ id: UUID) {
        if player?.recordingId == id { player?.stop() }
        do {
            try session.library.trashRecording(id: id)
            lastTrashed = id
            lastDiscarded = nil
            toast = Toast("已移到最近删除", action: "撤销")
        } catch {
            toast = Toast("删除失败，请重试")
        }
    }

    // MARK: - Keep or discard (features.md X10)

    private func observeFinished(_ watch: UUID) {
        withObservationTracking { _ = session.lastFinished } onChange: {
            Task { @MainActor [weak self] in
                guard let self, self.syncWatch == watch else { return }
                self.offerKeep(self.session.lastFinished)
                self.observeFinished(watch)
            }
        }
    }

    private func offerKeep(_ finished: FinishedRecording?) {
        guard let finished, finished.deviceId == currentDevice?.id, finished != justRecorded else { return }
        justRecorded = finished
        offerTask?.cancel()
        offerTask = Task { [weak self, keepOfferDuration] in
            try? await Task.sleep(for: keepOfferDuration)
            guard !Task.isCancelled, let self, self.justRecorded == finished else { return }
            self.justRecorded = nil  // not answered: kept
        }
    }

    /// "留着": nothing to do but close the offer.
    public func keepJustRecorded() {
        offerTask?.cancel()
        justRecorded = nil
    }

    /// "不要": the recording is still synced first, then goes to 最近删除 and is deleted from the
    /// card (CLAUDE.md rule 2 holds: the card copy goes only after the phone has it).
    public func discardJustRecorded() {
        guard let finished = justRecorded else { return }
        offerTask?.cancel()
        justRecorded = nil
        do {
            try session.library.requestDiscard(deviceId: finished.deviceId, cardFileName: finished.cardFileName)
            lastDiscarded = finished
            lastTrashed = nil
            toast = Toast("这条不会保留", action: "撤销")
            session.syncEngine.requestSync(.discard)
        } catch {
            toast = Toast("操作失败，请重试")
        }
    }

    /// Stars or unstars a recording from its list row (features.md X21).
    public func toggleStar(_ id: UUID) {
        guard let recording = recordings.first(where: { $0.id == id }) else { return }
        do {
            try session.library.setStarred(id: id, !recording.isStarred)
        } catch {
            toast = Toast("保存失败，请重试")
        }
    }

    /// The list grouped by day, with each day's count and total length (#89).
    public var days: [RecordingDay] { RecordingDay.group(filteredRecordings) }

    /// A recording was moved to 最近删除 from its own page: the list offers "撤销" like a swipe
    /// delete does (#85).
    public func offerUndo(forTrashed id: UUID) {
        lastTrashed = id
        lastDiscarded = nil
        toast = Toast("已移到最近删除", action: "撤销")
    }

    /// "撤销" on the toast: puts the recording just deleted, or just discarded, back.
    public func undoDelete() {
        if let finished = lastDiscarded {
            lastDiscarded = nil
            do {
                try session.library.cancelDiscard(deviceId: finished.deviceId, cardFileName: finished.cardFileName)
                toast = Toast("已保留")
            } catch {
                toast = Toast("恢复失败，请重试")
            }
            return
        }
        guard let id = lastTrashed else { return }
        lastTrashed = nil
        do {
            try session.library.restoreRecording(id: id)
            toast = Toast("已恢复")
        } catch {
            toast = Toast("恢复失败，请重试")
        }
    }

    /// The filter chips above the list (design-spec.md §3, #89).
    public enum Filter: String, CaseIterable, Identifiable, Sendable {
        case all, starred, withTodos, marked, untranscribed

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .all: "全部"
            case .starred: "星标"
            case .withTodos: "有待办"
            case .marked: "有重点"
            case .untranscribed: "还没转文字"
            }
        }
    }

    public var filter: Filter = .all
    /// The folder chip that is selected, if any (features.md D1c); applies on top of `filter`.
    public var folderFilter: UUID?
    /// The source chip that is selected, if any (features.md D1c 按来源筛选); also on top of `filter`.
    public var sourceFilter: Recording.Source?

    /// Sources to offer as chips: only when the list holds more than one, card first.
    public var sources: [Recording.Source] {
        let present = Set(recordings.map(\.source))
        guard present.count > 1 else { return [] }
        return [Recording.Source.card, .phone, .import, .realtime].filter(present.contains)
    }
    public private(set) var folders: [Folder] = []

    /// Reads the folders again (they change on the recording page and in the chip menu).
    public func refreshFolders() {
        folders = (try? session.library.folders()) ?? []
        if let folderFilter, !folders.contains(where: { $0.id == folderFilter }) { self.folderFilter = nil }
    }

    public func renameFolder(_ folder: Folder, to name: String) {
        do {
            try session.library.renameFolder(id: folder.id, to: name)
        } catch {
            toast = Toast("重命名失败，请重试")
        }
        refreshFolders()
    }

    /// Deletes the folder; its recordings stay in the list.
    public func deleteFolder(_ folder: Folder) {
        do {
            try session.library.deleteFolder(id: folder.id)
            toast = Toast("已删除文件夹，里面的录音还在")
        } catch {
            toast = Toast("删除失败，请重试")
        }
        refreshFolders()
    }

    /// `recordings` narrowed by `folderFilter` and `filter`, newest first.
    public var filteredRecordings: [Recording] {
        var recordings = folderFilter.map { id in self.recordings.filter { $0.folderId == id } } ?? self.recordings
        if let sourceFilter { recordings = recordings.filter { $0.source == sourceFilter } }
        switch filter {
        case .all:
            return recordings
        case .starred:
            return recordings.filter(\.isStarred)
        case .withTodos:
            let ids = (try? session.library.recordingIdsWithOpenTodos()) ?? []
            return recordings.filter { ids.contains($0.id) }
        case .marked:
            let ids = (try? session.library.recordingIdsWithMarks()) ?? []
            return recordings.filter { ids.contains($0.id) }
        case .untranscribed:
            let ids = (try? session.library.recordingIdsWithTranscript()) ?? []
            return recordings.filter { !ids.contains($0.id) }
        }
    }

    /// An import from Files is running (features.md E2).
    public private(set) var isImporting = false

    /// File extensions read as text (features.md E2): the file becomes a recording with no audio.
    public static let textExtensions: Set<String> = ["txt", "text", "md", "markdown"]

    /// Imports audio or text files picked in Files: each becomes a recording named after its
    /// file; a text file's paragraphs become its transcript and it has no audio. The caller has
    /// already opened their security scope. Nothing is sent anywhere.
    public func importAudio(_ urls: [URL]) async {
        guard !urls.isEmpty, !isImporting else { return }
        isImporting = true
        defer { isImporting = false }
        var imported = 0
        var failed = 0
        for url in urls {
            do {
                if Self.textExtensions.contains(url.pathExtension.lowercased()) {
                    let created = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
                    guard let text = TextImport.decode(try Data(contentsOf: url)),
                          try session.library.addTextRecording(text: text, title: url.deletingPathExtension().lastPathComponent,
                                                               startedAt: created) != nil
                    else { throw CocoaError(.fileReadCorruptFile) }
                    imported += 1
                    continue
                }
                let prepared = try await AudioImporter.prepare(url)
                let created = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
                try session.library.addLocalRecording(file: prepared.file, source: .import, startedAt: created,
                                                      durationMs: prepared.durationMs,
                                                      title: url.deletingPathExtension().lastPathComponent)
                try? FileManager.default.removeItem(at: prepared.file.deletingLastPathComponent())
                imported += 1
            } catch {
                failed += 1
            }
        }
        switch (imported, failed) {
        case (_, 0): toast = Toast(imported == 1 ? "已导入" : "已导入 \(imported) 个文件")
        case (0, _): toast = Toast("导入失败：不是能识别的音频或文字文件")
        default: toast = Toast("已导入 \(imported) 个，\(failed) 个无法识别")
        }
    }

    /// Results of the search field (features.md D2); nil when it is empty.
    public private(set) var searchResults: [Recording]?

    /// Searches titles, transcripts and summaries on this phone.
    public func search(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            searchResults = nil
            return
        }
        searchResults = (try? session.library.searchRecordings(trimmed)) ?? []
    }

    /// Marks of a recording, for the count on its list row (design-spec.md §3 录音行).
    public func markCount(for recording: Recording) -> Int {
        ((try? session.library.playbackMarks(for: recording)) ?? []).count
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
        } catch CardServiceError.unknownCard {
            session.diagnostics?.add("home", "reconnect failed: unknownCard")
            prompt = .rescan
        } catch {
            session.diagnostics?.add("home", "reconnect failed: \(error)")
            toast = Toast((error as? CardServiceError)?.userText ?? "连接失败，请重试")
        }
    }
}
