// Local database (prd.md §5, ADR-007). Tables are added as versioned
// migrations in #39; existing migrations are never edited, only appended.

import Foundation
import GRDB

public final class AppDatabase: Sendable {
    public let writer: any DatabaseWriter

    public init(_ writer: any DatabaseWriter) throws {
        self.writer = writer
        try Self.migrator.migrate(writer)
    }

    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        #if DEBUG
        // Surface schema mistakes during development instead of migrating around them.
        migrator.eraseDatabaseOnSchemaChange = true
        #endif
        return migrator
    }

    /// On-disk database in Application Support (not Documents: prd.md §5).
    public static func onDisk(directory: URL) throws -> AppDatabase {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let pool = try DatabasePool(path: directory.appendingPathComponent("library.sqlite").path)
        return try AppDatabase(pool)
    }

    /// In-memory database for tests.
    public static func inMemory() throws -> AppDatabase {
        try AppDatabase(DatabaseQueue())
    }
}
