import CardLink
import CardProtocol
import CardService
import CryptoKit
import Foundation
import Library
import os

// Card files to the local library, per the sync state machine (prd.md §4).
//
// The card holds the only copy of a recording (CLAUDE.md rule 2), so a file is only ever
// deleted on the card after its Recording row and OGG file are committed, and only when
// the user has turned on delete-after-sync.

public enum SyncStatus: Equatable, Sendable {
    case idle
    case syncing(file: String, received: Int, total: Int)
    /// The card is recording or paused: its list is empty, so nothing is synced (H5).
    case waitingForRecording
    /// The last pass stopped early; the value is an app error code (prd.md §6).
    case stopped(String)
}

@MainActor
public final class SyncEngine {
    public struct Options: Sendable {
        /// Off by default (prd.md §4.5).
        public var deleteAfterSync: Bool
        /// Delays of the automatic retries of a failed file (prd.md §4.3).
        public var retryDelays: [Duration]
        /// Wait after `recordingStopped` before listing (prd.md §4.4).
        public var recordingStoppedDelay: Duration
        /// Free space kept on top of what a download needs.
        public var spaceMargin: Int64

        public init(deleteAfterSync: Bool = false, retryDelays: [Duration] = [.seconds(5), .seconds(30), .seconds(120)],
                    recordingStoppedDelay: Duration = .seconds(1), spaceMargin: Int64 = 20_000_000) {
            self.deleteAfterSync = deleteAfterSync
            self.retryDelays = retryDelays
            self.recordingStoppedDelay = recordingStoppedDelay
            self.spaceMargin = spaceMargin
        }
    }

    /// Test seams for fault injection (test-spec.md §3.3). Unused in the app.
    public struct Hooks {
        public var beforeDownload: (@MainActor (CardFile) -> Void)?
        public var afterDownload: (@MainActor (CardFile) -> Void)?
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
    public var hooks = Hooks()
    public private(set) var status: SyncStatus = .idle
    /// Set while a pass downloads files; nil otherwise.
    public private(set) var progress: Progress?
    /// Files on the current card that are not in the library yet, as of the last list.
    /// Files that failed to decrypt are not counted: they are never retried.
    public private(set) var pendingCount = 0
    /// End of the last pass that ran to completion; on launch, the newest stored card recording.
    public private(set) var lastCompletedAt: Date?

    private let service: CardService
    private let library: RecordingLibrary
    private let freeSpace: () -> Int64
    private let now: () -> Date
    private let log = Logger(subsystem: "revive", category: "SyncEngine")

    private var pass: Task<Void, Never>?
    private var rerunRequested = false
    private var retryTimer: Task<Void, Never>?
    /// `0x70` said a listed file does not exist: list once more (prd.md §6 `fileNotFound`).
    private var relistAfterNotFound = false

    /// Recovers from a previous crash before anything else touches the library (prd.md §4.3).
    public init(service: CardService, library: RecordingLibrary, options: Options = Options(),
                freeSpace: (() -> Int64)? = nil, now: @escaping () -> Date = Date.init) throws {
        self.service = service
        self.library = library
        self.options = options
        self.freeSpace = freeSpace ?? { library.store.availableCapacity() }
        self.now = now
        try library.recoverAfterLaunch()
        lastCompletedAt = try library.lastStoredAt()
    }

    // MARK: - Triggers (prd.md §4.4)

    /// Feed CardService events here; whoever consumes `CardService.events` forwards them.
    public func handle(_ event: CardEvent) {
        switch event {
        case .stateChanged(.connected):
            requestSync()
        case .recordingStopped:
            let delay = options.recordingStoppedDelay
            Task { [weak self] in
                try? await Task.sleep(for: delay)
                self?.requestSync()
            }
        default:
            break
        }
    }

    /// Starts a pass, or queues one more if a pass is running. Also the pull-to-refresh entry.
    public func requestSync() {
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
            await runPass()
        } while rerunRequested
        pass = nil
    }

    // MARK: - One pass

    private func runPass() async {
        guard service.linkState == .connected else { return }
        defer { progress = nil }
        do {
            let device = try await currentDevice()
            guard try await cardIsIdle() else { return }
            let files: [CardFile]
            do {
                files = try await service.listFiles()
            } catch CardServiceError.cardBusyRecording {
                // An empty list while recording says nothing about the card's files (#5).
                status = .waitingForRecording
                return
            }
            let listed = Set(files.map { Key($0.name, $0.size) })

            // A delete whose outcome was unknown (link dropped after 0x91): gone means done.
            for var item in try library.syncItems(deviceId: device.id)
            where item.state == .deletePending && !listed.contains(Key(item)) {
                markDeleted(&item)
            }

            var queue: [SyncItem] = []
            for file in files.sorted(by: { $0.name < $1.name }) {
                var item = try library.syncItem(deviceId: device.id, name: file.name, size: file.size)
                switch item.state {
                case .stored where options.deleteAfterSync:
                    item.state = .deletePending
                    try library.update(item)
                case .stored, .deletePending, .deletedOnCard:
                    break  // already in the library: never download again (T-M1-24)
                case .failed where item.lastError == SyncFailure.decryptFailed.rawValue:
                    break  // the bytes are kept in diagnostics; retrying gives the same result
                case .discovered, .downloading, .failed:
                    queue.append(item)
                }
            }

            pendingCount = queue.count
            for (index, item) in queue.enumerated() {
                // Recording started mid-sync: stop after the current file (prd.md §4.4).
                if index > 0, try await !cardIsIdle() { return }
                progress = Progress(index: index + 1, total: queue.count)
                if try await sync(item, device: device) { pendingCount -= 1 }
            }
            progress = nil

            if options.deleteAfterSync { try await deletePending(device) }
            status = .idle
            lastCompletedAt = now()
            if relistAfterNotFound {
                relistAfterNotFound = false
                rerunRequested = true
            }
            scheduleRetry(device)
        } catch {
            let code = SyncFailure.code(error)
            log.error("sync pass stopped: \(code, privacy: .public)")
            status = .stopped(code)
        }
    }

    private func cardIsIdle() async throws -> Bool {
        guard try await service.recordingStatus().state == .idle else {
            status = .waitingForRecording
            return false
        }
        return true
    }

    private func currentDevice() async throws -> Device {
        let info: DeviceInfo
        if let last = service.lastInfo { info = last } else { info = try await service.info() }
        let peripheral = service.peripheralId?.uuidString
        let seen = now()
        return try library.upsertDevice(sn: info.serial) { d in
            if d.name.isEmpty { d.name = info.bluetoothName ?? "D·NOTE" }
            d.firmware = info.firmware
            d.peripheralId = peripheral ?? d.peripheralId
            d.lastSeenAt = seen
            d.battery = info.battery
            d.freeMb = info.freeSpace
            d.totalMb = info.totalSpace
        }
    }

    // MARK: - One file (prd.md §4.1, §4.2)

    /// Downloads, converts and commits one file. Errors that concern only this file are
    /// recorded on the item; errors that end the pass (link lost, phone full) are thrown.
    /// Returns true when the recording was committed.
    private func sync(_ item: SyncItem, device: Device) async throws -> Bool {
        var item = item
        guard let id = item.id else { return false }
        let file = CardFile(name: item.cardFileName, size: item.cardFileSize)
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

        let writer = try store.openPart(id)
        var writeFailed = false
        var received = offset
        status = .syncing(file: file.name, received: received, total: file.size)
        do {
            try await service.download(file, from: offset) { [weak self] chunk in
                do { try writer.append(chunk) } catch { writeFailed = true }
                received += chunk.count
                self?.status = .syncing(file: file.name, received: received, total: file.size)
            }
            writer.close()
        } catch let error as CardServiceError {
            writer.close()
            switch error {
            case .fileNotFound:
                store.removePart(id)
                fail(&item, .fileNotFound, countsAsAttempt: false)
                relistAfterNotFound = true
                return false
            case .transferFailed:
                // Offsets are checked per chunk, but a bad length at EOF leaves a full, wrong part.
                store.removePart(id)
                fail(&item, .transferFailed, countsAsAttempt: true)
                return false
            case .requestTimeout:
                fail(&item, .transferFailed, countsAsAttempt: true)
                return false
            default:
                // Link lost and the like: keep the part for resuming after reconnect (prd.md §4.3).
                fail(&item, SyncFailure(error), countsAsAttempt: false)
                throw error
            }
        }
        hooks.afterDownload?(file)
        if writeFailed {
            store.removePart(id)
            fail(&item, .phoneStorageFull, countsAsAttempt: false)
            throw SyncFailure.phoneStorageFull
        }

        let raw = try store.readPart(id)
        guard raw.count == file.size else {
            store.removePart(id)
            fail(&item, .transferFailed, countsAsAttempt: true)
            return false
        }
        let audio: ConvertedAudio
        do {
            audio = try await Task.detached(priority: .utility) { try ConvertedAudio(raw) }.value
        } catch {
            // Keep the card file and the raw bytes for a bug report (prd.md §6 decryptFailed).
            try? store.saveDiagnostic(raw, name: "\(device.id.uuidString)-\(file.name)")
            store.removePart(id)
            fail(&item, .decryptFailed, countsAsAttempt: false)
            return false
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

        let started = Self.startDate(fileName: file.name) ?? now()
        let recording = Recording(
            id: recordingId, deviceId: device.id, source: .card, cardFileName: file.name,
            cardFileSize: file.size, startedAt: started, durationMs: audio.durationMs, audioPath: path,
            audioSha256: audio.sha256, title: Self.title(started), createdAt: now(), updatedAt: now())
        do {
            item = try library.commitStored(recording, item: item, deleteAfterSync: options.deleteAfterSync)
        } catch {
            store.removeAudio(path)
            store.removePart(id)
            fail(&item, .storeFailed, countsAsAttempt: true)
            return false
        }
        store.removePart(id)
        hooks.afterCommit?(item)
        return true
    }

    private func fail(_ item: inout SyncItem, _ failure: SyncFailure, countsAsAttempt: Bool) {
        item.state = .failed
        item.lastError = failure.rawValue
        if countsAsAttempt { item.attempts += 1 }
        do { try library.update(item) } catch { log.error("could not record sync failure") }
    }

    private func markDeleted(_ item: inout SyncItem) {
        item.state = .deletedOnCard
        item.deletedOnCardAt = now()
        do { try library.update(item) } catch { log.error("could not record card delete") }
    }

    // MARK: - Delete after sync

    /// `0x91` for items already committed, then a second list to confirm (prd.md §4.1).
    private func deletePending(_ device: Device) async throws {
        let pending = try library.syncItems(deviceId: device.id).filter { $0.state == .deletePending }
        guard !pending.isEmpty else { return }
        for item in pending {
            // deletePending is only ever set in or after the commit that stores the recording.
            try await service.delete(item.cardFileName)
        }
        let remaining: [CardFile]
        do {
            remaining = try await service.listFiles()
        } catch CardServiceError.cardBusyRecording {
            return  // unconfirmed; the next pass checks again
        }
        let listed = Set(remaining.map { Key($0.name, $0.size) })
        for var item in pending where !listed.contains(Key(item)) {
            markDeleted(&item)
        }
    }

    // MARK: - Retries

    private func scheduleRetry(_ device: Device) {
        guard retryTimer == nil,
              let items = try? library.syncItems(deviceId: device.id) else { return }
        let retryable = items.filter {
            $0.state == .failed && $0.attempts > 0 && $0.attempts <= options.retryDelays.count
                && SyncFailure(rawValue: $0.lastError ?? "")?.retriesAutomatically == true
        }
        guard let attempts = retryable.map(\.attempts).min() else { return }
        let delay = options.retryDelays[attempts - 1]
        retryTimer = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self else { return }
            self.retryTimer = nil
            self.requestSync()
        }
    }

    // MARK: - Naming

    /// Card file names are `YYYYMMDDHHmmss.opus` in the card's clock, which the app sets to
    /// the phone's local time (prd.md §5.2).
    static func startDate(fileName: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyyMMddHHmmss"
        return f.date(from: String(fileName.prefix(14)))
    }

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
    case notPaired, cardBusyRecording, requestTimeout, other

    init(_ error: CardServiceError) {
        switch error {
        case .notPaired: self = .notPaired
        case .cardBusyRecording: self = .cardBusyRecording
        case .fileNotFound: self = .fileNotFound
        case .transferFailed: self = .transferFailed
        case .requestTimeout: self = .requestTimeout
        case .disconnected, .bluetoothOff, .bluetoothUnauthorized, .bluetoothUnsupported,
             .connectTimeout, .connectFailed, .unknownCard: self = .disconnected
        default: self = .other
        }
    }

    /// Retried by the 5 s / 30 s / 120 s timer; the rest wait for the next trigger.
    var retriesAutomatically: Bool {
        self == .transferFailed || self == .storeFailed
    }

    static func code(_ error: Error) -> String {
        switch error {
        case let e as SyncFailure: e.rawValue
        case let e as CardServiceError: SyncFailure(e).rawValue
        default: SyncFailure.storeFailed.rawValue
        }
    }
}

/// Unique key of a card file (prd.md §4.3).
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

/// Raw card bytes -> OGG, off the main actor (prd.md §4.2 step 2).
struct ConvertedAudio: Sendable {
    let ogg: Data
    let durationMs: Int
    let sha256: String

    init(_ raw: Data) throws {
        let opus = AudioCrypto.isEncrypted(raw) ? try AudioCrypto.decrypt(raw) : raw
        let frames = OggOpus.splitFrames(opus)
        ogg = OggOpus.wrap(frames)
        durationMs = frames.count * 20  // 20 ms per frame
        sha256 = SHA256.hash(data: ogg).map { String(format: "%02x", $0) }.joined()
    }
}
