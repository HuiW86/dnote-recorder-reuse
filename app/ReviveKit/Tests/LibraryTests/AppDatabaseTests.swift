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

        try lib.deleteRecording(id: id)
        #expect(try lib.recordings().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: lib.store.url(forAudioPath: path).path))
        let after = try #require(try lib.syncItems(deviceId: device.id).first)
        #expect(after.state == .stored && after.recordingId == nil)
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

        try lib.recoverAfterLaunch()
        #expect(try lib.syncItems(deviceId: device.id).first { $0.cardFileName == "a.opus" }?.state == .discovered)
        #expect(lib.store.partLength(item.id!) == 0)
        #expect(!FileManager.default.fileExists(atPath: lib.store.url(forAudioPath: orphan).path))
        #expect(FileManager.default.fileExists(atPath: lib.store.url(forAudioPath: keptPath).path))
    }
}
