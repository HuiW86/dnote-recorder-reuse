// Transcribing and summarizing a local recording with the 闻笺 account, end to end
// (product-spec.md §7.3b): which server recording it is, putting the audio or only the text there,
// waiting on the task and reading the result. The app decides whether to come here at all
// (AIRoute); nothing here runs for the card (CLAUDE.md rule 3).

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// What the server is told about a recording sent without its audio, to carry only its text.
public struct RecordingDetails: Equatable, Sendable {
    public var source: NewRecording.Source
    public var startedAt: Date
    public var durationMs: Int
    public var title: String

    public init(source: NewRecording.Source, startedAt: Date, durationMs: Int, title: String) {
        self.source = source
        self.startedAt = startedAt
        self.durationMs = durationMs
        self.title = title
    }
}

/// One line of the app's own transcript, as `PUT /recordings/{id}/transcript` takes it.
public struct TranscriptLine: Equatable, Sendable {
    public var startMs: Int
    public var endMs: Int
    public var speaker: String?
    public var text: String

    public init(startMs: Int, endMs: Int, speaker: String? = nil, text: String) {
        self.startMs = startMs
        self.endMs = endMs
        self.speaker = speaker
        self.text = text
    }
}

/// The server recording a local one is, for one account.
public struct ServerRecordingId: Equatable, Sendable {
    public var id: UUID
    /// False when it was made for the text only.
    public var hasAudio: Bool

    public init(id: UUID, hasAudio: Bool) {
        self.id = id
        self.hasAudio = hasAudio
    }
}

/// Where the app keeps which server recording each local one is (the library's
/// `remote_recording`), so a summary does not put a recording on the server twice.
public protocol ServerRecordingIds: Sendable {
    func serverId(local: UUID, account: UUID) async throws -> ServerRecordingId?
    func keep(_ server: ServerRecordingId, local: UUID, account: UUID) async throws
    func forget(local: UUID, account: UUID) async throws
}

extension AccountClient {
    /// A recording without audio (only its text will go there). Every call makes a new one, so
    /// the caller keeps its id and sends a retry with the same `idempotencyKey`.
    public func createRecording(accessToken: String, _ details: RecordingDetails,
                                idempotencyKey: String) async throws -> RemoteRecording {
        let body: [String: Any] = [
            "source": details.source.rawValue,
            "started_at": Self.timestamp(details.startedAt),
            "duration_ms": details.durationMs,
            "title": details.title,
        ]
        return try decode(await send(request("POST", "/v1/recordings", body: body, bearer: accessToken,
                                             idempotencyKey: idempotencyKey)))
    }

    /// Replaces the recording's transcript with the app's own. `engine` names what made it on the
    /// phone ("on-device", "own-service"); the server stores it as "app:<engine>".
    public func putTranscript(accessToken: String, recordingId: UUID, engine: String, language: String,
                              lines: [TranscriptLine]) async throws -> RemoteTranscript {
        let segments: [[String: Any]] = lines.map { line in
            var segment: [String: Any] = ["start_ms": line.startMs, "end_ms": line.endMs, "text": line.text]
            if let speaker = line.speaker { segment["speaker"] = speaker }
            return segment
        }
        let body: [String: Any] = ["engine": engine, "language": language, "segments": segments]
        return try decode(await send(request("PUT", "/v1/recordings/\(Self.id(recordingId))/transcript", body: body,
                                             bearer: accessToken)))
    }
}

extension AccountSession {
    public func putTranscript(recordingId: UUID, engine: String, language: String,
                              lines: [TranscriptLine]) async throws -> RemoteTranscript {
        let client = client
        return try await authorized {
            try await client.putTranscript(accessToken: $0, recordingId: recordingId, engine: engine,
                                           language: language, lines: lines)
        }
    }

    /// Puts the audio on the server (or finds it there: the same audio is one recording), keeps
    /// the server's id, transcribes and returns the transcript. A text-only server recording kept
    /// for `local` is replaced by the one with the audio.
    public func transcribeRecording(local: UUID, _ new: NewRecording, audio: Data, language: String,
                                    ids: any ServerRecordingIds,
                                    progress: @escaping @Sendable (Int, Int) -> Void = { _, _ in },
                                    sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) })
        async throws -> RemoteTranscript {
        guard let account = user?.id else { throw AccountError.signedOut }
        // The server finds the same audio by its SHA-256, so a fresh key per call is safe.
        let server = try await upload(new, audio: audio, idempotencyKey: UUID().uuidString, progress: progress)
        try await ids.keep(ServerRecordingId(id: server, hasAudio: true), local: local, account: account)
        let started = try await transcribe(recordingId: server, language: language, idempotencyKey: UUID().uuidString)
        _ = try await waitForTask(started.id, sleep: sleep)
        return try await transcript(recordingId: server)
    }

    /// Sends only the text (product-spec.md §7.3b: 已有文字稿时，纪要只发文字), summarizes it and
    /// returns the summary. Uses the server recording kept for `local`, with or without audio;
    /// makes a text-only one when there is none, or when the server no longer has it.
    /// `fromServer`: the local transcript came from this account's transcription; the server's
    /// own copy (with speakers, end times and speaker names) is kept and summarized as it is,
    /// never replaced by the app's shorter copy. Edits made on the phone are then not sent.
    public func summarizeText(local: UUID, _ details: RecordingDetails, lines: [TranscriptLine], engine: String,
                              language: String, templateId: String?, profession: String,
                              ids: any ServerRecordingIds, fromServer: Bool = false,
                              sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) })
        async throws -> RemoteSummary {
        guard let account = user?.id else { throw AccountError.signedOut }
        let client = client
        // A retry after a lost answer makes no second recording; after the server lost the
        // first one, a fresh key makes a new one instead of replaying the old answer.
        func create(_ key: String) async throws -> UUID {
            let made = try await authorized { try await client.createRecording(accessToken: $0, details, idempotencyKey: key) }
            try await ids.keep(ServerRecordingId(id: made.id, hasAudio: false), local: local, account: account)
            return made.id
        }
        var server: UUID
        var known = false
        var serverTranscript = false
        if let kept = try await ids.serverId(local: local, account: account) {
            server = kept.id
            known = true
            serverTranscript = fromServer && kept.hasAudio
        } else {
            server = try await create("text-\(local.uuidString.lowercased())")
        }
        do {
            if !serverTranscript {
                _ = try await putTranscript(recordingId: server, engine: engine, language: language, lines: lines)
            }
        } catch let error as AccountError where known && error.code == "recording_not_found" {
            try await ids.forget(local: local, account: account)
            server = try await create(UUID().uuidString)
            _ = try await putTranscript(recordingId: server, engine: engine, language: language, lines: lines)
        }
        let started = try await summarize(recordingId: server, templateId: templateId, profession: profession,
                                          idempotencyKey: UUID().uuidString)
        _ = try await waitForTask(started.id, sleep: sleep)
        guard let newest = try await summaries(recordingId: server).first else { throw AccountError.badResponse(200) }
        return newest
    }
}

extension TranscriptLine {
    /// The app keeps only where each line starts: it ends where the next one starts, and the last
    /// one at the end of the recording (never before its own start).
    public static func lines(starts segments: [(startMs: Int, text: String)], durationMs: Int) -> [TranscriptLine] {
        segments.enumerated().map { index, segment in
            let next = index + 1 < segments.count ? segments[index + 1].startMs : durationMs
            return TranscriptLine(startMs: max(0, segment.startMs), endMs: max(segment.startMs, next, 0),
                                  text: segment.text)
        }
    }

    /// What `engine` the server is told for the app's transcript engine: "cloud" is the user's own
    /// service; names the server does not take become "app".
    public static func serverEngine(_ engine: String) -> String {
        if engine == "cloud" { return "own-service" }
        let allowed = engine.count <= 32 && !engine.isEmpty
            && engine.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" }
        return allowed ? engine : "app"
    }

    /// The server takes "zh", "zh-CN" or "auto"; anything else (an imported text is "und") is "auto".
    public static func serverLanguage(_ language: String) -> String {
        let parts = language.split(separator: "-", omittingEmptySubsequences: false)
        let lower = parts.first.map { $0.count == 2 && $0.unicodeScalars.allSatisfy { ("a"..."z").contains($0) } } ?? false
        let upper = parts.count == 1
            || (parts.count == 2 && parts[1].count == 2 && parts[1].unicodeScalars.allSatisfy { ("A"..."Z").contains($0) })
        return lower && upper ? language : "auto"
    }
}
