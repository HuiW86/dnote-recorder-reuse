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
