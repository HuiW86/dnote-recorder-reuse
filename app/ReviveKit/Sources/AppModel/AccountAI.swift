import Account
import AIRoute
import CryptoKit
import Foundation
import Library
import Transcription

// The 闻笺 account as the third AI path (product-spec.md §7.3b, ADR-009), joined to the library:
// which server recording each local one is, the transcriber, summaries from the stored
// transcript, and what each path can do right now (AISituation). The pages and 录完自动整理 come
// here only when AIRoute chose the account; the card never does (CLAUDE.md rule 3).

/// The library's `remote_recording`, as the account flows keep it.
public struct LibraryServerIds: ServerRecordingIds {
    private let library: RecordingLibrary

    public init(library: RecordingLibrary) {
        self.library = library
    }

    public func serverId(local: UUID, account: UUID) async throws -> ServerRecordingId? {
        try library.serverRecordingLink(recordingId: local, accountId: account)
            .map { ServerRecordingId(id: $0.serverId, hasAudio: $0.hasAudio) }
    }

    public func keep(_ server: ServerRecordingId, local: UUID, account: UUID) async throws {
        try library.saveServerRecordingLink(ServerRecordingLink(accountId: account, recordingId: local,
                                                                serverId: server.id, hasAudio: server.hasAudio))
    }

    public func forget(local: UUID, account: UUID) async throws {
        try library.forgetServerRecordingLinks(accountId: account, recordingId: local)
    }
}

/// 转成文字 with the 闻笺 account: the stored audio goes to our backend as it is (OGG or M4A),
/// the server transcribes it, and its lines come back. The page says the audio is uploaded.
public struct AccountTranscriber: SpeechTranscribing {
    public static let engineName = "account"
    public var engineName: String { Self.engineName }
    public var usesNetwork: Bool { true }

    private let library: RecordingLibrary
    private let session: AccountSession
    private let progress: @Sendable (Int, Int) -> Void

    /// `progress` gets the bytes the server holds and the total while the audio goes up.
    public init(library: RecordingLibrary, session: AccountSession,
                progress: @escaping @Sendable (Int, Int) -> Void = { _, _ in }) {
        self.library = library
        self.session = session
        self.progress = progress
    }

    public func transcribe(_ recording: Recording, language: String) async throws -> [TranscriptSegment] {
        guard recording.hasAudio,
              let audio = try? Data(contentsOf: library.store.url(forAudioPath: recording.audioPath)) else {
            throw TranscriptionError.audioMissing
        }
        let new = NewRecording(source: AccountAI.source(recording.source), startedAt: recording.startedAt,
                               durationMs: recording.durationMs, title: recording.title,
                               sha256: AccountAI.sha256(audio), size: audio.count,
                               contentType: AccountAI.contentType(audioPath: recording.audioPath))
        let remote = try await session.transcribeRecording(local: recording.id, new, audio: audio,
                                                           language: TranscriptLine.serverLanguage(language),
                                                           ids: LibraryServerIds(library: library), progress: progress)
        return AccountAI.segments(remote)
    }
}

public enum AccountAI {
    /// 生成纪要 with the 闻笺 account from the stored transcript: only its text goes (§7.3b). The
    /// summary is returned to be stored like the user's service's (`RecordingLibrary.saveSummary`).
    public static func summarize(_ recording: Recording, transcript: Transcript, scene: String?, profession: String,
                                 session: AccountSession, library: RecordingLibrary) async throws -> Summary {
        let lines = TranscriptLine.lines(starts: transcript.segments.map { ($0.startMs, $0.text) },
                                         durationMs: recording.durationMs)
        let details = RecordingDetails(source: source(recording.source), startedAt: recording.startedAt,
                                       durationMs: recording.durationMs, title: recording.title)
        let remote = try await session.summarizeText(
            local: recording.id, details, lines: lines, engine: TranscriptLine.serverEngine(transcript.engine),
            language: TranscriptLine.serverLanguage(transcript.language), templateId: scene, profession: profession,
            ids: LibraryServerIds(library: library), fromServer: transcript.engine == AccountTranscriber.engineName)
        return summary(remote, recordingId: recording.id)
    }

    /// The account signed out or was deleted (`AccountModel.onLeave`): the confirmations go
    /// (§7.3b: signing in again asks again); after a deletion the server has none of its
    /// recordings, so which server recording each local one was goes too.
    @MainActor
    public static func leave(_ account: UUID, deleted: Bool, preferences: Preferences, library: RecordingLibrary?) {
        preferences.forgetAIConsents()
        if deleted { try? library?.forgetServerRecordingLinks(accountId: account) }
    }

    /// What each path can do right now, for AIRoute. `onDeviceSupported` is whether this phone
    /// recognizes the language offline; `accountSignedIn` is nil in a build without a server.
    @MainActor
    public static func situation(for work: AIWork, preferences: Preferences, onDeviceSupported: Bool,
                                 ownTranscription: Bool, ownService: Bool, accountSignedIn: Bool?,
                                 hasTranscript: Bool) -> AISituation {
        var options: [AIPathOption] = []
        for path in work.paths {
            switch path {
            case .onDevice:
                options.append(AIPathOption(.onDevice, problem: onDeviceSupported ? nil : .unsupported))
            case .ownService:
                // Transcription lists the user's service only once it has a transcription model.
                if work == .transcribe {
                    if ownTranscription { options.append(AIPathOption(.ownService)) }
                } else {
                    options.append(AIPathOption(.ownService, problem: ownService ? nil : .notConfigured))
                }
            case .account:
                if let signedIn = accountSignedIn {
                    options.append(AIPathOption(.account, problem: signedIn ? nil : .signedOut))
                }
            }
        }
        let defaultPath = work == .transcribe ? preferences.defaultTranscriptionPath : preferences.defaultSummaryPath
        return AISituation(options: options, defaultPath: defaultPath, consents: preferences.aiConsents,
                           hasTranscript: hasTranscript)
    }

    static func source(_ source: Recording.Source) -> NewRecording.Source {
        switch source {
        case .card, .realtime: .card
        case .phone: .phone
        case .import: .import
        }
    }

    static func contentType(audioPath: String) -> String {
        switch (audioPath as NSString).pathExtension.lowercased() {
        case "ogg", "opus", "": "audio/ogg"
        case "m4a", "mp4": "audio/mp4"
        case "mp3": "audio/mpeg"
        case "wav": "audio/wav"
        case "caf": "audio/x-caf"
        case let other: "audio/\(other)"
        }
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// The server's lines as the library keeps them: start and text (names of speakers stay on
    /// the server).
    static func segments(_ remote: RemoteTranscript) -> [TranscriptSegment] {
        remote.segments.sorted { $0.startMs < $1.startMs }.map { TranscriptSegment(startMs: $0.startMs, text: $0.text) }
    }

    static func summary(_ remote: RemoteSummary, recordingId: UUID, now: Date = Date()) -> Summary {
        Summary(recordingId: recordingId, scene: remote.scene, title: remote.title, summary: remote.summary,
                sections: remote.sections.map { SummarySection(heading: $0.heading, items: $0.items) },
                todos: remote.todos.map { SummaryTodo(text: $0) }, tags: remote.tags, people: remote.people,
                outline: remote.outline.map { OutlineItem(title: $0.title, points: $0.points) },
                quotes: remote.quotes, model: remote.model, createdAt: now)
    }
}
