// Local database (prd.md §5, ADR-007). Tables are added as versioned migrations;
// existing migrations are never edited, only appended.

import Foundation
import GRDB

public final class AppDatabase: Sendable {
    public let writer: any DatabaseWriter

    public init(_ writer: any DatabaseWriter) throws {
        self.writer = writer
        try Self.migrator.migrate(writer)
    }

    static var migrator: DatabaseMigrator {
        // Never enable eraseDatabaseOnSchemaChange, not even in DEBUG: debug builds are
        // used with real cards, and wiping the library after delete-after-sync would
        // lose recordings whose only other copy is already gone (CLAUDE.md rule 2).
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1") { db in
            try db.create(table: "device") { t in
                t.primaryKey("id", .blob)
                t.column("peripheral_id", .text)
                t.column("sn", .text).notNull().unique()
                t.column("name", .text).notNull()
                t.column("firmware", .text).notNull()
                t.column("paired_at", .datetime)
                t.column("last_seen_at", .datetime)
                t.column("battery", .integer)
                t.column("free_mb", .integer)
                t.column("total_mb", .integer)
                t.column("remote_id", .text)
            }
            try db.create(table: "recording") { t in
                t.primaryKey("id", .blob)
                t.column("device_id", .blob).references("device", onDelete: .setNull)
                t.column("source", .text).notNull()
                t.column("card_file_name", .text)
                t.column("card_file_size", .integer)
                t.column("started_at", .datetime).notNull()
                t.column("duration_ms", .integer).notNull()
                t.column("audio_path", .text).notNull()
                t.column("audio_sha256", .text).notNull()
                t.column("title", .text).notNull()
                t.column("created_at", .datetime).notNull()
                t.column("updated_at", .datetime).notNull()
                // Reserved for M4 (folders, trash) and M2/M4 (backend sync).
                t.column("folder_id", .blob)
                t.column("trashed_at", .datetime)
                t.column("remote_id", .text)
                t.column("remote_version", .integer)
            }
            try db.create(table: "sync_item") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("device_id", .blob).notNull().references("device", onDelete: .restrict)
                t.column("card_file_name", .text).notNull()
                t.column("card_file_size", .integer).notNull()
                t.column("state", .text).notNull()
                t.column("attempts", .integer).notNull().defaults(to: 0)
                t.column("last_error", .text)
                // A recording deleted in the app leaves its SyncItem `stored` (prd.md §4.3).
                t.column("recording_id", .blob).references("recording", onDelete: .setNull)
                t.column("deleted_on_card_at", .datetime)
                t.uniqueKey(["device_id", "card_file_name", "card_file_size"])
            }
        }

        // The build a `decryptFailed` item last failed in: a newer build retries it once (#59).
        migrator.registerMigration("v2") { db in
            try db.alter(table: "sync_item") { t in
                t.add(column: "failed_build", .text)
            }
        }

        // Marks set while recording (features.md X7), keyed by the card file like SyncItem, so a
        // mark made before the file is synced finds its recording later.
        migrator.registerMigration("v3") { db in
            try db.create(table: "recording_mark") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("device_id", .blob).notNull().references("device", onDelete: .cascade)
                t.column("card_file_name", .text).notNull()
                t.column("offset_ms", .integer).notNull()
                t.column("created_at", .datetime).notNull()
            }
            try db.create(index: "recording_mark_file", on: "recording_mark", columns: ["device_id", "card_file_name"])
        }

        // "不要这条" (features.md X10): the user does not want a card file. The request waits for
        // the file to be stored, then the recording goes to 最近删除 and the card copy is deleted.
        migrator.registerMigration("v4") { db in
            try db.create(table: "discard_request") { t in
                t.column("device_id", .blob).notNull().references("device", onDelete: .cascade)
                t.column("card_file_name", .text).notNull()
                t.column("created_at", .datetime).notNull()
                t.primaryKey(["device_id", "card_file_name"])
            }
        }

        // Text of a recording (features.md X9, later F1). One per recording; removed with it.
        migrator.registerMigration("v5") { db in
            try db.create(table: "transcript") { t in
                t.primaryKey("recording_id", .blob).references("recording", onDelete: .cascade)
                t.column("engine", .text).notNull()
                t.column("language", .text).notNull()
                t.column("segments", .text).notNull()
                t.column("created_at", .datetime).notNull()
            }
        }

        // Summary of a recording (features.md G1, G2a). One per recording; removed with it.
        // The list columns hold JSON.
        migrator.registerMigration("v6") { db in
            try db.create(table: "summary") { t in
                t.primaryKey("recording_id", .blob).references("recording", onDelete: .cascade)
                t.column("scene", .text).notNull()
                t.column("title", .text).notNull()
                t.column("summary", .text).notNull()
                t.column("sections", .text).notNull()
                t.column("todos", .text).notNull()
                t.column("tags", .text).notNull()
                t.column("people", .text).notNull()
                t.column("model", .text).notNull()
                t.column("created_at", .datetime).notNull()
            }
        }

        // Star a recording (features.md X21). Null means not starred.
        migrator.registerMigration("v7") { db in
            try db.alter(table: "recording") { t in
                t.add(column: "starred_at", .datetime)
            }
        }

        // Folders (features.md D1c). `recording.folder_id`, reserved in v1, points here; a deleted
        // folder leaves its recordings in place, outside any folder.
        migrator.registerMigration("v8") { db in
            try db.create(table: "folder") { t in
                t.primaryKey("id", .blob)
                t.column("name", .text).notNull()
                t.column("created_at", .datetime).notNull()
            }
        }

        // Who set the title (features.md G1, X6): "user" after a rename, "ai" from the user's AI
        // service, null for the default date title. A title the user typed is never replaced by
        // an AI one; telling them apart by the shape of the title is not enough once AI titles
        // exist. Rows renamed before v9 keep null and still count as the user's by their shape.
        migrator.registerMigration("v9") { db in
            try db.alter(table: "recording") { t in
                t.add(column: "title_source", .text)
            }
        }

        // Outline and quotes of a summary (features.md G1 大纲、金句). JSON like the other list
        // columns; summaries from before get empty lists.
        migrator.registerMigration("v10") { db in
            try db.alter(table: "summary") { t in
                t.add(column: "outline", .text).notNull().defaults(to: "[]")
                t.add(column: "quotes", .text).notNull().defaults(to: "[]")
            }
        }

        // 纠错词库 (#75): words the user corrected in a transcript, replaced in later ones.
        migrator.registerMigration("v11") { db in
            try db.create(table: "correction") { t in
                t.primaryKey("wrong", .text)
                t.column("right", .text).notNull()
                t.column("created_at", .datetime).notNull()
            }
        }

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
