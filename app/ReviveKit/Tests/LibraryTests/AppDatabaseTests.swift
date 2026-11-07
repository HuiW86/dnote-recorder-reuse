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
