import Assistant
import Foundation
import Library
import Observation
import os
import Transcription

/// "录完自动整理" (features.md X22): a recording that reaches the phone gets its transcript and
/// summary without a tap, through the same transcriber and service the recording page uses.
///
/// - Off unless the user turned it on; only recordings stored since then are processed, so
///   turning it on never sends the whole library (`Preferences.autoProcessSince`).
/// - One recording at a time, oldest first. A step already done (a transcript, a summary) is
///   skipped; a step without what it needs (no transcriber, no service) is left for the page.
/// - Each recording is tried once per app run. A failure leaves the page's own buttons and is
///   tried again on later launches for 3 days; it shows no Toast, as nobody asked for it on screen.
/// - Runs only while the app runs. It is not a device function: the card, sync and playback
///   never wait for it (CLAUDE.md rule 3).
@MainActor
@Observable
public final class AutoProcessor {
    /// The recording being processed now, if any.
    public private(set) var current: UUID?

    @ObservationIgnored private let library: RecordingLibrary
    @ObservationIgnored private let preferences: Preferences
    @ObservationIgnored private let transcriberSource: @MainActor () -> (any SpeechTranscribing)?
    @ObservationIgnored private let assistant: AssistantConfigSource?
    @ObservationIgnored private let summarizer: Summarizer
    @ObservationIgnored private let jobs: TranscriptionJobs
    @ObservationIgnored private let diagnostics: DiagnosticLog?
    @ObservationIgnored private let log = Logger(subsystem: "revive", category: "AutoProcess")
    @ObservationIgnored private var observation: LibraryObservation?
    @ObservationIgnored private var queue: [UUID] = []
    /// Tried in this run, whatever came of it.
    @ObservationIgnored private var tried: Set<UUID> = []
    @ObservationIgnored private var worker: Task<Void, Never>?

    public init(library: RecordingLibrary, preferences: Preferences,
                transcriberSource: @escaping @MainActor () -> (any SpeechTranscribing)?,
                assistant: AssistantConfigSource?, summarizer: Summarizer = Summarizer(),
                jobs: TranscriptionJobs = .shared, diagnostics: DiagnosticLog? = nil) {
        self.library = library
        self.preferences = preferences
        self.transcriberSource = transcriberSource
        self.assistant = assistant
        self.summarizer = summarizer
        self.jobs = jobs
        self.diagnostics = diagnostics
    }

    /// Watches the library from now on. The first value arrives at once, so recordings stored
    /// while the app was not running (since the switch was turned on) are picked up too.
    public func start() {
        guard observation == nil else { return }
        observation = library.observeRecordings(
            onError: { [weak self] in self?.log.error("observe failed: \(String(describing: $0), privacy: .public)") },
            onChange: { [weak self] in self?.consider($0) })
    }

    public func stop() {
        observation?.cancel()
        observation = nil
        worker?.cancel()
        worker = nil
        queue = []
    }

    /// How long a recording that failed stays due on later launches.
    nonisolated static let retryWindow: TimeInterval = 3 * 24 * 3600

    /// Recordings that are due: stored since the switch went on and within `retryWindow` of
    /// `now`, not tried in this run.
    nonisolated static func due(_ recordings: [Recording], since: Date?, tried: Set<UUID>,
                                now: Date = Date()) -> [Recording] {
        guard let since else { return [] }
        let start = max(since, now.addingTimeInterval(-retryWindow))
        return recordings
            .filter { $0.trashedAt == nil && $0.createdAt >= start && !tried.contains($0.id) }
            .sorted { $0.createdAt < $1.createdAt }
    }

    private func consider(_ recordings: [Recording]) {
        let due = Self.due(recordings, since: preferences.autoProcessSince, tried: tried.union(queue))
        guard !due.isEmpty else { return }
        queue += due.map(\.id)
        guard worker == nil else { return }
        worker = Task { [weak self] in
            while let self, let id = self.next() {
                await self.process(id)
            }
            self?.worker = nil
            self?.current = nil
        }
    }

    private func next() -> UUID? {
        guard preferences.autoProcessEnabled, !queue.isEmpty else {
            queue = []
            return nil
        }
        let id = queue.removeFirst()
        tried.insert(id)
        current = id
        return id
    }

    private func process(_ id: UUID) async {
        // Deleted, or moved to 最近删除, while it waited.
        guard var recording = try? library.recording(id: id), recording.trashedAt == nil else { return }
        if (try? library.transcript(recordingId: id)) == nil, recording.hasAudio {
            guard await transcribe(recording) else { return }
        }
        guard (try? library.summary(recordingId: id)) == nil,
              let transcript = try? library.transcript(recordingId: id),
              let config = assistant?.current() else { return }
        recording = (try? library.recording(id: id)) ?? recording
        await summarize(recording, transcript: transcript, config: config)
    }

    /// True when a transcript is stored afterwards.
    private func transcribe(_ recording: Recording) async -> Bool {
        guard let transcriber = transcriberSource(),
              jobs.begin(recording.id, audioMs: recording.durationMs, usesNetwork: transcriber.usesNetwork)
        else { return false }
        var succeeded = false
        defer { jobs.end(recording.id, succeeded: succeeded) }
        do {
            // Same language and 纠错词库 as the recording page's "转成文字".
            let segments = library.corrected(try await transcriber.transcribe(recording, language: "zh-CN"))
            try library.saveTranscript(Transcript(recordingId: recording.id, engine: transcriber.engineName,
                                                  language: "zh-CN", segments: segments, createdAt: Date()))
            succeeded = true
            diagnostics?.add("auto", "transcribed, \(segments.count) lines, \(transcriber.engineName)")
        } catch {
            diagnostics?.add("auto", "transcription failed: \(Self.describe(error))")
        }
        return succeeded
    }

    private func summarize(_ recording: Recording, transcript: Transcript, config: ServiceConfig) async {
        guard jobs.beginSummary(recording.id) else { return }
        defer { jobs.endSummary(recording.id) }
        do {
            let draft = try await summarizer.summarize(transcript: Summarizer.material(from: transcript),
                                                       durationMs: recording.durationMs, config: config,
                                                       fixedScene: nil)
            let stored = try library.saveSummary(draft.record(recordingId: recording.id))
            // The summary's title becomes the recording's unless the user renamed it (G1, X6).
            _ = try library.applyAITitle(id: recording.id, stored.title)
            diagnostics?.add("auto", "summarized")
        } catch {
            diagnostics?.add("auto", "summary failed: \(Self.describe(error))")
        }
    }

    /// The error's kind only: no text of the recording, no address or key goes into the log.
    private static func describe(_ error: Error) -> String {
        switch error {
        case AssistantError.notConfigured: "not configured"
        case AssistantError.http(let code, _): "http \(code)"
        case AssistantError.badReply: "bad reply"
        case AssistantError.unreachable: "unreachable"
        case TranscriptionError.permissionDenied: "permission denied"
        case TranscriptionError.unsupportedLanguage: "unsupported language"
        case TranscriptionError.noSpeech: "no speech"
        case TranscriptionError.audioMissing: "audio missing"
        case TranscriptionError.failed: "failed"
        case is CancellationError: "cancelled"
        default: String(describing: type(of: error))
        }
    }
}
