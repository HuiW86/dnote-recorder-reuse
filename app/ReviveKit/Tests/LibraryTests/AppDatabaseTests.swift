import Foundation
import GRDB
import Testing
@testable import Library

struct AppDatabaseTests {
    @Test func inMemoryDatabaseOpensAndMigrates() throws {
        let db = try AppDatabase.inMemory()
        let foreignKeys = try db.writer.read { try Bool.fetchOne($0, sql: "PRAGMA foreign_keys") }
        #expect(foreignKeys == true)
        let applied = try db.writer.read { try AppDatabase.migrator.appliedIdentifiers($0) }
        #expect(applied == Set(AppDatabase.migrator.migrations))
    }

    /// prd.md §5.3: upgrade from a v1 library (the 0.1.0 (1) build) keeps its rows; a
    /// `decryptFailed` row from then has no build, so any build retries it once (#59).
    @Test func v1LibraryUpgradesToV2() throws {
        let queue = try DatabaseQueue()
        try AppDatabase.migrator.migrate(queue, upTo: "v1")
        let deviceId = UUID()
        try queue.write { db in
            try db.execute(sql: "INSERT INTO device (id, sn, name, firmware) VALUES (?, 'S', 'card', '1.50')",
                           arguments: [deviceId])
            try db.execute(sql: """
                INSERT INTO sync_item (device_id, card_file_name, card_file_size, state, attempts, last_error)
                VALUES (?, 'bad.opus', 10, 'failed', 0, 'decryptFailed')
                """, arguments: [deviceId])
        }
        let db = try AppDatabase(queue)
        let item = try #require(try db.writer.read { try SyncItem.fetchOne($0) })
        #expect(item.state == .failed && item.lastError == "decryptFailed" && item.failedBuild == nil)

        let lib = RecordingLibrary(database: db, store: try AudioStore(
            root: FileManager.default.temporaryDirectory.appendingPathComponent("lib-\(UUID().uuidString)")))
        defer { try? FileManager.default.removeItem(at: lib.store.root) }
        #expect(try lib.retryFailures("decryptFailed", notFailedIn: "2") == 1)
        let reset = try #require(try lib.syncItems(deviceId: deviceId).first)
        #expect(reset.state == .discovered && reset.lastError == nil)
        #expect(try lib.retryFailures("decryptFailed", notFailedIn: "2") == 0)
    }

    /// A library from before summaries (v5) gains the summary table and keeps its recordings.
    @Test func v5LibraryUpgradesToV6() throws {
        let queue = try DatabaseQueue()
        try AppDatabase.migrator.migrate(queue, upTo: "v5")
        let recordingId = UUID()
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO recording (id, source, started_at, duration_ms, audio_path, audio_sha256, title,
                                       created_at, updated_at)
                VALUES (?, 'import', ?, 1000, 'audio/x.ogg', 'x', 't', ?, ?)
                """, arguments: [recordingId, Date(), Date(), Date()])
        }
        #expect(try queue.read { try $0.tableExists("summary") } == false)
        let db = try AppDatabase(queue)
        #expect(try db.writer.read { try $0.tableExists("summary") })
        #expect(try db.writer.read { try Recording.fetchOne($0, key: recordingId) }?.id == recordingId)
    }

    /// X21: a library from before stars (v6) gains the column; its recordings start unstarred
    /// and keep their summaries.
    @Test func v6LibraryUpgradesToV7() throws {
        let queue = try DatabaseQueue()
        try AppDatabase.migrator.migrate(queue, upTo: "v6")
        let recordingId = UUID()
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO recording (id, source, started_at, duration_ms, audio_path, audio_sha256, title,
                                       created_at, updated_at)
                VALUES (?, 'import', ?, 1000, 'audio/x.ogg', 'x', 't', ?, ?)
                """, arguments: [recordingId, Date(), Date(), Date()])
            try db.execute(sql: """
                INSERT INTO summary (recording_id, scene, title, summary, sections, todos, tags, people, model,
                                     created_at)
                VALUES (?, 'meeting', 'T', 'S', '[]', '[{"text":"a","done":false}]', '[]', '[]', 'm', ?)
                """, arguments: [recordingId, Date()])
        }
        #expect(try queue.read { try $0.columns(in: "recording") }.contains { $0.name == "starred_at" } == false)
        let db = try AppDatabase(queue)
        let recording = try #require(try db.writer.read { try Recording.fetchOne($0, key: recordingId) })
        #expect(!recording.isStarred)
        #expect(try db.writer.read { try Summary.fetchOne($0, key: recordingId) }?.todos.map(\.text) == ["a"])
    }

    @Test func onDiskDatabaseIsCreatedInGivenDirectory() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try AppDatabase.onDisk(directory: dir)
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("library.sqlite").path))
    }
}

struct RecordingLibraryTests {
    private func makeLibrary() throws -> (RecordingLibrary, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lib-\(UUID().uuidString)")
        return (RecordingLibrary(database: try AppDatabase.inMemory(), store: try AudioStore(root: root)), root)
    }

    private func recording(_ id: UUID, device: UUID, path: String) -> Recording {
        Recording(id: id, deviceId: device, source: .card, cardFileName: "a.opus", cardFileSize: 10,
                  startedAt: Date(), durationMs: 20, audioPath: path, audioSha256: "x", title: "t",
                  createdAt: Date(), updatedAt: Date())
    }

    /// prd.md §5 (#85): a library from the first TestFlight build (v1) upgrades through every
    /// later migration with its rows intact, and gains every new table.
    @Test func v1LibraryUpgradesToTheLatest() throws {
        let queue = try DatabaseQueue()
        try AppDatabase.migrator.migrate(queue, upTo: "v1")
        let deviceId = UUID()
        let recordingId = UUID()
        try queue.write { db in
            try db.execute(sql: "INSERT INTO device (id, sn, name, firmware) VALUES (?, 'S', 'card', '1.50')",
                           arguments: [deviceId])
            try db.execute(sql: """
                INSERT INTO recording (id, device_id, source, card_file_name, card_file_size, started_at,
                                       duration_ms, audio_path, audio_sha256, title, created_at, updated_at)
                VALUES (?, ?, 'card', 'a.opus', 10, ?, 20, 'audio/x.ogg', 'h', '2026-11-07 14:02', ?, ?)
                """, arguments: [recordingId, deviceId, Date(), Date(), Date()])
            try db.execute(sql: """
                INSERT INTO sync_item (device_id, card_file_name, card_file_size, state, attempts, recording_id)
                VALUES (?, 'a.opus', 10, 'stored', 0, ?)
                """, arguments: [deviceId, recordingId])
        }
        let db = try AppDatabase(queue)
        let applied = try db.writer.read { try AppDatabase.migrator.appliedIdentifiers($0) }
        #expect(applied == Set(AppDatabase.migrator.migrations))
        for table in ["recording_mark", "discard_request", "transcript", "summary", "folder"] {
            #expect(try db.writer.read { try $0.tableExists(table) }, "table \(table)")
        }
        let recording = try #require(try db.writer.read { try Recording.fetchOne($0, key: recordingId) })
        #expect(recording.title == "2026-11-07 14:02" && recording.trashedAt == nil && !recording.hasCustomTitle)
        #expect(!recording.isStarred)
        #expect(try db.writer.read { try SyncItem.fetchOne($0) }?.state == .stored)
    }

    @Test func v1CreatesTables() throws {
        let db = try AppDatabase.inMemory()
        for table in ["device", "recording", "sync_item"] {
            #expect(try db.writer.read { try $0.tableExists(table) })
        }
    }

    @Test func syncItemKeyIsDeviceNameAndSize() throws {
        let (lib, root) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let device = try lib.upsertDevice(sn: "S") { $0.name = "card"; $0.firmware = "1.50" }
        let a = try lib.syncItem(deviceId: device.id, name: "x.opus", size: 10)
        let again = try lib.syncItem(deviceId: device.id, name: "x.opus", size: 10)
        let other = try lib.syncItem(deviceId: device.id, name: "x.opus", size: 11)
        #expect(a.id == again.id && a.id != other.id)
        #expect(try lib.upsertDevice(sn: "S") { _ in }.id == device.id)
    }

    @Test func commitAndDeleteKeepSyncItem() throws {
        let (lib, root) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let device = try lib.upsertDevice(sn: "S") { $0.name = "card"; $0.firmware = "1.50" }
        let item = try lib.syncItem(deviceId: device.id, name: "a.opus", size: 10)
        let id = UUID()
        let path = try lib.store.storeAudio(Data("OggS".utf8), id: id)
        let stored = try lib.commitStored(recording(id, device: device.id, path: path), item: item, deleteAfterSync: false)
        #expect(stored.state == .stored && stored.recordingId == id)
        try Data("pcm".utf8).write(to: lib.store.decodedURL(for: id))

        try lib.deleteRecording(id: id)
        #expect(!FileManager.default.fileExists(atPath: lib.store.decodedURL(for: id).path))
        #expect(try lib.recordings().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: lib.store.url(forAudioPath: path).path))
        let after = try #require(try lib.syncItems(deviceId: device.id).first)
        #expect(after.state == .stored && after.recordingId == nil)
    }

    /// D1b: trash keeps the row and the audio, restore undoes it, purge removes only what expired.
    @Test func trashRestoreAndPurge() throws {
        let (lib, root) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let device = try lib.upsertDevice(sn: "S") { $0.name = "card"; $0.firmware = "1.50" }
        let item = try lib.syncItem(deviceId: device.id, name: "a.opus", size: 10)
        let id = UUID()
        let path = try lib.store.storeAudio(Data("OggS".utf8), id: id)
        _ = try lib.commitStored(recording(id, device: device.id, path: path), item: item, deleteAfterSync: false)
        let audio = lib.store.url(forAudioPath: path).path
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)

        try lib.trashRecording(id: id, now: t0)
        #expect(try lib.trashedRecordings().map(\.id) == [id])
        #expect(try lib.recording(id: id)?.trashedAt != nil)
        #expect(FileManager.default.fileExists(atPath: audio))
        // Still a local copy, and startup recovery must not take the audio for an orphan.
        try lib.recoverAfterLaunch()
        #expect(FileManager.default.fileExists(atPath: audio))
        #expect(try lib.hasLocalCopy(try #require(try lib.syncItems(deviceId: device.id).first)))

        try lib.restoreRecording(id: id)
        #expect(try lib.trashedRecordings().isEmpty)
        #expect(try lib.recording(id: id)?.trashedAt == nil)

        try lib.trashRecording(id: id, now: t0)
        #expect(try lib.purgeTrash(trashedBefore: t0.addingTimeInterval(-1)) == 0)
        #expect(try lib.recording(id: id) != nil)
        #expect(try lib.purgeTrash(trashedBefore: t0) == 1)
        #expect(try lib.recording(id: id) == nil)
        #expect(!FileManager.default.fileExists(atPath: audio))
        // Purged like a delete: the card file is not synced again.
        let after = try #require(try lib.syncItems(deviceId: device.id).first)
        #expect(after.state == .stored && after.recordingId == nil)
    }

    /// X7: marks are keyed by the card file, so they exist before the recording does.
    @Test func marksFollowTheCardFile() throws {
        let (lib, root) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(try lib.database.writer.read { try $0.tableExists("recording_mark") })
        let device = try lib.upsertDevice(sn: "S") { $0.name = "card"; $0.firmware = "1.50" }

        #expect(try lib.addMark(deviceId: device.id, cardFileName: "a.opus", offsetMs: 9_000))
        #expect(try lib.addMark(deviceId: device.id, cardFileName: "a.opus", offsetMs: 3_000))
        #expect(try !lib.addMark(deviceId: device.id, cardFileName: "a.opus", offsetMs: 4_500))  // double tap
        #expect(try lib.addMark(deviceId: device.id, cardFileName: "a.opus", offsetMs: 60_000))
        #expect(try lib.addMark(deviceId: device.id, cardFileName: "b.opus", offsetMs: 1_000))
        #expect(try lib.marks(deviceId: device.id, cardFileName: "a.opus").map(\.offsetMs) == [3_000, 9_000, 60_000])

        // The recording arrives later; marks past its end are left out.
        let item = try lib.syncItem(deviceId: device.id, name: "a.opus", size: 10)
        let id = UUID()
        let path = try lib.store.storeAudio(Data("OggS".utf8), id: id)
        var r = recording(id, device: device.id, path: path)
        r.durationMs = 10_000
        _ = try lib.commitStored(r, item: item, deleteAfterSync: false)
        let marks = try lib.marks(for: r)
        #expect(marks.map(\.offsetMs) == [3_000, 9_000])
        try lib.deleteMark(id: try #require(marks.first?.id))
        #expect(try lib.marks(for: r).map(\.offsetMs) == [9_000])
        var imported = r
        imported.deviceId = nil
        #expect(try lib.marks(for: imported).isEmpty)
    }

    /// X10 and D1b: restoring a discarded recording calls the discard off, and the library
    /// knows when the card copy is gone (最近删除 then warns it is the last copy).
    @Test func restoreCancelsDiscardAndCardCopyIsTracked() throws {
        let (lib, root) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let device = try lib.upsertDevice(sn: "S") { $0.name = "card"; $0.firmware = "1.50" }
        let item = try lib.syncItem(deviceId: device.id, name: "a.opus", size: 10)
        let id = UUID()
        let path = try lib.store.storeAudio(Data("OggS".utf8), id: id)
        _ = try lib.commitStored(recording(id, device: device.id, path: path), item: item, deleteAfterSync: false)
        #expect(try lib.cardCopyRemains(recordingId: id))

        try lib.requestDiscard(deviceId: device.id, cardFileName: "a.opus")
        #expect(try !lib.cardCopyRemains(recordingId: id))  // queued for the card delete
        try lib.restoreRecording(id: id)
        #expect(try !lib.discardRequested(deviceId: device.id, cardFileName: "a.opus"))
        #expect(try lib.syncItems(deviceId: device.id).first?.state == .stored)
        #expect(try lib.cardCopyRemains(recordingId: id))

        var gone = try #require(try lib.syncItems(deviceId: device.id).first)
        gone.state = .deletedOnCard
        try lib.update(gone)
        #expect(try !lib.cardCopyRemains(recordingId: id))
    }

    /// X7: deleting a recording for good removes its marks, unless another recording has the
    /// same card file name.
    @Test func marksGoWithTheirRecording() throws {
        let (lib, root) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let device = try lib.upsertDevice(sn: "S") { $0.name = "card"; $0.firmware = "1.50" }
        func store(size: Int) throws -> UUID {
            let item = try lib.syncItem(deviceId: device.id, name: "a.opus", size: size)
            let id = UUID()
            let path = try lib.store.storeAudio(Data("OggS".utf8), id: id)
            _ = try lib.commitStored(recording(id, device: device.id, path: path), item: item, deleteAfterSync: false)
            return id
        }
        let first = try store(size: 10)
        let second = try store(size: 11)  // same name after a card clock reset
        try lib.addMark(deviceId: device.id, cardFileName: "a.opus", offsetMs: 0)
        try lib.deleteRecording(id: first)
        #expect(try lib.marks(deviceId: device.id, cardFileName: "a.opus").count == 1)
        try lib.deleteRecording(id: second)
        #expect(try lib.marks(deviceId: device.id, cardFileName: "a.opus").isEmpty)
    }

    /// D2: search finds words in the title, the transcript and the summary; every word must
    /// match; trashed recordings and LIKE wildcards in the query are not matched.
    @Test func searchCoversTitleTranscriptAndSummary() throws {
        let (lib, root) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let device = try lib.upsertDevice(sn: "S") { $0.name = "card"; $0.firmware = "1.50" }
        func store(_ name: String, title: String) throws -> UUID {
            let item = try lib.syncItem(deviceId: device.id, name: name, size: 10)
            let id = UUID()
            let path = try lib.store.storeAudio(Data("OggS".utf8), id: id)
            var r = recording(id, device: device.id, path: path)
            r.cardFileName = name
            r.title = title
            _ = try lib.commitStored(r, item: item, deleteAfterSync: false)
            return id
        }
        let a = try store("a.opus", title: "周会")
        let b = try store("b.opus", title: "2026-11-07 14:02")
        let c = try store("c.opus", title: "100% 完成")
        try lib.saveTranscript(Transcript(recordingId: b, engine: "t", language: "zh-CN",
                                          segments: [TranscriptSegment(startMs: 0, text: "汇款率排查")], createdAt: Date()))
        try lib.saveSummary(Summary(recordingId: a, scene: "meeting", title: "定发布日", summary: "周三发布",
                                    sections: [], todos: [SummaryTodo(text: "通知 Alice")], tags: [], people: [],
                                    model: "m", createdAt: Date()))

        #expect(try lib.searchRecordings("周会").map(\.id) == [a])
        #expect(try lib.searchRecordings("汇款").map(\.id) == [b])
        #expect(try lib.searchRecordings("alice").map(\.id) == [a])  // case-insensitive
        #expect(try lib.searchRecordings("周会 发布").map(\.id) == [a])
        #expect(try lib.searchRecordings("周会 汇款").isEmpty)  // every word must match
        #expect(try lib.searchRecordings("%").map(\.id) == [c])  // a literal percent sign
        #expect(try lib.searchRecordings("   ").isEmpty)
        try lib.trashRecording(id: a)
        #expect(try lib.searchRecordings("周会").isEmpty)
    }

    /// D1c: folders hold recordings; deleting a folder keeps its recordings; a library from
    /// before folders (v7) gains the table and keeps its recordings outside any folder.
    @Test func foldersHoldRecordings() throws {
        let (lib, root) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let device = try lib.upsertDevice(sn: "S") { $0.name = "card"; $0.firmware = "1.50" }
        let item = try lib.syncItem(deviceId: device.id, name: "a.opus", size: 10)
        let id = UUID()
        let path = try lib.store.storeAudio(Data("OggS".utf8), id: id)
        _ = try lib.commitStored(recording(id, device: device.id, path: path), item: item, deleteAfterSync: false)

        #expect(try lib.createFolder(named: "   ") == nil)
        let work = try #require(try lib.createFolder(named: " 客户 "))
        let home = try #require(try lib.createFolder(named: "家里"))
        #expect(try lib.folders().map(\.name) == ["客户", "家里"].sorted())
        try lib.moveRecording(id: id, toFolder: work.id)
        #expect(try lib.recording(id: id)?.folderId == work.id)
        try lib.renameFolder(id: work.id, to: "客户 A")
        #expect(try lib.folders().contains { $0.name == "客户 A" })
        try lib.renameFolder(id: work.id, to: "  ")
        #expect(try lib.folders().contains { $0.name == "客户 A" })  // an empty name changes nothing
        try lib.deleteFolder(id: work.id)
        #expect(try lib.recording(id: id)?.folderId == nil)  // the recording stays
        #expect(try lib.folders().map(\.id) == [home.id])
        try lib.moveRecording(id: id, toFolder: home.id)
        try lib.moveRecording(id: id, toFolder: nil)
        #expect(try lib.recording(id: id)?.folderId == nil)
    }

    @Test func v7LibraryUpgradesToV8() throws {
        let queue = try DatabaseQueue()
        try AppDatabase.migrator.migrate(queue, upTo: "v7")
        let recordingId = UUID()
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO recording (id, source, started_at, duration_ms, audio_path, audio_sha256, title,
                                       created_at, updated_at, starred_at)
                VALUES (?, 'import', ?, 1000, 'audio/x.ogg', 'x', 't', ?, ?, ?)
                """, arguments: [recordingId, Date(), Date(), Date(), Date()])
        }
        #expect(try queue.read { try $0.tableExists("folder") } == false)
        let db = try AppDatabase(queue)
        #expect(try db.writer.read { try $0.tableExists("folder") })
        let recording = try #require(try db.writer.read { try Recording.fetchOne($0, key: recordingId) })
        #expect(recording.folderId == nil && recording.isStarred)
    }

    /// X21: starring is kept across trash and restore, a second star keeps the first time, and
    /// an unknown id changes nothing.
    @Test func starRecording() throws {
        let (lib, root) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let path = try lib.store.storeAudio(Data("OggS".utf8), id: id)
        var r = recording(id, device: UUID(), path: path)
        r.deviceId = nil
        try lib.database.writer.write { db in try r.insert(db) }
        let first = Date(timeIntervalSince1970: 1_000)
        #expect(try lib.setStarred(id: id, true, now: first)?.starredAt == first)
        #expect(try lib.setStarred(id: id, true, now: first.addingTimeInterval(60))?.starredAt == first)
        try lib.trashRecording(id: id)
        try lib.restoreRecording(id: id)
        #expect(try lib.recording(id: id)?.isStarred == true)
        #expect(try lib.setStarred(id: id, false)?.isStarred == false)
        #expect(try lib.setStarred(id: UUID(), true) == nil)
    }

    /// #89 总览 and 知识库: open todos across recordings (newest recording first, summary order
    /// within one), recent summaries by summary time, and nothing from 最近删除.
    @Test func openTodosAndRecentSummaries() throws {
        let (lib, root) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        func add(startedAt: TimeInterval) throws -> UUID {
            let id = UUID()
            let path = try lib.store.storeAudio(Data("OggS".utf8), id: id)
            var r = recording(id, device: UUID(), path: path)
            r.deviceId = nil
            r.startedAt = Date(timeIntervalSince1970: startedAt)
            try lib.database.writer.write { db in try r.insert(db) }
            return id
        }
        func summarize(_ id: UUID, at: TimeInterval, todos: [SummaryTodo]) throws {
            try lib.saveSummary(Summary(recordingId: id, scene: "meeting", title: "T", summary: "S", sections: [],
                                        todos: todos, tags: [], people: [], model: "m",
                                        createdAt: Date(timeIntervalSince1970: at)))
        }
        let old = try add(startedAt: 100)
        let new = try add(startedAt: 200)
        let none = try add(startedAt: 300)
        let gone = try add(startedAt: 400)
        try summarize(old, at: 900, todos: [SummaryTodo(text: "a"), SummaryTodo(text: "b", done: true),
                                            SummaryTodo(text: "c")])
        try summarize(new, at: 800, todos: [SummaryTodo(text: "d")])
        try summarize(gone, at: 950, todos: [SummaryTodo(text: "e")])
        try lib.trashRecording(id: gone)

        let todos = try lib.openTodos()
        #expect(todos.map(\.text) == ["d", "a", "c"])
        #expect(todos.map(\.index) == [0, 0, 2])
        #expect(Set(todos.map(\.id)).count == 3)
        #expect(try lib.recordingIdsWithOpenTodos() == [old, new])
        #expect(try lib.recentSummaries().map(\.recording.id) == [old, new])
        #expect(try lib.recentSummaries(limit: 1).map(\.recording.id) == [old])

        let digest = try lib.digest()
        #expect(digest.openTodos == todos && digest.recentSummaries.count == 2)
        #expect(digest.untranscribedCount == 3)  // old, new, none; not the trashed one
        try lib.saveTranscript(Transcript(recordingId: none, engine: "t", language: "zh-CN", segments: [],
                                          createdAt: Date()))
        #expect(try lib.digest().untranscribedCount == 2)

        try lib.setTodoDone(recordingId: new, index: 0, done: true)
        #expect(try lib.recordingIdsWithOpenTodos() == [old])
        #expect(!(try lib.recentSummaries().map(\.recording.id).contains(none)))
    }

    /// X18: a phone recording keeps its M4A, gets a default title, and an orphaned M4A (crash
    /// between the move and the insert) is removed at launch like an orphaned OGG.
    @Test func phoneRecordingsAreStoredAsM4A() throws {
        let (lib, root) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("phone-\(UUID().uuidString).m4a")
        try Data("m4a".utf8).write(to: file)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let stored = try lib.addPhoneRecording(file: file, startedAt: start, durationMs: 3_000)
        #expect(stored.source == .phone && stored.deviceId == nil && stored.cardFileName == nil)
        #expect(stored.audioPath.hasSuffix(".m4a") && !stored.hasCustomTitle)
        #expect(!FileManager.default.fileExists(atPath: file.path))  // moved, not copied
        let audio = lib.store.url(forAudioPath: stored.audioPath)
        #expect(FileManager.default.fileExists(atPath: audio.path))

        let orphan = lib.store.url(forAudioPath: "audio/\(UUID().uuidString).m4a")
        try Data("x".utf8).write(to: orphan)
        try lib.recoverAfterLaunch()
        #expect(!FileManager.default.fileExists(atPath: orphan.path))
        #expect(FileManager.default.fileExists(atPath: audio.path))
    }

    /// X6: rename trims, caps the length and falls back to the default title.
    @Test func renameRecording() throws {
        let (lib, root) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let device = try lib.upsertDevice(sn: "S") { $0.name = "card"; $0.firmware = "1.50" }
        let item = try lib.syncItem(deviceId: device.id, name: "a.opus", size: 10)
        let id = UUID()
        let path = try lib.store.storeAudio(Data("OggS".utf8), id: id)
        var r = recording(id, device: device.id, path: path)
        r.title = Recording.defaultTitle(for: r.startedAt)
        _ = try lib.commitStored(r, item: item, deleteAfterSync: false)
        #expect(!r.hasCustomTitle)

        #expect(try lib.renameRecording(id: id, to: "  周会  ")?.title == "周会")
        #expect(try #require(try lib.recording(id: id)).hasCustomTitle)
        #expect(try lib.renameRecording(id: id, to: String(repeating: "长", count: 200))?.title.count == 80)
        let reset = try #require(try lib.renameRecording(id: id, to: "   "))
        #expect(reset.title == Recording.defaultTitle(for: r.startedAt) && !reset.hasCustomTitle)
        #expect(try lib.renameRecording(id: UUID(), to: "x") == nil)
    }

    /// G1: a summary round-trips its JSON columns, is replaced on save, keeps todo ticks, and
    /// goes away with its recording.
    @Test func summaryIsStoredAndFollowsTheRecording() throws {
        let (lib, root) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(try lib.database.writer.read { try $0.tableExists("summary") })
        let device = try lib.upsertDevice(sn: "S") { $0.name = "card"; $0.firmware = "1.50" }
        let item = try lib.syncItem(deviceId: device.id, name: "a.opus", size: 10)
        let id = UUID()
        let path = try lib.store.storeAudio(Data("OggS".utf8), id: id)
        _ = try lib.commitStored(recording(id, device: device.id, path: path), item: item, deleteAfterSync: false)
        #expect(try lib.summary(recordingId: id) == nil)

        let created = Date(timeIntervalSince1970: 1_800_000_000)
        let first = Summary(
            recordingId: id, scene: "meeting", title: "周会排期", summary: "下周三上线。",
            sections: [SummarySection(heading: "结论与决定", items: ["下周三上线", "老王负责测试"])],
            todos: [SummaryTodo(text: "老王周二前测完"), SummaryTodo(text: "小李发通知", done: true)],
            tags: ["排期", "上线"], people: ["老王", "小李"], model: "deepseek-chat", createdAt: created)
        try lib.saveSummary(first)
        #expect(try lib.summary(recordingId: id) == first)

        let ticked = try #require(try lib.setTodoDone(recordingId: id, index: 0, done: true))
        #expect(ticked.todos.map(\.done) == [true, true])
        #expect(try lib.summary(recordingId: id)?.todos.map(\.done) == [true, true])
        #expect(try lib.setTodoDone(recordingId: id, index: 5, done: true) == nil)
        #expect(try lib.setTodoDone(recordingId: UUID(), index: 0, done: true) == nil)

        var second = first
        second.title = "重新生成"
        second.todos = []
        try lib.saveSummary(second)
        #expect(try lib.summary(recordingId: id) == second)

        try lib.deleteRecording(id: id)
        #expect(try lib.summary(recordingId: id) == nil)
    }

    @Test func recoveryResetsDownloadsAndRemovesOrphans() throws {
        let (lib, root) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let device = try lib.upsertDevice(sn: "S") { $0.name = "card"; $0.firmware = "1.50" }
        var item = try lib.syncItem(deviceId: device.id, name: "a.opus", size: 10)
        item.state = .downloading
        try lib.update(item)
        let writer = try lib.store.openPart(item.id!)
        try writer.append(Data([1, 2, 3]))
        writer.close()
        let kept = UUID()
        let keptPath = try lib.store.storeAudio(Data("keep".utf8), id: kept)
        let item2 = try lib.syncItem(deviceId: device.id, name: "b.opus", size: 4)
        _ = try lib.commitStored(recording(kept, device: device.id, path: keptPath), item: item2, deleteAfterSync: false)
        let orphan = try lib.store.storeAudio(Data("orphan".utf8), id: UUID())
        // Decoded copies: one kept, one for a deleted recording, one unfinished decode.
        let keptDecoded = lib.store.decodedURL(for: kept)
        let orphanDecoded = lib.store.decodedURL(for: UUID())
        let unfinished = keptDecoded.deletingLastPathComponent().appendingPathComponent("\(UUID().uuidString).part")
        for url in [keptDecoded, orphanDecoded, unfinished] { try Data("pcm".utf8).write(to: url) }

        try lib.recoverAfterLaunch()
        #expect(FileManager.default.fileExists(atPath: keptDecoded.path))
        #expect(!FileManager.default.fileExists(atPath: orphanDecoded.path))
        #expect(!FileManager.default.fileExists(atPath: unfinished.path))
        #expect(try lib.syncItems(deviceId: device.id).first { $0.cardFileName == "a.opus" }?.state == .discovered)
        #expect(lib.store.partLength(item.id!) == 0)
        #expect(!FileManager.default.fileExists(atPath: lib.store.url(forAudioPath: orphan).path))
        #expect(FileManager.default.fileExists(atPath: lib.store.url(forAudioPath: keptPath).path))
    }
}
