// 用闻笺账号转写 (ADR-009's third path; features.md F1): put a recording's audio on our backend,
// start a transcription and read the transcript (prd.md §7.2 录音与上传、转写、任务; backend/
// revive_api/routers/recordings.py, transcripts.py). Nothing here runs unless the user picks the
// account for AI work; the card never needs it (CLAUDE.md rule 3).

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A recording to put on the server. The audio is identified by its SHA-256: the server keeps
/// one recording per account and audio, so sending the same audio again returns the first one.
public struct NewRecording: Equatable, Sendable {
    public enum Source: String, Sendable {
        case card, phone, `import`
    }

    public var source: Source
    public var startedAt: Date
    public var durationMs: Int
    public var title: String
    /// Lowercase hex.
    public var sha256: String
    public var size: Int
    /// "audio/ogg" for card recordings, "audio/mp4" for M4A.
    public var contentType: String

    public init(source: Source, startedAt: Date, durationMs: Int, title: String, sha256: String, size: Int,
                contentType: String) {
        self.source = source
        self.startedAt = startedAt
        self.durationMs = durationMs
        self.title = title
        self.sha256 = sha256
        self.size = size
        self.contentType = contentType
    }
}

/// The server's recording (`RecordingOut`): only what uploading needs.
public struct RemoteRecording: Decodable, Equatable, Sendable {
    public struct Audio: Decodable, Equatable, Sendable {
        public let sha256: String
        public let size: Int
        public let uploaded: Bool
    }

    /// Where each part goes (`UploadOut`); present only while the audio is not stored.
    public struct Upload: Decodable, Equatable, Sendable {
        public let partSize: Int
        public let parts: [Part]
    }

    public struct Part: Decodable, Equatable, Sendable {
        public let partNumber: Int
        public let offset: Int
        public let size: Int
        public let url: URL
        /// Already stored: not sent again.
        public let done: Bool
        public let etag: String?
    }

    public let id: UUID
    public let audio: Audio?
    public let upload: Upload?
}

/// A server task (`TaskOut`): transcription now, summaries later.
public struct RemoteTask: Decodable, Equatable, Sendable {
    public enum Status: String, Decodable, Sendable {
        case queued, running, succeeded, failed
    }

    public struct Failure: Decodable, Equatable, Sendable {
        public let code: String
        public let message: String
    }

    /// What a task answers on itself: a new title for `retitle`; nil for kinds that store
    /// their result elsewhere (a transcript, a summary).
    public struct Outcome: Decodable, Equatable, Sendable {
        public let title: String?
    }

    public let id: UUID
    public let kind: String
    /// A retry waiting shows `queued` with the last error.
    public let status: Status
    public let error: Failure?
    public let result: Outcome?
}

/// The server's transcript (`TranscriptOut`).
public struct RemoteTranscript: Decodable, Equatable, Sendable {
    public struct Segment: Decodable, Equatable, Sendable {
        public let startMs: Int
        public let endMs: Int
        /// The engine's label ("S1"), nil when it does not tell speakers apart.
        public let speaker: String?
        public let text: String
    }

    public let language: String
    public let segments: [Segment]
    /// Names the user gave the labels.
    public let speakers: [String: String]
    public let asrProvider: String
}

extension AccountClient {
    /// 201 with a new recording, 200 with the one this account already has for the same audio.
    public func createRecording(accessToken: String, _ new: NewRecording,
                                idempotencyKey: String) async throws -> RemoteRecording {
        let body: [String: Any] = [
            "source": new.source.rawValue,
            "started_at": Self.timestamp(new.startedAt),
            "duration_ms": new.durationMs,
            "title": new.title,
            "audio": ["sha256": new.sha256, "size": new.size, "content_type": new.contentType],
        ]
        return try decode(await send(request("POST", "/v1/recordings", body: body, bearer: accessToken,
                                             idempotencyKey: idempotencyKey)))
    }

    /// Fresh part URLs, with the parts already stored marked done.
    public func resumeUpload(accessToken: String, recordingId: UUID) async throws -> RemoteRecording {
        try decode(await send(request("POST", "/v1/recordings/\(Self.id(recordingId))/upload", body: nil,
                                      bearer: accessToken)))
    }

    /// PUTs one part to its signed URL (no token: the URL is the permission) and returns the ETag
    /// the store names it by.
    public func putPart(_ data: Data, to url: URL) async throws -> String {
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.httpBody = data
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        let (_, response) = try await exchange(request)
        let etag = response.allHeaderFields.first { ($0.key as? String)?.lowercased() == "etag" }?.value as? String
        guard let etag, !etag.isEmpty else { throw AccountError.badResponse(response.statusCode) }
        return etag
    }

    /// Joins the stored parts; doing it again once stored is not an error.
    public func completeUpload(accessToken: String, recordingId: UUID,
                               parts: [(number: Int, etag: String)]) async throws -> RemoteRecording {
        let body: [String: Any] = ["parts": parts.map { ["part_number": $0.number, "etag": $0.etag] }]
        return try decode(await send(request("POST", "/v1/recordings/\(Self.id(recordingId))/upload-complete",
                                             body: body, bearer: accessToken)))
    }

    /// 202 with a new task, 200 with the one already queued or running. 429 `quota_exceeded`
    /// when this month's transcription time would run out.
    public func transcribe(accessToken: String, recordingId: UUID, language: String,
                           idempotencyKey: String) async throws -> RemoteTask {
        try decode(await send(request("POST", "/v1/recordings/\(Self.id(recordingId))/transcribe",
                                      body: ["language": language, "speakers": true], bearer: accessToken,
                                      idempotencyKey: idempotencyKey)))
    }

    public func task(accessToken: String, id: UUID) async throws -> RemoteTask {
        try decode(await send(request("GET", "/v1/tasks/\(Self.id(id))", body: nil, bearer: accessToken)))
    }

    public func transcript(accessToken: String, recordingId: UUID) async throws -> RemoteTranscript {
        try decode(await send(request("GET", "/v1/recordings/\(Self.id(recordingId))/transcript", body: nil,
                                      bearer: accessToken)))
    }

    /// The server's form of an id: lowercase, as Python prints UUIDs.
    static func id(_ uuid: UUID) -> String {
        uuid.uuidString.lowercased()
    }

    /// ISO 8601 with the offset, which the server requires (`AwareDatetime`).
    static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

// MARK: - 纪要、换角度重起标题、用量 (features.md G1, G2a, X2; backend/revive_api/routers/summaries.py, me.py)

/// A scene the server summarizes by (`TemplateOut`): the same ten scenes the app has (Scene.swift).
public struct SummaryTemplate: Decodable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let definition: String
    public let headings: [String]
}

/// A summary the server wrote (`SummaryOut`); every one is kept, newest first.
public struct RemoteSummary: Decodable, Equatable, Sendable {
    public struct Section: Decodable, Equatable, Sendable {
        public let heading: String
        public let items: [String]
    }

    public struct Outline: Decodable, Equatable, Sendable {
        public let title: String
        public let points: [String]
    }

    public let id: UUID
    public let scene: String
    public let title: String
    public let summary: String
    public let sections: [Section]
    public let todos: [String]
    public let tags: [String]
    public let people: [String]
    public let outline: [Outline]
    public let quotes: [String]
    public let model: String
}

/// This month's use and allowances (`UsageOut`). Months start at midnight Beijing time.
public struct RemoteUsage: Decodable, Equatable, Sendable {
    public struct Allowance: Decodable, Equatable, Sendable {
        public let used: Int
        /// Transcriptions queued or running, held against the allowance.
        public let reserved: Int?
        /// nil: no limit set.
        public let limit: Int?
        public let remaining: Int?
    }

    /// ISO 8601, as the server sends it.
    public let periodStart: String
    public let periodEnd: String
    public let asrSeconds: Allowance
    public let llmTokens: Allowance
}

extension AccountClient {
    public func templates(accessToken: String) async throws -> [SummaryTemplate] {
        try decode(await send(request("GET", "/v1/templates", body: nil, bearer: accessToken)))
    }

    /// 202 with a new task, 200 with the one already queued or running. `templateId` nil lets
    /// the model choose the scene. 409 `no_transcript` before a transcript exists; 429
    /// `quota_exceeded` once this month's model allowance is used up.
    public func summarize(accessToken: String, recordingId: UUID, templateId: String?, profession: String,
                          idempotencyKey: String) async throws -> RemoteTask {
        var body: [String: Any] = ["profession": profession]
        if let templateId { body["template_id"] = templateId }
        return try decode(await send(request("POST", "/v1/recordings/\(Self.id(recordingId))/summaries", body: body,
                                             bearer: accessToken, idempotencyKey: idempotencyKey)))
    }

    public func summaries(accessToken: String, recordingId: UUID) async throws -> [RemoteSummary] {
        try decode(await send(request("GET", "/v1/recordings/\(Self.id(recordingId))/summaries", body: nil,
                                      bearer: accessToken)))
    }

    /// A title from another angle; the finished task's `result.title` holds it. The server does
    /// not change the recording's title: the app decides (it keeps a title the user wrote).
    public func retitle(accessToken: String, recordingId: UUID, currentTitle: String?,
                        idempotencyKey: String) async throws -> RemoteTask {
        var body: [String: Any] = [:]
        if let currentTitle { body["current_title"] = currentTitle }
        return try decode(await send(request("POST", "/v1/recordings/\(Self.id(recordingId))/retitle", body: body,
                                             bearer: accessToken, idempotencyKey: idempotencyKey)))
    }

    public func usage(accessToken: String) async throws -> RemoteUsage {
        try decode(await send(request("GET", "/v1/me/usage", body: nil, bearer: accessToken)))
    }
}

