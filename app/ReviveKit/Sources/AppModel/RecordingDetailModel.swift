import Assistant
import Foundation
import Library
import Observation
import os
import Player
import Transcription

/// Recording detail: player, file info, export and delete (product-spec.md P06).
@MainActor
@Observable
public final class RecordingDetailModel {
    public let recordingId: UUID
    public let player: RecordingPlayer
    /// Nil when the recording is not in the library (deleted elsewhere).
    public private(set) var recording: Recording?
    /// The system cannot open the OGG directly and the decode is running ("正在准备播放").
    public private(set) var isPreparing = false
    /// The OGG file is gone; the page offers to delete the row.
    public private(set) var audioMissing = false
    /// An M4A export is being made; the share button shows progress meanwhile.
    public private(set) var isExporting = false
    /// Points marked while recording, in playback order (features.md X7).
    public private(set) var marks: [RecordingMark] = []
    /// The stored text of this recording, if it has been transcribed (features.md X9).
    public private(set) var transcript: Transcript?
    /// A transcription of this recording is running, started from this page or an earlier one.
    public var isTranscribing: Bool { jobs.running.contains(recordingId) }
    /// The stored summary (features.md G1), if one was made.
    public private(set) var summary: Summary?
    public private(set) var isSummarizing = false
    /// Result of the last rewrite or question (features.md X15, G3); shown in a sheet.
    public var assistantOutput: AssistantOutput?
    public private(set) var isAsking = false
    /// Set after a delete; the page closes.
    public private(set) var isDeleted = false
    public var toast: Toast?

    @ObservationIgnored private let library: RecordingLibrary
    @ObservationIgnored private let deviceNames: [UUID: String]
    @ObservationIgnored private var playTask: Task<Void, Never>?
    /// Nil when on-device transcription is switched off.
    @ObservationIgnored private let transcriber: (any SpeechTranscribing)?
    /// The user's AI service; nil when the app has none (features.md X11).
    @ObservationIgnored private let assistant: AssistantConfigSource?
    @ObservationIgnored private let jobs: TranscriptionJobs
    @ObservationIgnored private let summarizer: Summarizer
    @ObservationIgnored private let log = Logger(subsystem: "revive", category: "Detail")

    public init(recordingId: UUID, library: RecordingLibrary, player: RecordingPlayer,
                transcriber: (any SpeechTranscribing)? = nil, assistant: AssistantConfigSource? = nil,
                summarizer: Summarizer = Summarizer(), jobs: TranscriptionJobs = .shared) {
        self.recordingId = recordingId
        self.library = library
        self.player = player
        self.transcriber = transcriber
        self.assistant = assistant
        self.summarizer = summarizer
        self.jobs = jobs
        transcript = try? library.transcript(recordingId: recordingId)
        summary = try? library.summary(recordingId: recordingId)
        recording = try? library.recording(id: recordingId)
        deviceNames = Dictionary(((try? library.pairedDevices()) ?? []).map { ($0.id, $0.name) },
                                 uniquingKeysWith: { a, _ in a })
        if let recording {
            marks = (try? library.marks(for: recording)) ?? []
            audioMissing = !FileManager.default.fileExists(atPath: library.store.url(forAudioPath: recording.audioPath).path)
        }
    }

    // MARK: - Player

    private var isLoaded: Bool { player.recordingId == recordingId }

    public var isPlaying: Bool { isLoaded && player.state == .playing }

    /// Player duration once loaded; before that, the duration stored at sync.
    public var duration: TimeInterval {
        isLoaded ? player.duration : Double(recording?.durationMs ?? 0) / 1000
    }

    /// Read from a TimelineView; the player's position is not observed.
    public var currentTime: TimeInterval { isLoaded ? player.currentTime : 0 }

    public func togglePlay() {
        if isPlaying {
            player.pause()
            return
        }
        guard let recording, playTask == nil else { return }
        playTask = Task {
            // Only a decode takes noticeable time; show the spinner if loading is not instant.
            let spinner = Task {
                try await Task.sleep(for: .milliseconds(150))
                isPreparing = true
            }
            defer {
                spinner.cancel()
                isPreparing = false
                playTask = nil
            }
            do {
                try await player.play(recording)
            } catch is CancellationError {
                // Left the page or played another recording: silent (product-spec.md P06).
            } catch PlayerError.audioMissing {
                audioMissing = true
            } catch {
                log.error("cannot play \(recording.id, privacy: .public): \(String(describing: error), privacy: .public)")
                toast = Toast("无法播放这条录音")
            }
        }
    }

    /// Jumps by `seconds` (negative goes back), within the recording.
    public func skip(by seconds: TimeInterval) {
        guard isLoaded else { return }
        player.seek(to: player.currentTime + seconds)
    }

    public func seek(to time: TimeInterval) {
        guard isLoaded else { return }
        player.seek(to: time)
    }

    // MARK: - Speed and marks on the player bar (design-spec.md §3)

    public static let speeds: [Float] = [1, 1.25, 1.5, 2, 0.75]

    /// "1.25×" on the speed button.
    public var speedText: String {
        let rate = player.rate
        return (rate == rate.rounded() ? String(Int(rate)) : String(format: "%g", rate)) + "×"
    }

    /// Next speed in `speeds`.
    public func cycleSpeed() {
        let index = Self.speeds.firstIndex(of: player.rate) ?? 0
        player.setRate(Self.speeds[(index + 1) % Self.speeds.count])
    }

    /// Where the marks sit on the progress bar, 0…1.
    public var markPositions: [Double] {
        let total = Double(recording?.durationMs ?? 0)
        guard total > 0 else { return [] }
        return marks.map { min(1, Double($0.offsetMs) / total) }
    }

    // MARK: - Transcript (features.md X9)

    /// The audio is uploaded to the user's service to transcribe it (ADR-009); the page says so.
    public var transcriptionUsesNetwork: Bool { transcriber?.usesNetwork ?? false }

    /// "转成文字" is offered when transcription is switched on and nothing is running.
    public var canTranscribe: Bool { transcriber != nil && recording != nil && !audioMissing }

    /// Recognizes the recording on this phone and stores the text. Replaces an earlier transcript.
    public func transcribe(language: String = "zh-CN") {
        guard let transcriber, let recording, jobs.begin(recording.id) else { return }
        Task { [jobs] in
            defer { jobs.end(recording.id) }
            do {
                let segments = try await transcriber.transcribe(recording, language: language)
                let result = Transcript(recordingId: recording.id, engine: transcriber.engineName,
                                        language: language, segments: segments, createdAt: Date())
                try library.saveTranscript(result)
                transcript = result
            } catch let error as TranscriptionError {
                toast = Toast(Self.text(for: error))
            } catch {
                toast = Toast("转写失败，请重试")
            }
        }
    }

    private static func text(for error: TranscriptionError) -> String {
        switch error {
        case .permissionDenied: "没有语音识别权限，请到系统「设置」里为闻笺打开"
        case .unsupportedLanguage: "这部手机不支持离线识别这种语言"
        case .noSpeech: "没有识别到说话声"
        case .audioMissing: "找不到这条录音的音频文件"
        case .failed: "转写失败，请重试"
        }
    }

    // MARK: - Summary (features.md G1, X11)

    /// "生成纪要" needs a transcript and a configured service.
    public var canSummarize: Bool { transcript != nil && assistant?.current() != nil }

    /// Why "生成纪要" is not offered, when there is a transcript; nil otherwise.
    public var summaryHint: String? {
        guard transcript != nil, summary == nil, assistant?.current() == nil else { return nil }
        return "在「设置 → AI 服务」里填上你的服务后，可以把文字稿整理成纪要"
    }

    /// Sends the transcript to the user's service and stores the summary. The text leaves the
    /// phone here, to the service the user chose (ADR-009); nothing else does.
    public func summarize() {
        guard let transcript, let recording, let config = assistant?.current(), !isSummarizing else { return }
        isSummarizing = true
        let material = Summarizer.material(from: transcript)
        Task {
            defer { isSummarizing = false }
            do {
                let draft = try await summarizer.summarize(transcript: material, durationMs: recording.durationMs,
                                                           config: config)
                let stored = draft.record(recordingId: recording.id)
                try library.saveSummary(stored)
                summary = stored
            } catch let error as AssistantError {
                toast = Toast(AssistantSettingsModel.text(for: error))
            } catch is CancellationError {
                // Left the page.
            } catch {
                toast = Toast("生成纪要失败，请重试")
            }
        }
    }

    // MARK: - Rewrite and ask (features.md X15, G3)

    /// Rewriting and asking need some text and a configured service.
    public var canRewrite: Bool { (transcript != nil || summary != nil) && assistant?.current() != nil }

    public func rewrite(_ style: RewriteStyle, extra: String = "") {
        run(title: style.name) { config, material, rewriter in
            try await rewriter.rewrite(material: material, style: style, extra: extra, config: config)
        }
    }

    public func ask(_ question: String) {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        run(title: trimmed) { config, material, rewriter in
            try await rewriter.answer(question: trimmed, material: material, config: config)
        }
    }

    private func run(title: String,
                     _ work: @escaping @Sendable (ServiceConfig, String, Rewriter) async throws -> String) {
        guard let config = assistant?.current(), !isAsking else { return }
        let material = Rewriter.material(summary: summary, transcript: transcript)
        guard !material.isEmpty else { return }
        isAsking = true
        let rewriter = Rewriter(client: summarizer.client)
        Task {
            defer { isAsking = false }
            do {
                let text = try await work(config, material, rewriter)
                assistantOutput = AssistantOutput(title: title, text: text)
            } catch let error as AssistantError {
                toast = Toast(AssistantSettingsModel.text(for: error))
            } catch is CancellationError {
            } catch {
                toast = Toast("请求失败，请重试")
            }
        }
    }

    /// Ticks or unticks a to-do of the summary.
    public func setTodo(_ index: Int, done: Bool) {
        do {
            if let updated = try library.setTodoDone(recordingId: recordingId, index: index, done: done) {
                summary = updated
            }
        } catch {
            toast = Toast("保存失败，请重试")
        }
    }

    /// "会议", "访谈"… for the stored scene code.
    public var sceneName: String? {
        summary.flatMap { RecordingScene(rawValue: $0.scene)?.name }
    }

    /// Reads the stored transcript again: a transcription started from an earlier page may
    /// have finished while this one was open.
    public func reloadTranscript() {
        transcript = try? library.transcript(recordingId: recordingId)
    }

    /// "00:18:06" for a transcript line.
    public func timeText(_ segment: TranscriptSegment) -> String {
        RecordingText.clock(seconds: segment.startMs / 1000)
    }

    /// Plays from a transcript line.
    public func play(from segment: TranscriptSegment) {
        play(fromMs: segment.startMs)
    }

    /// Plays from a mark; loads the recording first when it is not the one in the player.
    public func play(from mark: RecordingMark) {
        play(fromMs: mark.offsetMs)
    }

    private func play(fromMs offsetMs: Int) {
        let target = Double(offsetMs) / 1000
        if isLoaded {
            player.seek(to: target)
            return
        }
        guard let recording, playTask == nil else { return }
        playTask = Task {
            defer { playTask = nil }
            do {
                try await player.play(recording)
                player.seek(to: target)
            } catch is CancellationError {
                // Left the page: silent, as in `togglePlay`.
            } catch PlayerError.audioMissing {
                audioMissing = true
            } catch {
                toast = Toast("无法播放这条录音")
            }
        }
    }

    /// "00:18:06" for a mark row.
    public func markText(_ mark: RecordingMark) -> String {
        RecordingText.clock(seconds: mark.offsetMs / 1000)
    }

    /// Leaving the page while a decode runs cancels it; playback that already started goes on.
    public func leave() {
        if playTask != nil, !isPlaying { player.stop() }
    }

    // MARK: - Info

    public var title: String { recording.map { RecordingText.title($0) } ?? "" }

    /// "2026-11-07 14:02:11" on the player card.
    public var startedAtText: String {
        guard let recording else { return "" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.string(from: recording.startedAt)
    }

    public var durationText: String { RecordingText.longDuration(ms: recording?.durationMs ?? 0) }

    public var sourceText: String? {
        recording?.deviceId.flatMap { deviceNames[$0] }
    }

    public var sizeText: String {
        guard let recording else { return "" }
        let url = library.store.url(forAudioPath: recording.audioPath)
        let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    // MARK: - Export and delete

    /// A temporary `<title>.ogg` for the share sheet (features.md E1a); nil with a toast on failure.
    public func exportFile() -> URL? {
        guard let recording else { return nil }
        do {
            return try RecordingExporter.exportFile(for: recording, library: library)
        } catch PlayerError.audioMissing {
            audioMissing = true
        } catch {
            toast = Toast("导出失败，请重试")
        }
        return nil
    }

    /// A temporary `<title>.m4a` for the share sheet (features.md E1b); nil with a toast on failure.
    public func exportM4A() async -> URL? {
        guard let recording, !isExporting else { return nil }
        isExporting = true
        defer { isExporting = false }
        do {
            return try await RecordingExporter.exportM4A(for: recording, library: library)
        } catch PlayerError.audioMissing {
            audioMissing = true
        } catch {
            log.error("cannot export m4a: \(String(describing: error), privacy: .public)")
            toast = Toast("导出失败，请重试")
        }
        return nil
    }

    /// Summary and transcript can be shared as Markdown (features.md J1).
    public var canExportMarkdown: Bool { summary != nil || transcript != nil }

    /// A temporary `<title>.md` for the share sheet; nil with a toast on failure.
    public func exportMarkdown() -> URL? {
        guard let recording else { return nil }
        let text = MarkdownExport.markdown(title: title, recording: recording, sceneName: sceneName,
                                           summary: summary, transcript: transcript)
        do {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("export", isDirectory: true)
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent(RecordingExporter.fileName(for: recording.title, fileExtension: "md"))
            try Data(text.utf8).write(to: url, options: .atomic)
            return url
        } catch {
            toast = Toast("导出失败，请重试")
            return nil
        }
    }

    /// The title to start a rename from: the user's own, or empty for the default one.
    public var editableTitle: String {
        guard let recording, recording.hasCustomTitle else { return "" }
        return recording.title
    }

    /// Renames the recording; an empty title puts the default back (features.md X6).
    public func rename(to title: String) {
        do {
            if let renamed = try library.renameRecording(id: recordingId, to: title) { recording = renamed }
        } catch {
            toast = Toast("重命名失败，请重试")
        }
    }

    /// Moves the local recording to 最近删除 (features.md D1b); nothing is sent to the card
    /// (product-spec.md §3.3).
    public func delete() {
        if isLoaded { player.stop() }
        do {
            try library.trashRecording(id: recordingId)
            isDeleted = true
        } catch {
            toast = Toast("删除失败，请重试")
        }
    }
}

/// Text the user's service wrote for this recording: a rewrite or an answer.
public struct AssistantOutput: Equatable, Identifiable, Sendable {
    public let id = UUID()
    public let title: String
    public let text: String
}
