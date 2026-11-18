import Foundation
import GRDB

// Rows of prd.md §5. Column names are snake_case in the database.

/// A card this phone has synced from. The bondId is not here: it lives in the Keychain.
public struct Device: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    public var id: UUID
    public var peripheralId: String?
    public var sn: String
    public var name: String
    public var firmware: String
    public var pairedAt: Date?
    public var lastSeenAt: Date?
    public var battery: Int?
    public var freeMb: Int?
    public var totalMb: Int?
    public var remoteId: String?

    public init(id: UUID = UUID(), peripheralId: String? = nil, sn: String, name: String, firmware: String,
                pairedAt: Date? = nil, lastSeenAt: Date? = nil, battery: Int? = nil, freeMb: Int? = nil,
                totalMb: Int? = nil, remoteId: String? = nil) {
        self.id = id
        self.peripheralId = peripheralId
        self.sn = sn
        self.name = name
        self.firmware = firmware
        self.pairedAt = pairedAt
        self.lastSeenAt = lastSeenAt
        self.battery = battery
        self.freeMb = freeMb
        self.totalMb = totalMb
        self.remoteId = remoteId
    }

    public static let databaseTableName = "device"
    public static let databaseColumnDecodingStrategy = DatabaseColumnDecodingStrategy.convertFromSnakeCase
    public static let databaseColumnEncodingStrategy = DatabaseColumnEncodingStrategy.convertToSnakeCase
}

public struct Recording: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    public enum Source: String, Codable, Sendable {
        case card, `import`, realtime
    }

    /// Also the audio file name: `audio/<id>.ogg`.
    public var id: UUID
    public var deviceId: UUID?
    public var source: Source
    public var cardFileName: String?
    public var cardFileSize: Int?
    public var startedAt: Date
    public var durationMs: Int
    /// Relative to the library's root directory.
    public var audioPath: String
    public var audioSha256: String
    public var title: String
    public var createdAt: Date
    public var updatedAt: Date
    public var folderId: UUID?
    public var trashedAt: Date?
    public var remoteId: String?
    public var remoteVersion: Int?

    public init(id: UUID = UUID(), deviceId: UUID?, source: Source, cardFileName: String?, cardFileSize: Int?,
                startedAt: Date, durationMs: Int, audioPath: String, audioSha256: String, title: String,
                createdAt: Date, updatedAt: Date) {
        self.id = id
        self.deviceId = deviceId
        self.source = source
        self.cardFileName = cardFileName
        self.cardFileSize = cardFileSize
        self.startedAt = startedAt
        self.durationMs = durationMs
        self.audioPath = audioPath
        self.audioSha256 = audioSha256
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public static let databaseTableName = "recording"
    public static let databaseColumnDecodingStrategy = DatabaseColumnDecodingStrategy.convertFromSnakeCase
    public static let databaseColumnEncodingStrategy = DatabaseColumnEncodingStrategy.convertToSnakeCase
}

extension Recording {
    /// How long a deleted recording stays in 最近删除 before it is removed for good (features.md D1b).
    public static let trashRetention: TimeInterval = 7 * 86_400

    /// The title sync gives a recording: "2026-11-07 14:02" in the phone's zone.
    public static func defaultTitle(for date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: date)
    }

    /// True once the user has renamed the recording (features.md X6). Told by the shape of the
    /// title, not by comparing with `startedAt`, so a phone that changed time zone still agrees.
    public var hasCustomTitle: Bool {
        !title.isEmpty
            && title.range(of: #"^\d{4}-\d{2}-\d{2} \d{2}:\d{2}$"#, options: .regularExpression) == nil
    }
}

/// A point the user marked while recording (features.md X7): `offsetMs` into the audio of the
/// card file `cardFileName` on `deviceId`.
public struct RecordingMark: Codable, Equatable, Sendable, Identifiable, FetchableRecord, MutablePersistableRecord {
    public var id: Int64?
    public var deviceId: UUID
    public var cardFileName: String
    public var offsetMs: Int
    public var createdAt: Date

    public init(deviceId: UUID, cardFileName: String, offsetMs: Int, createdAt: Date) {
        self.deviceId = deviceId
        self.cardFileName = cardFileName
        self.offsetMs = offsetMs
        self.createdAt = createdAt
    }

    public static let databaseTableName = "recording_mark"
    public static let databaseColumnDecodingStrategy = DatabaseColumnDecodingStrategy.convertFromSnakeCase
    public static let databaseColumnEncodingStrategy = DatabaseColumnEncodingStrategy.convertToSnakeCase

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

/// One sentence of a transcript, with where it starts in the audio.
public struct TranscriptSegment: Codable, Equatable, Sendable {
    public var startMs: Int
    public var text: String

    public init(startMs: Int, text: String) {
        self.startMs = startMs
        self.text = text
    }
}

/// The text of a recording (features.md X9). `segments` is stored as JSON.
public struct Transcript: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    public var recordingId: UUID
    /// What produced it: "on-device" for the system recognizer on this phone.
    public var engine: String
    public var language: String
    public var segments: [TranscriptSegment]
    public var createdAt: Date

    public init(recordingId: UUID, engine: String, language: String, segments: [TranscriptSegment], createdAt: Date) {
        self.recordingId = recordingId
        self.engine = engine
        self.language = language
        self.segments = segments
        self.createdAt = createdAt
    }

    public static let databaseTableName = "transcript"
    public static let databaseColumnDecodingStrategy = DatabaseColumnDecodingStrategy.convertFromSnakeCase
    public static let databaseColumnEncodingStrategy = DatabaseColumnEncodingStrategy.convertToSnakeCase
}

/// One headed block of a summary, such as 「结论与决定」 for a meeting.
public struct SummarySection: Codable, Equatable, Sendable {
    public var heading: String
    public var items: [String]

    public init(heading: String, items: [String]) {
        self.heading = heading
        self.items = items
    }
}

/// A follow-up the summary found; `done` is set by the user.
public struct SummaryTodo: Codable, Equatable, Sendable {
    public var text: String
    public var done: Bool

    public init(text: String, done: Bool = false) {
        self.text = text
        self.done = done
    }
}

/// The summary of a recording (features.md G1, G2a). One per recording; removed with it.
/// `sections`, `todos`, `tags` and `people` are stored as JSON.
public struct Summary: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    public var recordingId: UUID
    /// Scene code, such as "meeting" (the raw value of Assistant's `Scene`).
    public var scene: String
    public var title: String
    public var summary: String
    public var sections: [SummarySection]
    public var todos: [SummaryTodo]
    public var tags: [String]
    public var people: [String]
    /// What produced it: the model name, or "keywords" for the rule-based fallback.
    public var model: String
    public var createdAt: Date

    public init(recordingId: UUID, scene: String, title: String, summary: String, sections: [SummarySection],
                todos: [SummaryTodo], tags: [String], people: [String], model: String, createdAt: Date) {
        self.recordingId = recordingId
        self.scene = scene
        self.title = title
        self.summary = summary
        self.sections = sections
        self.todos = todos
        self.tags = tags
        self.people = people
        self.model = model
        self.createdAt = createdAt
    }

    public static let databaseTableName = "summary"
    public static let databaseColumnDecodingStrategy = DatabaseColumnDecodingStrategy.convertFromSnakeCase
    public static let databaseColumnEncodingStrategy = DatabaseColumnEncodingStrategy.convertToSnakeCase
}

/// States of prd.md §4.1.
public enum SyncState: String, Codable, Sendable, CaseIterable {
    case discovered, downloading, stored, deletePending, deletedOnCard, failed

    /// The file is safely in the library; never download it again.
    public var isStoredOrLater: Bool {
        switch self {
        case .stored, .deletePending, .deletedOnCard: true
        case .discovered, .downloading, .failed: false
        }
    }
}

/// One card file, keyed by (device, name, size) (prd.md §4.3).
public struct SyncItem: Codable, Equatable, Sendable, FetchableRecord, MutablePersistableRecord {
    public var id: Int64?
    public var deviceId: UUID
    public var cardFileName: String
    public var cardFileSize: Int
    public var state: SyncState
    public var attempts: Int
    /// App error code of the last failure (prd.md §6).
    public var lastError: String?
    public var recordingId: UUID?
    public var deletedOnCardAt: Date?
    /// App build that recorded a `decryptFailed`; nil for other failures and for rows from
    /// before migration v2. A different build retries the file once (#59).
    public var failedBuild: String?

    public init(deviceId: UUID, cardFileName: String, cardFileSize: Int, state: SyncState = .discovered) {
        self.deviceId = deviceId
        self.cardFileName = cardFileName
        self.cardFileSize = cardFileSize
        self.state = state
        self.attempts = 0
    }

    public static let databaseTableName = "sync_item"
    public static let databaseColumnDecodingStrategy = DatabaseColumnDecodingStrategy.convertFromSnakeCase
    public static let databaseColumnEncodingStrategy = DatabaseColumnEncodingStrategy.convertToSnakeCase

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
