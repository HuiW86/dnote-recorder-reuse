import CryptoKit
import Foundation
import GRDB

/// Database and audio files together; the only way SyncEngine and the UI touch the library.
public final class RecordingLibrary: Sendable {
    public let database: AppDatabase
    public let store: AudioStore

    public init(database: AppDatabase, store: AudioStore) {
        self.database = database
        self.store = store
    }

    // MARK: Startup recovery (prd.md §4.3)

    /// After a launch, possibly following a crash: `downloading` goes back to `discovered`,
    /// temporary files are dropped, and OGG files with no Recording row are removed.
    public func recoverAfterLaunch() throws {
        try database.writer.write { db in
            try db.execute(sql: "UPDATE sync_item SET state = ? WHERE state = ?",
                           arguments: [SyncState.discovered.rawValue, SyncState.downloading.rawValue])
        }
        store.clearTemporary()
        let known = Set(try database.writer.read { try Recording.fetchAll($0) }.map(\.id))
        for file in store.storedAudioFiles() where !known.contains(file.id) {
            store.removeAudio(file.path)
        }
        store.removeDecoded(except: known)
    }

    /// Items that failed with `lastError` (SyncEngine passes `decryptFailed`) in another app
    /// build, or before builds were recorded, go back to `discovered`, so the next pass downloads
    /// them once more: a newer build may fix the cause (#59). Nothing is sent to the card.
    /// Returns how many items were reset.
    @discardableResult
    public func retryFailures(_ lastError: String, notFailedIn currentBuild: String) throws -> Int {
        try database.writer.write { db in
            try db.execute(sql: """
                UPDATE sync_item SET state = ?, last_error = NULL, failed_build = NULL
                WHERE state = ? AND last_error = ? AND (failed_build IS NULL OR failed_build <> ?)
                """, arguments: [SyncState.discovered.rawValue, SyncState.failed.rawValue,
                                 lastError, currentBuild])
            return db.changesCount
        }
    }

    // MARK: Devices

    /// Inserts or updates the device with this serial.
    @discardableResult
    public func upsertDevice(sn: String, update: (inout Device) -> Void) throws -> Device {
        try database.writer.write { db in
            var device = try Device.filter(Column("sn") == sn).fetchOne(db)
                ?? Device(sn: sn, name: "", firmware: "")
            update(&device)
            try device.save(db)
            return device
        }
    }

    // MARK: Sync items

    public func syncItems(deviceId: UUID) throws -> [SyncItem] {
        try database.writer.read { db in
            try SyncItem.filter(Column("device_id") == deviceId).order(Column("card_file_name")).fetchAll(db)
        }
    }

    /// The item for this card file, inserted as `discovered` if new.
    public func syncItem(deviceId: UUID, name: String, size: Int) throws -> SyncItem {
        try database.writer.write { db in
            if let item = try SyncItem
                .filter(Column("device_id") == deviceId && Column("card_file_name") == name
                        && Column("card_file_size") == size)
                .fetchOne(db) {
                return item
            }
            var item = SyncItem(deviceId: deviceId, cardFileName: name, cardFileSize: size)
            try item.insert(db)
            return item
        }
    }

    public func update(_ item: SyncItem) throws {
        try database.writer.write { db in try item.update(db) }
    }

    /// Inserts the Recording and moves the item to `stored` (or `deletePending`) in one
    /// transaction (prd.md §4.2 step 4).
    public func commitStored(_ recording: Recording, item: SyncItem, deleteAfterSync: Bool) throws -> SyncItem {
        try database.writer.write { db in
            // "不要这条" was asked for this file before it arrived (features.md X10): it is stored
            // like any other, then goes straight to 最近删除 and its card copy is queued for delete.
            let discard = try Self.discardRequested(db, deviceId: item.deviceId, cardFileName: item.cardFileName)
            var recording = recording
            if discard { recording.trashedAt = recording.createdAt }
            try recording.insert(db)
            var item = item
            item.state = deleteAfterSync || discard ? .deletePending : .stored
            item.recordingId = recording.id
            item.lastError = nil
            item.failedBuild = nil
            try item.update(db)
            return item
        }
    }

    /// Whether the phone still holds this item's recording: the row and its audio file. A card
    /// file may be deleted only then (CLAUDE.md rule 2); a recording deleted in the app leaves
    /// the item `stored` with no recording, and the card copy is then the only one.
    public func hasLocalCopy(_ item: SyncItem) throws -> Bool {
        guard let id = item.recordingId, let recording = try recording(id: id) else { return false }
        return FileManager.default.fileExists(atPath: store.url(forAudioPath: recording.audioPath).path)
    }

    // MARK: Recordings

    public func recordings() throws -> [Recording] {
        try database.writer.read { try Recording.order(Column("started_at")).fetchAll($0) }
    }

    public func recording(id: UUID) throws -> Recording? {
        try database.writer.read { try Recording.fetchOne($0, key: id) }
    }

    /// Recordings newest first, now and after every change (the home list, product-spec.md P05).
    /// The first value arrives immediately; keep the returned observation to keep observing.
    @MainActor
    public func observeRecordings(onError: @escaping @MainActor (Error) -> Void,
                                  onChange: @escaping @MainActor ([Recording]) -> Void) -> LibraryObservation {
        let observation = ValueObservation.tracking { db in
            try Recording.filter(Column("trashed_at") == nil).order(Column("started_at").desc).fetchAll(db)
        }
        return LibraryObservation(observation.start(in: database.writer, scheduling: .immediate,
                                                    onError: onError, onChange: onChange))
    }

    // MARK: Rename and trash (features.md X6, D1b)

    /// Sets the title; an empty one puts the default back. Returns the stored recording, nil when
    /// it is not in the library.
    @discardableResult
    public func renameRecording(id: UUID, to title: String, now: Date = Date()) throws -> Recording? {
        try database.writer.write { db in
            guard var recording = try Recording.fetchOne(db, key: id) else { return nil }
            let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
            recording.title = trimmed.isEmpty
                ? Recording.defaultTitle(for: recording.startedAt) : String(trimmed.prefix(80))
            recording.titleSource = trimmed.isEmpty ? nil : .user
            recording.updatedAt = now
            try recording.update(db)
            return recording
        }
    }

    /// Sets a title from the user's AI service (features.md G1). A title the user typed is kept
    /// unless `replacingUserTitle` (the user asked for a new one). An empty title changes
    /// nothing. Returns the stored recording, nil when it is not in the library.
    @discardableResult
    public func applyAITitle(id: UUID, _ title: String, replacingUserTitle: Bool = false,
                             now: Date = Date()) throws -> Recording? {
        try database.writer.write { db in
            guard var recording = try Recording.fetchOne(db, key: id) else { return nil }
            let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, replacingUserTitle || !recording.hasCustomTitle else { return recording }
            recording.title = String(trimmed.prefix(80))
            recording.titleSource = .ai
            recording.updatedAt = now
            try recording.update(db)
            return recording
        }
    }

    /// Moves a recording to 最近删除: the row and the audio stay, so it can be restored as it
    /// was. Like a delete, nothing is sent to the card and the SyncItem stays `stored`.
    public func trashRecording(id: UUID, now: Date = Date()) throws {
        try database.writer.write { db in
            try db.execute(sql: "UPDATE recording SET trashed_at = ?, updated_at = ? WHERE id = ? AND trashed_at IS NULL",
                           arguments: [now, now, id])
        }
        store.removeDecoded(id)
    }

    /// Restoring also calls off a "不要这条" request for it (features.md X10): the user wants the
    /// recording after all, so its card copy is not deleted for that reason. A card delete queued
    /// by "同步后删除" is queued again by the next pass.
    public func restoreRecording(id: UUID, now: Date = Date()) throws {
        try database.writer.write { db in
            try db.execute(sql: "UPDATE recording SET trashed_at = NULL, updated_at = ? WHERE id = ?",
                           arguments: [now, id])
            guard let recording = try Recording.fetchOne(db, key: id), let deviceId = recording.deviceId,
                  let name = recording.cardFileName else { return }
            try db.execute(sql: "DELETE FROM discard_request WHERE device_id = ? AND card_file_name = ?",
                           arguments: [deviceId, name])
            try db.execute(sql: "UPDATE sync_item SET state = ? WHERE recording_id = ? AND state = ?",
                           arguments: [SyncState.stored.rawValue, id, SyncState.deletePending.rawValue])
        }
    }

    /// Whether the card still holds this recording's file, as far as the library knows. False
    /// once it was deleted from the card or is queued to be: deleting the phone copy then
    /// loses the recording for good, and 最近删除 says so.
    public func cardCopyRemains(recordingId: UUID) throws -> Bool {
        try database.writer.read { db in
            try SyncItem.filter(Column("recording_id") == recordingId && Column("state") == SyncState.stored.rawValue)
                .fetchCount(db) > 0
        }
    }

    /// Recordings in 最近删除, the most recently deleted first.
    public func trashedRecordings() throws -> [Recording] {
        try database.writer.read { db in
            try Recording.filter(Column("trashed_at") != nil).order(Column("trashed_at").desc).fetchAll(db)
        }
    }

    /// 最近删除, now and after every change. Keep the returned observation to keep observing.
    @MainActor
    public func observeTrash(onError: @escaping @MainActor (Error) -> Void,
                             onChange: @escaping @MainActor ([Recording]) -> Void) -> LibraryObservation {
        let observation = ValueObservation.tracking { db in
            try Recording.filter(Column("trashed_at") != nil).order(Column("trashed_at").desc).fetchAll(db)
        }
        return LibraryObservation(observation.start(in: database.writer, scheduling: .immediate,
                                                    onError: onError, onChange: onChange))
    }

    // MARK: Star (features.md X21)

    /// Stars or unstars a recording. Starring one already starred keeps its first time. Returns
    /// the stored recording, nil when it is not in the library.
    @discardableResult
    public func setStarred(id: UUID, _ starred: Bool, now: Date = Date()) throws -> Recording? {
        try database.writer.write { db in
            guard var recording = try Recording.fetchOne(db, key: id) else { return nil }
            guard recording.isStarred != starred else { return recording }
            recording.starredAt = starred ? now : nil
            recording.updatedAt = now
            try recording.update(db)
            return recording
        }
    }

    // MARK: Discard after recording (features.md X10)

    /// "不要这条" for a card file. Nothing is deleted here: a file not synced yet is still stored
    /// first (CLAUDE.md rule 2) and `commitStored` then trashes it; one already stored is moved to
    /// 最近删除 now and its SyncItem is queued for the card delete.
    public func requestDiscard(deviceId: UUID, cardFileName: String, now: Date = Date()) throws {
        try database.writer.write { db in
            try db.execute(sql: "INSERT OR REPLACE INTO discard_request (device_id, card_file_name, created_at) VALUES (?, ?, ?)",
                           arguments: [deviceId, cardFileName, now])
            let stored = try Recording
                .filter(Column("device_id") == deviceId && Column("card_file_name") == cardFileName
                        && Column("trashed_at") == nil)
                .fetchAll(db)
            for recording in stored {
                try db.execute(sql: "UPDATE recording SET trashed_at = ?, updated_at = ? WHERE id = ?",
                               arguments: [now, now, recording.id])
                try db.execute(sql: "UPDATE sync_item SET state = ? WHERE recording_id = ? AND state = ?",
                               arguments: [SyncState.deletePending.rawValue, recording.id, SyncState.stored.rawValue])
            }
        }
    }

    /// "撤销" of `requestDiscard`: the recording comes back from 最近删除 and a card delete that has
    /// not been sent yet is called off. A card file already deleted stays deleted; the phone
    /// copy is the one that remains. Returns false when there was no request.
    @discardableResult
    public func cancelDiscard(deviceId: UUID, cardFileName: String, now: Date = Date()) throws -> Bool {
        try database.writer.write { db in
            guard try Self.discardRequested(db, deviceId: deviceId, cardFileName: cardFileName) else { return false }
            try db.execute(sql: "DELETE FROM discard_request WHERE device_id = ? AND card_file_name = ?",
                           arguments: [deviceId, cardFileName])
            let trashed = try Recording
                .filter(Column("device_id") == deviceId && Column("card_file_name") == cardFileName
                        && Column("trashed_at") != nil)
                .fetchAll(db)
            for recording in trashed {
                try db.execute(sql: "UPDATE recording SET trashed_at = NULL, updated_at = ? WHERE id = ?",
                               arguments: [now, recording.id])
                try db.execute(sql: "UPDATE sync_item SET state = ? WHERE recording_id = ? AND state = ?",
                               arguments: [SyncState.stored.rawValue, recording.id, SyncState.deletePending.rawValue])
            }
            return true
        }
    }

    public func discardRequested(deviceId: UUID, cardFileName: String) throws -> Bool {
        try database.writer.read { try Self.discardRequested($0, deviceId: deviceId, cardFileName: cardFileName) }
    }

    /// The card file is gone from the card: the request has done its job.
    public func finishDiscard(deviceId: UUID, cardFileName: String) throws {
        try database.writer.write { db in
            try db.execute(sql: "DELETE FROM discard_request WHERE device_id = ? AND card_file_name = ?",
                           arguments: [deviceId, cardFileName])
        }
    }

    private static func discardRequested(_ db: Database, deviceId: UUID, cardFileName: String) throws -> Bool {
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM discard_request WHERE device_id = ? AND card_file_name = ?",
                         arguments: [deviceId, cardFileName]) ?? 0 > 0
    }

    // MARK: Phone recordings (features.md X18)

    /// Stores a recording made with the phone's microphone: the file moves into `audio/` and a
    /// row is added. Nothing here involves a card or the sync engine.
    @discardableResult
    public func addPhoneRecording(file: URL, startedAt: Date, durationMs: Int, now: Date = Date()) throws -> Recording {
        try addLocalRecording(file: file, source: .phone, startedAt: startedAt, durationMs: durationMs, title: nil, now: now)
    }

    /// Stores an audio file that did not come from a card: a phone recording (X18) or an
    /// imported file (E2). `title` nil gives the default date title. The file is moved.
    @discardableResult
    public func addLocalRecording(file: URL, source: Recording.Source, startedAt: Date, durationMs: Int,
                                  title: String?, now: Date = Date()) throws -> Recording {
        let id = UUID()
        let data = try Data(contentsOf: file)
        let sha = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let path = try store.importAudio(from: file, id: id)
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let recording = Recording(id: id, deviceId: nil, source: source, cardFileName: nil, cardFileSize: nil,
                                  startedAt: startedAt, durationMs: durationMs, audioPath: path, audioSha256: sha,
                                  title: trimmed.isEmpty ? Recording.defaultTitle(for: startedAt) : String(trimmed.prefix(80)),
                                  createdAt: now, updatedAt: now)
        do {
            try database.writer.write { db in try recording.insert(db) }
        } catch {
            store.removeAudio(path)
            throw error
        }
        return recording
    }

    // MARK: Folders (features.md D1c)

    /// Folders by name.
    public func folders() throws -> [Folder] {
        try database.writer.read { try Folder.order(Column("name")).fetchAll($0) }
    }

    /// A new folder; the name is trimmed and capped at 40 characters. Nil for an empty name.
    @discardableResult
    public func createFolder(named name: String, now: Date = Date()) throws -> Folder? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let folder = Folder(name: String(trimmed.prefix(40)), createdAt: now)
        try database.writer.write { db in try folder.insert(db) }
        return folder
    }

    /// Renames a folder; an empty name changes nothing.
    public func renameFolder(id: UUID, to name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try database.writer.write { db in
            try db.execute(sql: "UPDATE folder SET name = ? WHERE id = ?", arguments: [String(trimmed.prefix(40)), id])
        }
    }

    /// Deletes the folder only: its recordings stay, outside any folder.
    public func deleteFolder(id: UUID) throws {
        try database.writer.write { db in
            try db.execute(sql: "UPDATE recording SET folder_id = NULL WHERE folder_id = ?", arguments: [id])
            try db.execute(sql: "DELETE FROM folder WHERE id = ?", arguments: [id])
        }
    }

    /// Puts a recording in a folder, or takes it out with nil.
    public func moveRecording(id: UUID, toFolder folderId: UUID?, now: Date = Date()) throws {
        try database.writer.write { db in
            try db.execute(sql: "UPDATE recording SET folder_id = ?, updated_at = ? WHERE id = ?",
                           arguments: [folderId, now, id])
        }
    }

    // MARK: Filters (design-spec.md §3 筛选项)

    /// Recordings that have at least one mark.
    public func recordingIdsWithMarks() throws -> Set<UUID> {
        try database.writer.read { db in
            Set(try UUID.fetchAll(db, sql: """
                SELECT DISTINCT recording.id FROM recording
                JOIN recording_mark ON recording_mark.device_id = recording.device_id
                 AND recording_mark.card_file_name = recording.card_file_name
                 AND recording_mark.offset_ms <= recording.duration_ms
                """))
        }
    }

    /// Recordings that have a transcript.
    public func recordingIdsWithTranscript() throws -> Set<UUID> {
        try database.writer.read { db in Set(try UUID.fetchAll(db, sql: "SELECT recording_id FROM transcript")) }
    }

    /// Recordings whose summary has a todo not yet ticked (the 有待办 filter, #89).
    public func recordingIdsWithOpenTodos() throws -> Set<UUID> {
        Set(try openTodos().map(\.recording.id))
    }

    // MARK: Overview and knowledge (#89)

    /// Todos not yet ticked, across recordings not in 最近删除: the newest recording first, and
    /// in the summary's order within one recording.
    public func openTodos() throws -> [OpenTodo] {
        try database.writer.read { try Self.openTodos($0) }
    }

    /// Recordings not in 最近删除 that have a summary, the most recently summarized first.
    public func recentSummaries(limit: Int = 20) throws -> [SummarizedRecording] {
        try database.writer.read { Array(try Self.summarizedRecordings($0, newestSummaryFirst: true).prefix(limit)) }
    }

    /// What 总览 and 知识库 show, now and after every change to recordings, transcripts or
    /// summaries. Keep the returned observation to keep observing.
    @MainActor
    public func observeDigest(summaryLimit: Int = 20, onError: @escaping @MainActor (Error) -> Void,
                              onChange: @escaping @MainActor (LibraryDigest) -> Void) -> LibraryObservation {
        let observation = ValueObservation.tracking { db in try Self.digest(db, summaryLimit: summaryLimit) }
        return LibraryObservation(observation.start(in: database.writer, scheduling: .immediate,
                                                    onError: onError, onChange: onChange))
    }

    public func digest(summaryLimit: Int = 20) throws -> LibraryDigest {
        try database.writer.read { try Self.digest($0, summaryLimit: summaryLimit) }
    }

    private static func digest(_ db: Database, summaryLimit: Int) throws -> LibraryDigest {
        let untranscribed = try Int.fetchOne(db, sql: """
            SELECT COUNT(*) FROM recording LEFT JOIN transcript ON transcript.recording_id = recording.id
            WHERE recording.trashed_at IS NULL AND transcript.recording_id IS NULL
            """) ?? 0
        return LibraryDigest(openTodos: try openTodos(db),
                             recentSummaries: Array(try summarizedRecordings(db, newestSummaryFirst: true)
                                 .prefix(summaryLimit)),
                             untranscribedCount: untranscribed)
    }

    private static func openTodos(_ db: Database) throws -> [OpenTodo] {
        try summarizedRecordings(db, newestSummaryFirst: false).flatMap { item in
            item.summary.todos.enumerated().compactMap { index, todo in
                todo.done ? nil : OpenTodo(recording: item.recording, index: index, text: todo.text)
            }
        }
    }

    /// Recordings not in 最近删除 with their summaries: by summary time, or by recording time.
    private static func summarizedRecordings(_ db: Database, newestSummaryFirst: Bool) throws -> [SummarizedRecording] {
        let order = newestSummaryFirst ? "summary.created_at DESC" : "recording.started_at DESC"
        let ids = try UUID.fetchAll(db, sql: """
            SELECT recording.id FROM recording JOIN summary ON summary.recording_id = recording.id
            WHERE recording.trashed_at IS NULL ORDER BY \(order)
            """)
        return try ids.compactMap { id in
            guard let recording = try Recording.fetchOne(db, key: id),
                  let summary = try Summary.fetchOne(db, key: id) else { return nil }
            return SummarizedRecording(recording: recording, summary: summary)
        }
    }

    // MARK: Search (features.md D2)

    /// Recordings not in 最近删除 whose title, transcript or summary contains every word of
    /// `query` (split at spaces), newest first. Case-insensitive for Latin letters. Local only.
    public func searchRecordings(_ query: String) throws -> [Recording] {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init).filter { !$0.isEmpty }
        guard !words.isEmpty else { return [] }
        return try database.writer.read { db in
            var sql = """
                SELECT recording.* FROM recording
                LEFT JOIN transcript ON transcript.recording_id = recording.id
                LEFT JOIN summary ON summary.recording_id = recording.id
                WHERE recording.trashed_at IS NULL
                """
            var arguments: [String] = []
            for word in words {
                // Escape LIKE wildcards so a "%" or "_" in the query is matched as typed.
                let pattern = "%" + word.replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_") + "%"
                sql += """
                     AND (recording.title LIKE ? ESCAPE '\\' OR transcript.segments LIKE ? ESCAPE '\\'
                          OR summary.title LIKE ? ESCAPE '\\' OR summary.summary LIKE ? ESCAPE '\\'
                          OR summary.sections LIKE ? ESCAPE '\\' OR summary.todos LIKE ? ESCAPE '\\'
                          OR summary.tags LIKE ? ESCAPE '\\' OR summary.people LIKE ? ESCAPE '\\'
                          OR summary.outline LIKE ? ESCAPE '\\' OR summary.quotes LIKE ? ESCAPE '\\')
                    """
                arguments += Array(repeating: pattern, count: 10)
            }
            sql += " ORDER BY recording.started_at DESC"
            return try Recording.fetchAll(db, sql: sql, arguments: StatementArguments(arguments))
        }
    }

    // MARK: Transcripts (features.md X9)

    /// Stores the transcript of a recording, replacing an earlier one.
    public func saveTranscript(_ transcript: Transcript) throws {
        try database.writer.write { db in try transcript.save(db) }
    }

    /// Replaces the text of one transcript line (the user fixed a misheard word). A short word
    /// swap is remembered in 纠错词库 (#75). Returns the stored transcript, nil when there is no
    /// transcript or no line at `index`.
    @discardableResult
    public func editTranscriptLine(recordingId: UUID, index: Int, to text: String,
                                   now: Date = Date()) throws -> Transcript? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return try database.writer.write { db in
            guard var transcript = try Transcript.fetchOne(db, key: recordingId),
                  transcript.segments.indices.contains(index), !trimmed.isEmpty else { return nil }
            let original = transcript.segments[index].text
            guard original != trimmed else { return transcript }
            transcript.segments[index].text = trimmed
            try transcript.update(db)
            if let pair = Correction.between(original, trimmed) {
                try Correction(wrong: pair.wrong, right: pair.right, createdAt: now).save(db)
            }
            return transcript
        }
    }

    /// 逐句润色 (#75): puts the polished text on each line, keeping its time. The lines as they
    /// were before the first polish are kept, so `restoreOriginalTranscript` can bring them back;
    /// polishing again keeps that first original. `texts` has one entry per line; an empty entry
    /// keeps the line's text. Nil when there is no transcript or the count does not match.
    @discardableResult
    public func savePolishedTranscript(recordingId: UUID, texts: [String]) throws -> Transcript? {
        try database.writer.write { db in
            guard var transcript = try Transcript.fetchOne(db, key: recordingId),
                  texts.count == transcript.segments.count else { return nil }
            if transcript.originalSegments == nil { transcript.originalSegments = transcript.segments }
            for (i, text) in texts.enumerated() {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { transcript.segments[i].text = trimmed }
            }
            try transcript.update(db)
            return transcript
        }
    }

    /// Goes back to the lines as transcribed, dropping the polished text (and edits made to
    /// it). Returns the transcript unchanged when it was never polished; nil when there is none.
    @discardableResult
    public func restoreOriginalTranscript(recordingId: UUID) throws -> Transcript? {
        try database.writer.write { db in
            guard var transcript = try Transcript.fetchOne(db, key: recordingId) else { return nil }
            guard let original = transcript.originalSegments else { return transcript }
            transcript.segments = original
            transcript.originalSegments = nil
            try transcript.update(db)
            return transcript
        }
    }

    /// 纠错词库, newest first.
    public func corrections() throws -> [Correction] {
        try database.writer.read { try Correction.order(Column("created_at").desc).fetchAll($0) }
    }

    public func deleteCorrection(wrong: String) throws {
        try database.writer.write { db in _ = try Correction.deleteOne(db, key: wrong) }
    }

    /// Segments with 纠错词库 applied, for a transcript about to be stored.
    public func corrected(_ segments: [TranscriptSegment]) -> [TranscriptSegment] {
        let corrections = (try? corrections()) ?? []
        guard !corrections.isEmpty else { return segments }
        return segments.map { TranscriptSegment(startMs: $0.startMs, text: Correction.apply(corrections, to: $0.text)) }
    }

    public func transcript(recordingId: UUID) throws -> Transcript? {
        try database.writer.read { try Transcript.fetchOne($0, key: recordingId) }
    }

    // MARK: Summaries (features.md G1)

    /// Stores the summary of a recording, replacing an earlier one.
    public func saveSummary(_ summary: Summary) throws {
        try database.writer.write { db in try summary.save(db) }
    }

    public func summary(recordingId: UUID) throws -> Summary? {
        try database.writer.read { try Summary.fetchOne($0, key: recordingId) }
    }

    /// Ticks or unticks the todo at `index`. Returns the stored summary, nil when there is no
    /// summary or no todo at that index.
    @discardableResult
    public func setTodoDone(recordingId: UUID, index: Int, done: Bool) throws -> Summary? {
        try database.writer.write { db in
            guard var stored = try Summary.fetchOne(db, key: recordingId),
                  stored.todos.indices.contains(index) else { return nil }
            stored.todos[index].done = done
            try stored.update(db)
            return stored
        }
    }

    // MARK: Marks (features.md X7)

    /// Adds a mark at `offsetMs` of a card file. A second mark within 2 s of an existing one is
    /// dropped (a double tap); returns whether a mark was added.
    @discardableResult
    public func addMark(deviceId: UUID, cardFileName: String, offsetMs: Int, now: Date = Date()) throws -> Bool {
        try database.writer.write { db in
            let near = try RecordingMark
                .filter(Column("device_id") == deviceId && Column("card_file_name") == cardFileName
                        && Column("offset_ms") > offsetMs - 2000 && Column("offset_ms") < offsetMs + 2000)
                .fetchCount(db)
            guard near == 0 else { return false }
            var mark = RecordingMark(deviceId: deviceId, cardFileName: cardFileName, offsetMs: max(0, offsetMs),
                                     createdAt: now)
            try mark.insert(db)
            return true
        }
    }

    /// Marks of a card file, in playback order.
    public func marks(deviceId: UUID, cardFileName: String) throws -> [RecordingMark] {
        try database.writer.read { db in
            try RecordingMark
                .filter(Column("device_id") == deviceId && Column("card_file_name") == cardFileName)
                .order(Column("offset_ms"))
                .fetchAll(db)
        }
    }

    /// Marks of a recording that came from a card, within its length; empty for any other source.
    public func marks(for recording: Recording) throws -> [RecordingMark] {
        guard let deviceId = recording.deviceId, let name = recording.cardFileName else { return [] }
        return try marks(deviceId: deviceId, cardFileName: name).filter { $0.offsetMs <= recording.durationMs }
    }

    public func deleteMark(id: Int64) throws {
        try database.writer.write { db in
            try db.execute(sql: "DELETE FROM recording_mark WHERE id = ?", arguments: [id])
        }
    }

    /// Deletes for good what was moved to 最近删除 at or before `cutoff`. Returns how many.
    @discardableResult
    public func purgeTrash(trashedBefore cutoff: Date) throws -> Int {
        let expired = try trashedRecordings().filter { ($0.trashedAt ?? .distantFuture) <= cutoff }
        for recording in expired { try deleteRecording(id: recording.id) }
        return expired.count
    }

    /// When the newest card recording was stored; nil when none was.
    public func lastStoredAt() throws -> Date? {
        try database.writer.read { db in
            try Date.fetchOne(db, sql: "SELECT MAX(created_at) FROM recording WHERE source = ?",
                              arguments: [Recording.Source.card.rawValue])
        }
    }

    // MARK: Devices for the UI

    /// Devices paired from this phone, oldest first. A row without `pairedAt` was only seen
    /// by a sync and does not count as paired (product-spec.md §5.1 `noDevice`).
    public func pairedDevices() throws -> [Device] {
        try database.writer.read { db in
            try Device.filter(Column("paired_at") != nil).order(Column("paired_at")).fetchAll(db)
        }
    }

    public func device(id: UUID) throws -> Device? {
        try database.writer.read { try Device.fetchOne($0, key: id) }
    }

    /// Unpairing keeps the row and its recordings; without `pairedAt` the card no longer counts as
    /// paired (product-spec.md P07 「解绑此卡」).
    public func markUnpaired(id: UUID) throws {
        try database.writer.write { db in
            try db.execute(sql: "UPDATE device SET paired_at = NULL WHERE id = ?", arguments: [id])
        }
    }

    /// Local display name only; nothing is written to the card (`0x86` is M4).
    public func renameDevice(id: UUID, to name: String) throws {
        try database.writer.write { db in
            try db.execute(sql: "UPDATE device SET name = ? WHERE id = ?", arguments: [name, id])
        }
    }

    /// Deletes a recording for good: the row, its audio and any decoded copy. The UI goes through
    /// `trashRecording` first (features.md D1b). The SyncItem stays `stored`, so the file is not
    /// synced again, and nothing is sent to the card (prd.md §4.3, T-M1-32).
    public func deleteRecording(id: UUID) throws {
        guard let recording = try database.writer.write({ db -> Recording? in
            guard let r = try Recording.fetchOne(db, key: id) else { return nil }
            try r.delete(db)
            // Its marks go too, unless another recording has the same card file name (the
            // card's clock was reset: T-M1-25).
            if let deviceId = r.deviceId, let name = r.cardFileName,
               try Recording.filter(Column("device_id") == deviceId && Column("card_file_name") == name).fetchCount(db) == 0 {
                try db.execute(sql: "DELETE FROM recording_mark WHERE device_id = ? AND card_file_name = ?",
                               arguments: [deviceId, name])
            }
            return r
        }) else { return }
        // Row first: a crash before the file is removed leaves an orphan that recovery deletes.
        store.removeAudio(recording.audioPath)
        store.removeDecoded(id)
    }
}

/// Failed sync items: `retryable` can be retried, `undecryptable` only by another app build
/// (#59). `autoRetrying` is the part of `retryable` that still has automatic retries left; the
/// rest wait for the user.
public struct FailureCounts: Equatable, Sendable {
    public var retryable: Int
    public var undecryptable: Int
    public var autoRetrying: Int

    public init(retryable: Int, undecryptable: Int, autoRetrying: Int = 0) {
        self.retryable = retryable
        self.undecryptable = undecryptable
        self.autoRetrying = autoRetrying
    }
}

/// Keeps a library observation alive; observing stops when this is released or cancelled.
public final class LibraryObservation: @unchecked Sendable {
    private let cancellable: AnyDatabaseCancellable

    init(_ cancellable: AnyDatabaseCancellable) {
        self.cancellable = cancellable
    }

    public func cancel() { cancellable.cancel() }
}
