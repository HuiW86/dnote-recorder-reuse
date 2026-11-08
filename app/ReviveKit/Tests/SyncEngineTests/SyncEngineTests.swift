import CardLink
import CardProtocol
import CardService
import CardTestSupport
import Foundation
import Library
import SyncEngine
import Testing

// Sync state machine against the fake card (prd.md §4; test-spec.md T-M1-20…32).

private let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("CardProtocolTests/Fixtures")

private func fixture(_ name: String) -> Data {
    (try? Data(contentsOf: fixtures.appendingPathComponent(name))) ?? Data()
}

/// `encrypted.bin` decrypts to `plain.bin`; both wrap to `expected_ogg.bin` (make_fixtures.py).
private let encrypted = fixture("encrypted.bin")
private let expectedOgg = fixture("expected_ogg.bin")

private func plainOpus(frames: Int, seed: UInt8) -> Data {
    Data((0..<(frames * 40)).map { UInt8(truncatingIfNeeded: $0) &+ seed })
}

private let fastTiming = CardService.Timing(request: .milliseconds(200), listFiles: .milliseconds(200),
                                            downloadBytesPerSecond: 1_000_000, downloadSlack: .milliseconds(500))
/// Long retry delays so no timer fires during a test unless the test asks for it.
private let testOptions = SyncEngine.Options(retryDelays: [.seconds(60), .seconds(60), .seconds(60)],
                                             recordingStoppedDelay: .milliseconds(10), spaceMargin: 0)

/// Polls until `condition` holds; fails the test after `timeout`.
@MainActor
private func waitUntil(_ what: String, timeout: Duration = .seconds(3),
                       _ condition: () throws -> Bool) async rethrows {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if try condition() { return }
        try? await Task.sleep(for: .milliseconds(5))
    }
    Issue.record("timed out waiting for \(what)")
}

/// Fake card + CardService + library + engine; CardService events are forwarded to the
/// current engine, as the app does.
@MainActor
private final class Harness {
    let card: FakeCard
    let service: CardService
    let library: RecordingLibrary
    let root: URL
    private(set) var engine: SyncEngine
    private(set) var events: [CardEvent] = []
    private let freeSpace: Int64

    init(files: [FakeCard.StoredFile] = [], card given: FakeCard? = nil, options: SyncEngine.Options = testOptions,
         freeSpace: Int64 = .max, hooks: SyncEngine.Hooks = SyncEngine.Hooks(), faults: [FakeCard.Fault] = [],
         waitForFirstPass: Bool = true) async throws {
        let card = given ?? FakeCard(files: files)
        self.card = card
        card.faults = faults
        service = CardService(link: card, bondStore: InMemoryBondStore([card.serial: card.bondId!]), timing: fastTiming)
        root = FileManager.default.temporaryDirectory.appendingPathComponent("sync-\(UUID().uuidString)")
        library = RecordingLibrary(database: try AppDatabase.inMemory(), store: try AudioStore(root: root))
        self.freeSpace = freeSpace
        engine = try SyncEngine(service: service, library: library, options: options, freeSpace: { freeSpace })
        engine.hooks = hooks
        let stream = service.events
        Task { [weak self] in
            for await e in stream {
                self?.events.append(e)
                self?.engine.handle(e)
            }
        }
        try await service.connect(card.id)
        // Connecting triggers the first pass (prd.md §4.4).
        await waitUntil("connected event") { events.contains(.stateChanged(.connected)) }
        if waitForFirstPass { await engine.idle() }
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    /// A new engine on the same database and files, as after the app was killed.
    func restart(options: SyncEngine.Options = testOptions) throws {
        engine = try SyncEngine(service: service, library: library, options: options, freeSpace: { [freeSpace] in freeSpace })
    }

    var items: [SyncItem] {
        get throws { try library.database.writer.read { try SyncItem.fetchAll($0) } }
    }

    var recordings: [Recording] {
        get throws { try library.recordings() }
    }

    var downloads: [CardRequest] { card.sentRequests.filter { $0.command == .fileData } }
    var deletes: [CardRequest] { card.sentRequests.filter { $0.command == .deleteFile } }

    func files(in dir: String) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent(dir).path)) ?? []
    }

    /// test-spec.md §3.5 gate 2, asserted at the end of every case.
    func checkNoForbiddenWrites() {
        #expect(card.wroteOnlyWhitelistedCommands)
        let cmds = Set(card.writtenFrames.map { $0[$0.startIndex + 1] })
        #expect(cmds.isDisjoint(with: [0x93, 0x94, 0xB0, 0xB1]))
    }
}

@MainActor
struct SyncEngineTests {
    /// T-M1-20
    @Test func syncsThreeFiles() async throws {
        let h = try await Harness(files: [
            .init(name: "20261101090000.opus", content: encrypted),
            .init(name: "20261101100000.opus", content: plainOpus(frames: 50, seed: 1)),
            .init(name: "20261101110000.opus", content: plainOpus(frames: 75, seed: 2)),
        ])
        let recordings = try h.recordings
        #expect(recordings.count == 3)
        #expect(try h.items.allSatisfy { $0.state == .stored && $0.recordingId != nil })
        let byName = Dictionary(uniqueKeysWithValues: recordings.map { ($0.cardFileName!, $0) })
        let first = try #require(byName["20261101090000.opus"])
        #expect(try Data(contentsOf: h.library.store.url(forAudioPath: first.audioPath)) == expectedOgg)
        #expect(first.durationMs == 123 * 20)
        #expect(byName["20261101100000.opus"]?.durationMs == 50 * 20)
        for r in recordings {
            let ogg = try Data(contentsOf: h.library.store.url(forAudioPath: r.audioPath))
            #expect(ogg.prefix(4) == Data("OggS".utf8))
        }
        #expect(h.engine.status == .idle)
        #expect(h.files(in: "tmp").isEmpty && h.files(in: "staging").isEmpty)
        h.checkNoForbiddenWrites()
    }

    /// SyncStatusCard data (product-spec.md §2.4): pending count, "n of total", last completed pass.
    @Test func reportsProgressAndLastCompletedPass() async throws {
        var seen: [SyncEngine.Progress?] = []
        var pendingSeen: [Int] = []
        var hooks = SyncEngine.Hooks()
        var engineRef: SyncEngine?
        hooks.beforeDownload = { _ in
            seen.append(engineRef?.progress)
            pendingSeen.append(engineRef?.pendingCount ?? -1)
        }
        let h = try await Harness(files: [
            .init(name: "a.opus", content: plainOpus(frames: 10, seed: 1)),
            .init(name: "b.opus", content: plainOpus(frames: 10, seed: 2)),
        ], waitForFirstPass: false)
        #expect(h.engine.lastCompletedAt == nil)
        engineRef = h.engine
        h.engine.hooks = hooks
        await h.engine.idle()
        // The first pass may have started before the hook was set; run one more with new files.
        h.card.files += [.init(name: "c.opus", content: plainOpus(frames: 10, seed: 3)),
                         .init(name: "d.opus", content: plainOpus(frames: 10, seed: 4))]
        seen = []
        pendingSeen = []
        await h.engine.syncNow()
        #expect(seen == [.init(index: 1, total: 2), .init(index: 2, total: 2)])
        #expect(pendingSeen == [2, 1])
        #expect(h.engine.progress == nil)
        #expect(h.engine.pendingCount == 0)
        #expect(h.engine.lastCompletedAt != nil)

        // A new engine on the same library starts from the newest stored recording.
        try h.restart()
        #expect(h.engine.lastCompletedAt != nil)
        h.checkNoForbiddenWrites()
    }

    @Test func failedFileStaysPending() async throws {
        let h = try await Harness(files: [.init(name: "a.opus", content: encrypted)],
                                  faults: [.chunkStatus(index: 1, status: 0x40)])
        #expect(try h.items.first?.state == .failed)
        #expect(h.engine.pendingCount == 1)
        h.checkNoForbiddenWrites()
    }

    /// T-M1-21
    @Test func resumesAfterDrop() async throws {
        let h = try await Harness(files: [.init(name: "a.opus", content: encrypted)],
                                  faults: [.disconnectAfterChunks(3)])
        let partial = 3 * h.card.chunkSize
        #expect(h.engine.status == .stopped("disconnected"))
        #expect(try h.items.first?.state == .failed)
        #expect(try h.recordings.isEmpty)

        h.card.advertise()  // the card comes back; the pending connect completes
        try await waitUntil("stored after reconnect") { try h.items.first?.state == .stored }
        await h.engine.idle()
        #expect(h.downloads.last == .download(name: "a.opus", offset: partial))
        let recordings = try h.recordings
        #expect(recordings.count == 1)
        #expect(try Data(contentsOf: h.library.store.url(forAudioPath: recordings[0].audioPath)) == expectedOgg)
        #expect(h.files(in: "tmp").isEmpty)
        h.checkNoForbiddenWrites()
    }

    /// T-M1-22
    @Test func decryptFailureKeepsCardFileAndRawBytes() async throws {
        var corrupt = encrypted
        corrupt[corrupt.startIndex + 40] ^= 0xFF  // inside the encrypted copy of the header
        let h = try await Harness(files: [.init(name: "bad.opus", content: corrupt)])
        let item = try #require(try h.items.first)
        #expect(item.state == .failed && item.lastError == "decryptFailed")
        #expect(try h.recordings.isEmpty)
        #expect(h.card.files.map(\.name) == ["bad.opus"])
        #expect(h.files(in: "diagnostics").count == 1)
        let before = h.downloads.count
        await h.engine.syncNow()
        #expect(h.downloads.count == before)  // not retried: same bytes, same result
        h.checkNoForbiddenWrites()
    }

    /// T-M1-23: the app dies between writing the OGG and committing the transaction.
    @Test func crashBeforeCommitRedownloadsOnce() async throws {
        var frozen = false
        var hooks = SyncEngine.Hooks()
        hooks.beforeCommit = {
            frozen = true
            // Never returns: the process is "dead" from here on.
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in Frozen.keep(c) }
        }
        let h = try await Harness(files: [.init(name: "a.opus", content: encrypted)], hooks: hooks,
                                  waitForFirstPass: false)
        await waitUntil("frozen before commit") { frozen }
        #expect(h.files(in: "audio").count == 1)  // OGG in place, transaction not committed
        #expect(try h.items.first?.state == .downloading)

        try h.restart()
        #expect(h.files(in: "audio").isEmpty)  // orphan removed
        #expect(h.files(in: "tmp").isEmpty)
        #expect(try h.items.first?.state == .discovered)
        await h.engine.syncNow()
        #expect(try h.recordings.count == 1)
        #expect(h.files(in: "audio").count == 1)
        #expect(h.downloads.count == 2 && h.downloads.last == .download(name: "a.opus", offset: 0))
        h.checkNoForbiddenWrites()
    }

    /// T-M1-24
    @Test func storedFileIsNotDownloadedAgain() async throws {
        let h = try await Harness(files: [.init(name: "a.opus", content: plainOpus(frames: 10, seed: 0))])
        #expect(h.downloads.count == 1)
        await h.engine.syncNow()
        await h.engine.syncNow()
        #expect(h.downloads.count == 1)
        #expect(try h.recordings.count == 1)
        h.checkNoForbiddenWrites()
    }

    /// T-M1-25
    @Test func sameNameDifferentSizeIsTwoFiles() async throws {
        let h = try await Harness(files: [.init(name: "20260101000000.opus", content: plainOpus(frames: 10, seed: 0))])
        // Card clock reset: a later recording gets the same name.
        h.card.files = [.init(name: "20260101000000.opus", content: plainOpus(frames: 20, seed: 9))]
        await h.engine.syncNow()
        #expect(try h.recordings.count == 2)
        #expect(try Set(h.items.map(\.cardFileSize)) == [400, 800])
        h.checkNoForbiddenWrites()
    }

    /// T-M1-26
    @Test func deleteOnlyAfterCommit() async throws {
        var options = testOptions
        options.deleteAfterSync = true
        var commits: [String: Int] = [:]
        let card = FakeCard(files: [.init(name: "a.opus", content: plainOpus(frames: 5, seed: 0)),
                                    .init(name: "b.opus", content: encrypted)])
        var hooks = SyncEngine.Hooks()
        hooks.afterCommit = { item in commits[item.cardFileName] = card.sentRequests.count }
        let h = try await Harness(card: card, options: options, hooks: hooks)
        await h.engine.syncNow()

        #expect(h.deletes.count == 2)
        for (index, request) in h.card.sentRequests.enumerated() {
            guard case .delete(let name) = request else { continue }
            let committedAt = try #require(commits[name])
            #expect(committedAt <= index)
        }
        #expect(h.card.files.isEmpty)
        #expect(try h.items.allSatisfy { $0.state == .deletedOnCard && $0.deletedOnCardAt != nil })
        #expect(try h.recordings.count == 2)
        h.checkNoForbiddenWrites()
    }

    /// T-M1-27, delete carried out, then the link dropped.
    @Test func deleteThenDropIsConfirmedByNextList() async throws {
        var options = testOptions
        options.deleteAfterSync = true
        let h = try await Harness(files: [.init(name: "a.opus", content: encrypted)], options: options,
                                  faults: [.disconnectAfter(.deleteFile)])
        #expect(try h.items.first?.state == .deletePending)
        h.card.advertise()
        try await waitUntil("deleted on card") { try h.items.first?.state == .deletedOnCard }
        #expect(h.deletes.count == 1)
        #expect(try h.recordings.count == 1)
        h.checkNoForbiddenWrites()
    }

    /// T-M1-27, link dropped before the delete took effect.
    @Test func deleteLostIsSentAgain() async throws {
        var options = testOptions
        options.deleteAfterSync = true
        let h = try await Harness(files: [.init(name: "a.opus", content: encrypted)], options: options,
                                  faults: [.disconnectInsteadOf(.deleteFile)])
        #expect(try h.items.first?.state == .deletePending)
        #expect(h.card.files.count == 1)
        h.card.advertise()
        try await waitUntil("deleted on card") { try h.items.first?.state == .deletedOnCard }
        #expect(h.deletes.count == 2)
        #expect(h.card.files.isEmpty)
        #expect(try h.recordings.count == 1)
        h.checkNoForbiddenWrites()
    }

    /// T-M1-28
    @Test func defaultNeverDeletes() async throws {
        let h = try await Harness(files: [.init(name: "a.opus", content: encrypted),
                                          .init(name: "b.opus", content: plainOpus(frames: 5, seed: 3))])
        await h.engine.syncNow()
        #expect(h.deletes.isEmpty)
        #expect(h.card.files.count == 2)
        #expect(try h.items.allSatisfy { $0.state == .stored })
        h.checkNoForbiddenWrites()
    }

    /// T-M1-29
    @Test func recordingStartedMidSyncPausesUntilStop() async throws {
        var pressed = false
        let card = FakeCard(files: [.init(name: "1.opus", content: plainOpus(frames: 5, seed: 1)),
                                    .init(name: "2.opus", content: plainOpus(frames: 5, seed: 2)),
                                    .init(name: "3.opus", content: plainOpus(frames: 5, seed: 3))])
        var hooks = SyncEngine.Hooks()
        hooks.afterDownload = { _ in
            guard !pressed else { return }
            pressed = true
            card.pressButtonToRecord()
        }
        let h = try await Harness(card: card, hooks: hooks)
        #expect(h.engine.status == .waitingForRecording)
        #expect(try h.recordings.count == 1)  // the file in flight was finished
        // The empty list of a recording card changes nothing.
        await h.engine.syncNow()
        #expect(try h.items.allSatisfy { $0.state == .stored || $0.state == .discovered })

        h.card.pressButtonToStop()  // adds the new recording and pushes recordingStopped
        try await waitUntil("all four stored") { try h.recordings.count == 4 }
        await h.engine.idle()
        #expect(h.engine.status == .idle)
        #expect(h.deletes.isEmpty)
        h.checkNoForbiddenWrites()
    }

    /// T-M1-30
    @Test func phoneFullStopsWithoutTouchingCard() async throws {
        let h = try await Harness(files: [.init(name: "a.opus", content: encrypted)], freeSpace: 1_000)
        #expect(h.engine.status == .stopped("phoneStorageFull"))
        #expect(try h.items.first?.lastError == "phoneStorageFull")
        #expect(h.downloads.isEmpty && h.deletes.isEmpty)
        #expect(h.card.files.count == 1)
        h.checkNoForbiddenWrites()
    }

    /// T-M1-31
    @Test func fileGoneBeforeDownloadRelists() async throws {
        let card = FakeCard(files: [.init(name: "a.opus", content: encrypted)])
        var hooks = SyncEngine.Hooks()
        hooks.beforeDownload = { file in card.files.removeAll { $0.name == file.name } }
        let h = try await Harness(card: card, hooks: hooks)
        #expect(try h.items.first?.lastError == "fileNotFound")
        #expect(try h.recordings.isEmpty)
        #expect(h.card.sentRequests.filter { $0 == .listFiles }.count >= 2)
        h.checkNoForbiddenWrites()
    }

    /// T-M1-32
    @Test func localDeleteDoesNotResyncOrTouchCard() async throws {
        let h = try await Harness(files: [.init(name: "a.opus", content: encrypted)])
        let recording = try #require(try h.recordings.first)
        let written = h.card.writtenFrames.count
        try h.library.deleteRecording(id: recording.id)
        #expect(h.card.writtenFrames.count == written)
        #expect(try h.recordings.isEmpty)
        #expect(h.files(in: "audio").isEmpty)
        let item = try #require(try h.items.first)
        #expect(item.state == .stored && item.recordingId == nil)

        await h.engine.syncNow()
        #expect(h.downloads.count == 1)
        #expect(try h.recordings.isEmpty)
        #expect(h.card.files.count == 1)
        h.checkNoForbiddenWrites()
    }

    /// prd.md §4.3: a failed transfer is retried by the timer.
    @Test func transferFailureIsRetried() async throws {
        var options = testOptions
        options.retryDelays = [.milliseconds(20), .milliseconds(20), .milliseconds(20)]
        let h = try await Harness(files: [.init(name: "a.opus", content: encrypted)], options: options,
                                  faults: [.chunkStatus(index: 2, status: 0x40)])
        #expect(try h.items.first?.attempts == 1)
        try await waitUntil("stored after retry") { try h.items.first?.state == .stored }
        await h.engine.idle()
        #expect(try h.recordings.count == 1)
        h.checkNoForbiddenWrites()
    }

    /// #38 E: the card serves files when bonded elsewhere, so the engine checks 0xA1 itself.
    @Test func cardBondedElsewhereIsNotSynced() async throws {
        var options = testOptions
        options.deleteAfterSync = true
        let h = try await Harness(files: [.init(name: "a.opus", content: encrypted)], options: options)
        let deletesBefore = h.deletes.count
        h.card.bondId = Data(repeating: 0x77, count: 16)
        h.card.files.append(.init(name: "b.opus", content: plainOpus(frames: 5, seed: 3)))
        await h.engine.syncNow()
        #expect(h.engine.status == .stopped("notPaired"))
        #expect(h.downloads.count == 1)
        #expect(h.deletes.count == deletesBefore)
        #expect(h.card.files.map(\.name) == ["b.opus"])
        h.checkNoForbiddenWrites()
    }

    /// #38: a card that refuses every download stops the pass without spending attempts.
    @Test func refusedDownloadStopsPassWithoutAttempts() async throws {
        let h = try await Harness(files: [.init(name: "a.opus", content: encrypted),
                                          .init(name: "b.opus", content: plainOpus(frames: 5, seed: 4))],
                                  faults: [.refuseDownloads])
        #expect(h.engine.status == .stopped("cardBusy"))
        #expect(h.downloads.count == 1)
        let item = try #require(try h.items.first { $0.cardFileName == "a.opus" })
        #expect(item.lastError == "cardBusy" && item.attempts == 0)
        h.card.faults = []
        h.card.dropLink()
        h.card.advertise()
        try await waitUntil("both stored") { try h.recordings.count == 2 }
        h.checkNoForbiddenWrites()
    }

    @Test func noSyncWhileRecording() async throws {
        let h = try await Harness(files: [], waitForFirstPass: true)
        _ = try await h.service.startRecording()
        await h.engine.syncNow()
        #expect(h.engine.status == .waitingForRecording)
        #expect(h.card.sentRequests.filter { $0 == .listFiles }.count == 1)  // only the first, idle pass
        h.checkNoForbiddenWrites()
    }
}

/// Holds continuations that must never resume (a "dead" process in T-M1-23).
@MainActor
private enum Frozen {
    static var continuations: [CheckedContinuation<Void, Never>] = []
    static func keep(_ c: CheckedContinuation<Void, Never>) { continuations.append(c) }
}
