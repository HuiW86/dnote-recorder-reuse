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
    /// End of the last sync pass that ran to completion on this card (migration v13); nil until
    /// one does. `lastSeenAt` is when a pass reached the card, finished or not.
    public var lastSyncedAt: Date?

    public init(id: UUID = UUID(), peripheralId: String? = nil, sn: String, name: String, firmware: String,
                pairedAt: Date? = nil, lastSeenAt: Date? = nil, battery: Int? = nil, freeMb: Int? = nil,
                totalMb: Int? = nil, remoteId: String? = nil, lastSyncedAt: Date? = nil) {
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
        self.lastSyncedAt = lastSyncedAt
    }

    public static let databaseTableName = "device"
    public static let databaseColumnDecodingStrategy = DatabaseColumnDecodingStrategy.convertFromSnakeCase
    public static let databaseColumnEncodingStrategy = DatabaseColumnEncodingStrategy.convertToSnakeCase
}

public struct Recording: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    /// False for an imported text file (features.md E2): no audio, only its transcript.
    /// `audioPath` is then empty, `durationMs` 0 and `audioSha256` empty.
    public var hasAudio: Bool { !audioPath.isEmpty }

    public enum Source: String, Codable, Sendable {
        case card, `import`, realtime
        /// Recorded with the phone's microphone (features.md X18); stored as AAC `.m4a`.
        case phone
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
    /// When the user starred it (features.md X21); nil when not starred.
    public var starredAt: Date?
    /// Who set `title`; nil for the default date title (features.md G1, X6).
    public var titleSource: TitleSource?

    public enum TitleSource: String, Codable, Sendable {
        /// Renamed by the user: never replaced by an AI title on its own.
        case user
        /// From the user's AI service; replaced by the next summary's title.
        case ai
    }

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

    public var isStarred: Bool { starredAt != nil }

    /// True once the user has renamed the recording (features.md X6). Rows from before
    /// `titleSource` (v9) are told by the shape of the title, not by comparing with `startedAt`,
    /// so a phone that changed time zone still agrees.
    public var hasCustomTitle: Bool {
        switch titleSource {
        case .user: true
        case .ai: false
        case nil:
            !title.isEmpty
                && title.range(of: #"^\d{4}-\d{2}-\d{2} \d{2}:\d{2}$"#, options: .regularExpression) == nil
        }
    }

    /// The title came from the user's AI service (features.md G1).
    public var hasAITitle: Bool { titleSource == .ai }
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

/// A point marked while recording with the phone (features.md X7, X18). A phone recording has no
/// card file, so its marks hang off the recording itself and go with it (`recording_id` cascades).
public struct PhoneMark: Codable, Equatable, Sendable, Identifiable, FetchableRecord, MutablePersistableRecord {
    public var id: Int64?
    public var recordingId: UUID
    public var offsetMs: Int
    public var createdAt: Date

    public init(recordingId: UUID, offsetMs: Int, createdAt: Date) {
        self.recordingId = recordingId
        self.offsetMs = offsetMs
        self.createdAt = createdAt
    }

    public static let databaseTableName = "phone_mark"
    public static let databaseColumnDecodingStrategy = DatabaseColumnDecodingStrategy.convertFromSnakeCase
    public static let databaseColumnEncodingStrategy = DatabaseColumnEncodingStrategy.convertToSnakeCase

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

/// A mark as playback shows it, whichever recording it came from: a card's `RecordingMark` or a
/// phone's `PhoneMark`.
public struct PlaybackMark: Equatable, Identifiable, Sendable {
    /// "card-3", "phone-3": the two tables number their rows separately.
    public let id: String
    public let offsetMs: Int

    public init(id: String, offsetMs: Int) {
        self.id = id
        self.offsetMs = offsetMs
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
    /// The lines as transcribed, kept after 逐句润色 (#75) replaced the text of `segments` so the
    /// user can go back to them; nil when the text was never polished. Same count and times.
    public var originalSegments: [TranscriptSegment]?

    public init(recordingId: UUID, engine: String, language: String, segments: [TranscriptSegment], createdAt: Date,
                originalSegments: [TranscriptSegment]? = nil) {
        self.recordingId = recordingId
        self.engine = engine
        self.language = language
        self.segments = segments
        self.createdAt = createdAt
        self.originalSegments = originalSegments
    }

    /// True when the text shown is the polished one.
    public var isPolished: Bool { originalSegments != nil }

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

/// One topic of a summary's outline (features.md G1 大纲, also drawn as 思维导图), in the order
/// the recording took it up.
public struct OutlineItem: Codable, Equatable, Sendable {
    public var title: String
    public var points: [String]

    public init(title: String, points: [String]) {
        self.title = title
        self.points = points
    }
}

/// A CEFR level, A1 (easiest) to C2 (hardest), for 单词分级 (features.md X20).
public enum WordLevel: String, Codable, CaseIterable, Comparable, Sendable {
    case a1 = "A1", a2 = "A2", b1 = "B1", b2 = "B2", c1 = "C1", c2 = "C2"

    public static func < (a: WordLevel, b: WordLevel) -> Bool {
        allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)!
    }

    /// "B2", " b2 ", "B2 中高级" → .b2; nil when no level is named.
    public init?(loosely text: String) {
        let upper = text.uppercased()
        guard let level = Self.allCases.first(where: { upper.contains($0.rawValue) }) else { return nil }
        self = level
    }
}

/// One word worth learning in a foreign-language transcript (features.md X20 单词分级).
public struct StudyWord: Codable, Equatable, Hashable, Sendable {
    public var word: String
    public var level: WordLevel
    /// What it means here, in Simplified Chinese.
    public var meaning: String
    /// The transcript line it was heard in.
    public var segmentIndex: Int

    public init(word: String, level: WordLevel, meaning: String, segmentIndex: Int) {
        self.word = word
        self.level = level
        self.meaning = meaning
        self.segmentIndex = segmentIndex
    }
}

/// The words of one recording (migration v15), made once by the user's service and kept;
/// removed with the recording. `words` is JSON.
public struct WordList: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    public var recordingId: UUID
    public var words: [StudyWord]
    public var model: String
    public var createdAt: Date

    public init(recordingId: UUID, words: [StudyWord], model: String, createdAt: Date = Date()) {
        self.recordingId = recordingId
        self.words = words
        self.model = model
        self.createdAt = createdAt
    }

    public static let databaseTableName = "word_list"
    public static let databaseColumnDecodingStrategy = DatabaseColumnDecodingStrategy.convertFromSnakeCase
    public static let databaseColumnEncodingStrategy = DatabaseColumnEncodingStrategy.convertToSnakeCase
}

/// The summary of a recording (features.md G1, G2a). One per recording; removed with it.
/// `sections`, `todos`, `tags`, `people`, `outline` and `quotes` are stored as JSON.
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
    /// Topics in the order discussed (G1 大纲); empty for summaries from before v10.
    public var outline: [OutlineItem]
    /// Sentences worth keeping, quoted as said (G1 金句); empty for summaries from before v10.
    public var quotes: [String]
    /// What produced it: the model name, or "keywords" for the rule-based fallback.
    public var model: String
    public var createdAt: Date

    public init(recordingId: UUID, scene: String, title: String, summary: String, sections: [SummarySection],
                todos: [SummaryTodo], tags: [String], people: [String], outline: [OutlineItem] = [],
                quotes: [String] = [], model: String, createdAt: Date) {
        self.recordingId = recordingId
        self.scene = scene
        self.title = title
        self.summary = summary
        self.sections = sections
        self.todos = todos
        self.tags = tags
        self.people = people
        self.outline = outline
        self.quotes = quotes
        self.model = model
        self.createdAt = createdAt
    }

    public static let databaseTableName = "summary"
    public static let databaseColumnDecodingStrategy = DatabaseColumnDecodingStrategy.convertFromSnakeCase
    public static let databaseColumnEncodingStrategy = DatabaseColumnEncodingStrategy.convertToSnakeCase
}

/// A word the user corrected in a transcript (纠错词库, #75): `wrong` is replaced by `right` in
/// transcripts made afterwards.
public struct Correction: Codable, Equatable, Hashable, Sendable, Identifiable, FetchableRecord, PersistableRecord {
    public var wrong: String
    public var right: String
    public var createdAt: Date

    public var id: String { wrong }

    public init(wrong: String, right: String, createdAt: Date = Date()) {
        self.wrong = wrong
        self.right = right
        self.createdAt = createdAt
    }

    public static let databaseTableName = "correction"
    public static let databaseColumnDecodingStrategy = DatabaseColumnDecodingStrategy.convertFromSnakeCase
    public static let databaseColumnEncodingStrategy = DatabaseColumnEncodingStrategy.convertToSnakeCase

    /// The part `edited` changed in `original`, when it is a short word swap: the common start
    /// and end are dropped, then the span is widened with unchanged neighbours (the next
    /// character first) until both sides have at least 2 characters, so one misheard character
    /// is not replaced everywhere ("汇款" → "回款", not "汇" → "回"). Both sides must then be
    /// 2 to 12 characters and differ. Nil for a rewrite, a pure insertion or a pure deletion.
    public static func between(_ original: String, _ edited: String) -> (wrong: String, right: String)? {
        let a = Array(original), b = Array(edited)
        var start = 0
        while start < a.count, start < b.count, a[start] == b[start] { start += 1 }
        var endA = a.count, endB = b.count
        while endA > start, endB > start, a[endA - 1] == b[endB - 1] {
            endA -= 1
            endB -= 1
        }
        // A pure insertion or deletion: one side is empty.
        guard endA > start, endB > start else { return nil }
        while endA - start < 2 || endB - start < 2 {
            if endA < a.count, endB < b.count {
                endA += 1
                endB += 1
            } else if start > 0 {
                start -= 1
            } else {
                break
            }
        }
        let wrong = String(a[start..<endA]).trimmingCharacters(in: .whitespaces)
        let right = String(b[start..<endB]).trimmingCharacters(in: .whitespaces)
        guard (2...12).contains(wrong.count), (2...12).contains(right.count), wrong != right else { return nil }
        return (wrong, right)
    }

    /// `text` with every correction applied, longest `wrong` first so a longer word wins.
    public static func apply(_ corrections: [Correction], to text: String) -> String {
        corrections.sorted { $0.wrong.count > $1.wrong.count }
            .reduce(text) { $0.replacingOccurrences(of: $1.wrong, with: $1.right) }
    }
}

/// A folder recordings can be put in (features.md D1c). A recording is in at most one.
public struct Folder: Codable, Equatable, Hashable, Sendable, Identifiable, FetchableRecord, PersistableRecord {
    public var id: UUID
    public var name: String
    public var createdAt: Date

    public init(id: UUID = UUID(), name: String, createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
    }

    public static let databaseTableName = "folder"
    public static let databaseColumnDecodingStrategy = DatabaseColumnDecodingStrategy.convertFromSnakeCase
    public static let databaseColumnEncodingStrategy = DatabaseColumnEncodingStrategy.convertToSnakeCase
}

/// States of prd.md §4.1.
public enum SyncState: String, Codable, Sendable, CaseIterable {
    case discovered, downloading, stored, deletePending, deletedOnCard, failed
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

/// A todo not yet ticked, with the recording its summary belongs to (the 总览 page, #89).
public struct OpenTodo: Equatable, Sendable, Identifiable {
    public var recording: Recording
    /// Index into `Summary.todos`, for ticking it.
    public var index: Int
    public var text: String

    public var id: String { "\(recording.id.uuidString)#\(index)" }

    public init(recording: Recording, index: Int, text: String) {
        self.recording = recording
        self.index = index
        self.text = text
    }
}

/// What 总览 and 知识库 show (#89), read in one transaction.
public struct LibraryDigest: Equatable, Sendable {
    public var openTodos: [OpenTodo]
    public var recentSummaries: [SummarizedRecording]
    /// Recordings not in 最近删除 that have no transcript yet.
    public var untranscribedCount: Int
    /// Tags of the summaries of recordings not in 最近删除, most used first (D1c 标签).
    public var tags: [TagCount]

    public init(openTodos: [OpenTodo] = [], recentSummaries: [SummarizedRecording] = [], untranscribedCount: Int = 0,
                tags: [TagCount] = []) {
        self.openTodos = openTodos
        self.recentSummaries = recentSummaries
        self.untranscribedCount = untranscribedCount
        self.tags = tags
    }
}

/// A tag and how many recordings carry it.
public struct TagCount: Equatable, Hashable, Sendable, Identifiable {
    public var name: String
    public var count: Int

    public var id: String { name }

    public init(name: String, count: Int) {
        self.name = name
        self.count = count
    }
}

/// What the user did to a tag (features.md D1c 标签), applied to every summary saved later so an
/// AI tag never brings back a tag the user renamed, merged or deleted. `replacement` nil means
/// deleted.
public struct TagRule: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    public var tag: String
    public var replacement: String?
    public var createdAt: Date

    public init(tag: String, replacement: String?, createdAt: Date = Date()) {
        self.tag = tag
        self.replacement = replacement
        self.createdAt = createdAt
    }

    public static let databaseTableName = "tag_rule"
    public static let databaseColumnDecodingStrategy = DatabaseColumnDecodingStrategy.convertFromSnakeCase
    public static let databaseColumnEncodingStrategy = DatabaseColumnEncodingStrategy.convertToSnakeCase

    /// `tags` with each rule applied once (renamed, or dropped when deleted), duplicates removed
    /// in order.
    public static func apply(_ rules: [TagRule], to tags: [String]) -> [String] {
        guard !rules.isEmpty else { return tags }
        let map = Dictionary(rules.map { ($0.tag, $0.replacement) }, uniquingKeysWith: { _, last in last })
        var seen = Set<String>()
        return tags.compactMap { tag -> String? in
            let mapped: String?
            if let rule = map[tag] { mapped = rule } else { mapped = tag }
            guard let name = mapped, seen.insert(name).inserted else { return nil }
            return name
        }
    }
}

/// A recording with its summary (the 知识库 page, #89).
public struct SummarizedRecording: Equatable, Sendable, Identifiable {
    public var recording: Recording
    public var summary: Summary

    public var id: UUID { recording.id }

    public init(recording: Recording, summary: Summary) {
        self.recording = recording
        self.summary = summary
    }
}
