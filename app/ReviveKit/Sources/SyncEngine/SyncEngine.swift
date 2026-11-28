import CryptoKit
import DeviceSource
import Foundation
import Library
import Observation
import os

// Device files to the local library, per the sync state machine (prd.md §4).
//
// The device holds the only copy of a recording (CLAUDE.md rule 2), so a file is only ever
// deleted on the device after its Recording row and OGG file are committed, and only when
// the user has turned on delete-after-sync or asked not to keep that recording.
//
// The engine knows devices only through `SyncSource` (ADR-010): it imports no D·NOTE module,
// and the D·NOTE card reaches it through `CardSyncSource`.

public enum SyncStatus: Equatable, Sendable {
    case idle
    case syncing(file: String, received: Int, total: Int)
    /// The card is recording or paused: its list is empty, so nothing is synced (H5).
    case waitingForRecording
    /// The last pass stopped early; the value is an app error code (prd.md §6).
    case stopped(String)
}

@MainActor
@Observable
public final class SyncEngine {
    public enum Trigger: String, Sendable {
        case connection, recordingStopped, manual, retry, discard
    }
    public struct Options: Sendable {
        /// Off by default (prd.md §4.5).
        public var deleteAfterSync: Bool
        /// Delays of the automatic retries of a failed file (prd.md §4.3).
        public var retryDelays: [Duration]
        /// Wait after `recordingStopped` before listing (prd.md §4.4).
        public var recordingStoppedDelay: Duration
        /// Free space kept on top of what a download needs.
        public var spaceMargin: Int64
        /// The app's build number (`CFBundleVersion`). A file that failed to decrypt in another
        /// build is downloaded once more at launch (#59); nil turns that off (tests).
        public var appBuild: String?

        public init(deleteAfterSync: Bool = false, retryDelays: [Duration] = [.seconds(5), .seconds(30), .seconds(120)],
                    recordingStoppedDelay: Duration = .seconds(1), spaceMargin: Int64 = 20_000_000,
                    appBuild: String? = nil) {
            self.deleteAfterSync = deleteAfterSync
            self.retryDelays = retryDelays
            self.recordingStoppedDelay = recordingStoppedDelay
            self.spaceMargin = spaceMargin
            self.appBuild = appBuild
        }
    }

    /// Test seams for fault injection (test-spec.md §3.3). Unused in the app.
    public struct Hooks {
        public var beforeDownload: (@MainActor (SourceFile) -> Void)?
        /// Replaces a single disk append so tests can model a short write or full volume.
        public var appendChunk: (@MainActor (PartWriter, Data) throws -> Void)?
        public var afterDownload: (@MainActor (SourceFile) -> Void)?
        /// Runs after the OGG file is in place and before the transaction commits.
        public var beforeCommit: (@MainActor () async -> Void)?
        public var afterCommit: (@MainActor (SyncItem) -> Void)?

        public init() {}
    }

    /// Position in the current pass, for "第 2 / 5 条" (product-spec.md §2.4).
    public struct Progress: Equatable, Sendable {
        /// 1-based number of the file being downloaded.
        public var index: Int
        public var total: Int

        public init(index: Int, total: Int) {
            self.index = index
            self.total = total
        }
    }

    public var options: Options
    @ObservationIgnored public var hooks = Hooks()
    /// Runs after each pass saves the card's row (`lastSeenAt`, battery, space) and again when
    /// the pass finishes (`lastSyncedAt`), so cached copies of the paired cards can be re-read
    /// (product-spec.md P08 "上次同步", "上次连接").
    @ObservationIgnored public var onDeviceSaved: (@MainActor (Device) -> Void)?
    /// Redacted diagnostics: why a pass was requested, and whether it was queued behind one.
    @ObservationIgnored public var onSyncRequested: (@MainActor (Trigger, Bool) -> Void)?
    /// Counts only; filenames and recording contents are never included.
    @ObservationIgnored public var onPassCompleted: (@MainActor (Int, Int, Int) -> Void)?
    public private(set) var status: SyncStatus = .idle
    /// Set while a pass downloads files; nil otherwise.
    public private(set) var progress: Progress?
    /// Files on the current card that are not in the library yet, as of the last list.
    /// Files that failed to decrypt are not counted: this build does not retry them.
    public private(set) var pendingCount = 0
    /// Failed files still on the current card, as of the last list (product-spec.md P05
    /// SyncStatusCard). Files that left the card no longer count.
    public private(set) var failures = FailureCounts(retryable: 0, undecryptable: 0)
    /// End of the last pass that ran to completion; on launch, the newest stored card recording.
    public private(set) var lastCompletedAt: Date?

    /// A pass is running or queued ("正在检查录音卡", product-spec.md P05).
    public var isRunning: Bool { pass != nil }

    /// The device files come from (ADR-010); `CardSyncSource` for the D·NOTE card.
    @ObservationIgnored private let source: any SyncSource
    @ObservationIgnored private let library: RecordingLibrary
    @ObservationIgnored private let freeSpace: () -> Int64
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let log = Logger(subsystem: "revive", category: "SyncEngine")

    private var pass: Task<Void, Never>?
    @ObservationIgnored private var rerunRequested = false
    @ObservationIgnored private var retryTimer: Task<Void, Never>?
    /// The card `failures` belongs to.
    @ObservationIgnored private var failuresDeviceId: UUID?
    /// The card and the "同步后删除" setting a pass started with (see `runPass`).
    @ObservationIgnored private var passCard: UUID?
    @ObservationIgnored private var passDeletesAfterSync = false

    /// Recovers from a previous crash before anything else touches the library (prd.md §4.3).
    public init(source: any SyncSource, library: RecordingLibrary, options: Options = Options(),
                freeSpace: (() -> Int64)? = nil, now: @escaping () -> Date = Date.init) throws {
        self.source = source
        self.library = library
        self.options = options
        self.freeSpace = freeSpace ?? { library.store.availableCapacity() }
        self.now = now
        try library.recoverAfterLaunch()
        if let build = options.appBuild {
            let reset = try library.retryFailures(SyncFailure.decryptFailed.rawValue, notFailedIn: build)
            if reset > 0 { log.notice("retrying \(reset) undecryptable file(s) in build \(build, privacy: .public)") }
        }
        lastCompletedAt = try library.lastStoredAt()
    }

    // MARK: - Triggers (prd.md §4.4)

    /// Feed device events here; whoever consumes the device's events forwards them (for the
    /// card, `CardService.events`, whose `CardEvent` maps itself to `SourceEvent`).
    public func handle(_ event: some SourceEventConvertible) {
        switch event.sourceEvent {
        case .connected:
            requestSync(.connection)
        case .recordingStopped:
            let delay = options.recordingStoppedDelay
            Task { [weak self] in
                try? await Task.sleep(for: delay)
                self?.requestSync(.recordingStopped)
            }
        case nil:
            break
        }
    }

    /// Starts a pass, or queues one more if a pass is running. Also the pull-to-refresh entry.
    public func requestSync(_ trigger: Trigger = .manual) {
        onSyncRequested?(trigger, pass != nil)
        guard pass == nil else {
            rerunRequested = true
            return
        }
        pass = Task { [weak self] in
            await self?.runPasses()
        }
    }

    /// Runs a pass and waits until the engine is idle.
    public func syncNow() async {
        requestSync()
        await idle()
    }

    /// Waits for the running pass and any pass queued behind it.
    public func idle() async {
        while let p = pass { await p.value }
    }

    private func runPasses() async {
        repeat {
            rerunRequested = false
            let needsRelist = await runPass()
            if needsRelist && !rerunRequested {
                _ = await runPass()  // One confirmation per trigger, even if the listing stays stale.
            }
        } while rerunRequested
        pass = nil
    }

    // MARK: - One pass

    /// Returns true if a completed pass needs a fresh listing to confirm a missing file.
    private func runPass() async -> Bool {
        guard source.isConnected else { return false }
        defer { progress = nil }
        // A pass belongs to the card it started on: after a switch it must not list, download
        // or delete on the next card with this card's file names, nor use that card's setting.
        passCard = source.connectionId
        passDeletesAfterSync = options.deleteAfterSync
        do {
            let device = try await currentDevice()
            if failuresDeviceId != device.id {
                failures = FailureCounts(retryable: 0, undecryptable: 0)
                failuresDeviceId = device.id
            }
            // The card serves files whether or not it is paired (#38 E): never sync, let alone
            // delete, on a card that was re-bound to another phone.
            guard try await source.isPairedWithThisPhone() else { throw SourceError.notPaired }
            guard try await cardIsIdle() else { return false }
            let files: [SourceFile]
            do {
                files = try await source.listFiles()
            } catch SourceError.busyRecording {
                // An empty list while recording says nothing about the card's files (#5).
                status = .waitingForRecording
                return false
            }
            let listed = Set(files.map { Key($0.name, $0.size) })

            // A delete whose outcome was unknown (link dropped after sending it): gone means done.
            for var item in try library.syncItems(deviceId: device.id)
            where item.state == .deletePending && !listed.contains(Key(item)) {
                markDeleted(&item)
            }

            var queue: [SyncItem] = []
            for file in files.sorted(by: { $0.name < $1.name }) {
                var item = try library.syncItem(deviceId: device.id, name: file.name, size: file.size)
                switch item.state {
                case .stored where passDeletesAfterSync:
                    // Deleted in the app: the card copy is the only one left, so it stays.
                    guard try library.hasLocalCopy(item) else { break }
                    item.state = .deletePending
                    try library.update(item)
                case .stored, .deletePending, .deletedOnCard:
                    break  // already in the library: never download again (T-M1-24)
                case .failed where item.lastError == SyncFailure.decryptFailed.rawValue:
                    // The bytes are kept in diagnostics; this build would give the same result.
                    // Another build retries it once at launch (init, #59).
                    break
                case .discovered, .downloading, .failed:
                    queue.append(item)
                }
            }

            var needsRelist = false
            pendingCount = queue.count
            for (index, item) in queue.enumerated() {
                // Recording started mid-sync: stop after the current file (prd.md §4.4).
                try checkSameCard()
                if index > 0, try await !cardIsIdle() { return false }
                progress = Progress(index: index + 1, total: queue.count)
                switch try await sync(item, device: device, converter: source.audioConverter) {
                case .stored: pendingCount -= 1
                case .missing: needsRelist = true
                case .failed: break
                }
            }
            progress = nil
            failures = try failureCounts(device, listed: listed)

            // With "同步后删除" off this only deletes files the user discarded (features.md X10).
            try await deletePending(device)
            try checkSameCard()
            status = .idle
            let completed = now()
            lastCompletedAt = completed
            // P08 "上次同步" per card; a failed write only loses the display, not the pass.
            if let synced = try? library.markSynced(deviceId: device.id, at: completed) { onDeviceSaved?(synced) }
            onPassCompleted?(listed.count, queue.count, failures.autoRetrying)
            scheduleRetry(device, listed: listed)
            return needsRelist
        } catch {
            let code = SyncFailure.code(error)
            log.error("sync pass stopped: \(code, privacy: .public)")
            status = .stopped(code)
            return false
        }
    }

    /// Counts failed items among the listed files. `fileNotFound` is never shown: the next
    /// list settles it (product-spec.md §7.1).
    private func failureCounts(_ device: Device, listed: Set<Key>) throws -> FailureCounts {
        let failed = try library.syncItems(deviceId: device.id).filter {
            $0.state == .failed && $0.lastError != SyncFailure.fileNotFound.rawValue && listed.contains(Key($0))
        }
        let undecryptable = failed.filter { $0.lastError == SyncFailure.decryptFailed.rawValue }.count
        return FailureCounts(retryable: failed.count - undecryptable, undecryptable: undecryptable,
                             autoRetrying: failed.filter(retriesLeft).count)
    }

    private func cardIsIdle() async throws -> Bool {
        guard try await !source.isRecording() else {
            status = .waitingForRecording
            return false
        }
        return true
    }

    /// Ends the pass as a lost link when the link now goes to another card, or to none.
    private func checkSameCard() throws {
        guard source.isConnected, source.connectionId == passCard else {
            throw SourceError.disconnected
        }
    }

    private func currentDevice() async throws -> Device {
        let info = try await source.deviceInfo()
        let peripheral = source.connectionId?.uuidString
        let defaultName = source.defaultDeviceName
        let seen = now()
        let device = try library.upsertDevice(sn: info.serial) { d in
            // Pairing names the device first; the device's own Bluetooth name is a brand (ADR-005).
            if d.name.isEmpty { d.name = defaultName }
            d.firmware = info.firmware
            d.peripheralId = peripheral ?? d.peripheralId
            d.lastSeenAt = seen
            d.battery = info.battery
            d.freeMb = info.freeMb
            d.totalMb = info.totalMb
        }
        onDeviceSaved?(device)
        return device
    }

    // MARK: - One file (prd.md §4.1, §4.2)

    private enum FileOutcome { case stored, missing, failed }

    /// Downloads, converts and commits one file. Errors that concern only this file are
    /// recorded on the item; errors that end the pass (link lost, phone full) are thrown.
    private func sync(_ item: SyncItem, device: Device, converter: any SourceAudioConverter) async throws -> FileOutcome {
        var item = item
        guard let id = item.id else { return .failed }
        let file = SourceFile(name: item.cardFileName, size: item.cardFileSize)
        let store = library.store

        var offset = store.partLength(id)
        if offset > file.size {
            store.removePart(id)
            offset = 0
        }
        // Part file + OGG of about the same size, plus a margin.
        let needed = Int64(file.size - offset) + Int64(file.size) + options.spaceMargin
        guard freeSpace() >= needed else {
            fail(&item, .phoneStorageFull, countsAsAttempt: false)
            throw SyncFailure.phoneStorageFull
        }

        item.state = .downloading
        try library.update(item)
        hooks.beforeDownload?(file)

        do {
            try await downloadPart(file, id: id, from: offset)
        } catch SyncFailure.phoneStorageFull {
            store.removePart(id)
            fail(&item, .phoneStorageFull, countsAsAttempt: false)
            throw SyncFailure.phoneStorageFull
        } catch let error as SourceError {
            switch error {
            case .fileNotFound:
                store.removePart(id)
                fail(&item, .fileNotFound, countsAsAttempt: false)
                return .missing
            case .transferFailed:
                // Offsets are checked per chunk, but a bad length at EOF leaves a full, wrong part.
                store.removePart(id)
                fail(&item, .transferFailed, countsAsAttempt: true)
                return .failed
            case .requestTimeout:
                fail(&item, .transferFailed, countsAsAttempt: true)
                return .failed
            case .busy:
                // Every file would be refused until the card restarts: keep the part, stop the pass.
                fail(&item, .cardBusy, countsAsAttempt: false)
                throw error
            default:
                // Link lost and the like: keep the part, so a reconnect in this run resumes from
                // its length. A relaunch clears tmp/ and downloads from the start (prd.md §4.3).
                fail(&item, SyncFailure(error), countsAsAttempt: false)
                throw error
            }
        }
        hooks.afterDownload?(file)

        let raw = try store.readPart(id)
        guard raw.count == file.size else {
            store.removePart(id)
            fail(&item, .transferFailed, countsAsAttempt: true)
            return .failed
        }
        let audio: ConvertedAudio
        do {
            audio = try await Task.detached(priority: .utility) { try ConvertedAudio(raw, converter: converter) }.value
        } catch {
            // Keep the card file and the raw bytes for a bug report (prd.md §6 decryptFailed).
            try? store.saveDiagnostic(raw, name: "\(device.id.uuidString)-\(file.name)")
            store.removePart(id)
            fail(&item, .decryptFailed, countsAsAttempt: false)
            return .failed
        }

        let recordingId = UUID()
        let path: String
        do {
            path = try store.storeAudio(audio.ogg, id: recordingId)
        } catch {
            store.removePart(id)
            fail(&item, .phoneStorageFull, countsAsAttempt: false)
            throw SyncFailure.phoneStorageFull
        }
        await hooks.beforeCommit?()

        let started = source.startDate(of: file) ?? now()
        let recording = Recording(
            id: recordingId, deviceId: device.id, source: .card, cardFileName: file.name,
            cardFileSize: file.size, startedAt: started, durationMs: audio.durationMs, audioPath: path,
            audioSha256: audio.sha256, title: Self.title(started), createdAt: now(), updatedAt: now())
        do {
            item = try library.commitStored(recording, item: item, deleteAfterSync: passDeletesAfterSync)
        } catch {
            store.removeAudio(path)
            store.removePart(id)
            fail(&item, .storeFailed, countsAsAttempt: true)
            return .failed
        }
        store.removePart(id)
        hooks.afterCommit?(item)
        return .stored
    }

    /// A resumable part must be a contiguous prefix. Once an append fails, ignore the rest
    /// of the transfer, even if the device keeps sending chunks or eventually drops the link.
    private func downloadPart(_ file: SourceFile, id: Int64, from offset: Int) async throws {
        let writer = try library.store.openPart(id)
        defer { writer.close() }
        let append = hooks.appendChunk ?? { try $0.append($1) }
        var received = offset
        var writeFailed = false
        status = .syncing(file: file.name, received: received, total: file.size)
        do {
            try await source.download(file, from: offset) { [weak self] chunk in
                guard !writeFailed else { return }
                do {
                    try append(writer, chunk)
                    received += chunk.count
                    self?.status = .syncing(file: file.name, received: received, total: file.size)
                } catch {
                    writeFailed = true
                }
            }
        } catch {
            if !writeFailed { throw error }
        }
        if writeFailed { throw SyncFailure.phoneStorageFull }
    }

    private func fail(_ item: inout SyncItem, _ failure: SyncFailure, countsAsAttempt: Bool) {
        item.state = .failed
        item.lastError = failure.rawValue
        item.failedBuild = failure == .decryptFailed ? options.appBuild : nil
        if countsAsAttempt { item.attempts += 1 }
        do { try library.update(item) } catch { log.error("could not record sync failure") }
    }

    private func markDeleted(_ item: inout SyncItem) {
        item.state = .deletedOnCard
        item.deletedOnCardAt = now()
        do {
            try library.update(item)
            try library.finishDiscard(deviceId: item.deviceId, cardFileName: item.cardFileName)
        } catch { log.error("could not record card delete") }
    }

    // MARK: - Delete after sync

    /// Deletes items already committed, then lists again to confirm (prd.md §4.1; `0x91` on the card).
    private func deletePending(_ device: Device) async throws {
        // An item is deleted from the card because "同步后删除" is on, or because the user asked
        // not to keep this recording. Items left `deletePending` by a setting since turned off stay.
        let pending = try library.syncItems(deviceId: device.id).filter { item in
            guard item.state == .deletePending else { return false }
            return try passDeletesAfterSync
                || library.discardRequested(deviceId: device.id, cardFileName: item.cardFileName)
        }
        guard !pending.isEmpty else { return }
        var sent: [SyncItem] = []
        for var item in pending {
            // deletePending is only ever set in or after the commit that stores the recording,
            // but the recording may have been deleted in the app since: check again right here.
            guard try library.hasLocalCopy(item) else {
                item.state = .stored
                try library.update(item)
                continue
            }
            try checkSameCard()
            try await source.delete(item.cardFileName)
            sent.append(item)
        }
        guard !sent.isEmpty else { return }
        try checkSameCard()
        let remaining: [SourceFile]
        do {
            remaining = try await source.listFiles()
        } catch SourceError.busyRecording {
            return  // unconfirmed; the next pass checks again
        }
        let listed = Set(remaining.map { Key($0.name, $0.size) })
        for var item in sent where !listed.contains(Key(item)) {
            markDeleted(&item)
        }
    }

    // MARK: - Retries

    private func scheduleRetry(_ device: Device, listed: Set<Key>) {
        // Only a completed pass with a fresh list may replace the previous timer. A failed
        // manual check must not cancel an otherwise valid automatic retry.
        guard let items = try? library.syncItems(deviceId: device.id) else { return }
        retryTimer?.cancel()
        retryTimer = nil
        let retryable = items.filter { listed.contains(Key($0)) && retriesLeft($0) }
        guard let attempts = retryable.map(\.attempts).min(), let card = passCard else { return }
        let delay = options.retryDelays[attempts - 1]
        retryTimer = Task { [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            guard !Task.isCancelled, let self else { return }
            self.retryTimer = nil
            guard self.source.isConnected, self.source.connectionId == card else { return }
            self.requestSync(.retry)
        }
    }

    /// A failed item that `scheduleRetry` will still pick up (product-spec.md §7.1: 3 tries).
    private func retriesLeft(_ item: SyncItem) -> Bool {
        item.state == .failed && item.attempts > 0 && item.attempts <= options.retryDelays.count
            && SyncFailure(rawValue: item.lastError ?? "")?.retriesAutomatically == true
    }

    // MARK: - Naming

    static func title(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: date)
    }
}

/// Item failure codes, stored in `sync_item.last_error` (prd.md §6).
public enum SyncFailure: String, Error, Sendable {
    case disconnected, transferFailed, fileNotFound, decryptFailed, phoneStorageFull, storeFailed
    case notPaired, cardBusyRecording, cardBusy, requestTimeout, unexpectedReply, other

    init(_ error: SourceError) {
        switch error {
        case .notPaired: self = .notPaired
        case .busyRecording: self = .cardBusyRecording
        case .busy: self = .cardBusy
        case .fileNotFound: self = .fileNotFound
        case .transferFailed: self = .transferFailed
        case .requestTimeout: self = .requestTimeout
        case .unexpectedReply: self = .unexpectedReply
        case .disconnected: self = .disconnected
        case .other: self = .other
        }
    }

    /// Retried by the 5 s / 30 s / 120 s timer; the rest wait for the next trigger.
    var retriesAutomatically: Bool {
        self == .transferFailed || self == .storeFailed
    }

    static func code(_ error: Error) -> String {
        switch error {
        case let e as SyncFailure: e.rawValue
        case let e as SourceError: SyncFailure(e).rawValue
        default: SyncFailure.storeFailed.rawValue
        }
    }
}

/// Unique key of a device file (prd.md §4.3).
private struct Key: Hashable {
    let name: String
    let size: Int

    init(_ name: String, _ size: Int) {
        self.name = name
        self.size = size
    }

    init(_ item: SyncItem) {
        self.init(item.cardFileName, item.cardFileSize)
    }
}

/// Downloaded bytes -> OGG through the device's converter, off the main actor (prd.md §4.2 step 2).
struct ConvertedAudio: Sendable {
    let ogg: Data
    let durationMs: Int
    let sha256: String

    init(_ raw: Data, converter: any SourceAudioConverter) throws {
        let audio = try converter.convert(raw)
        ogg = audio.ogg
        durationMs = audio.durationMs
        sha256 = SHA256.hash(data: ogg).map { String(format: "%02x", $0) }.joined()
    }
}
