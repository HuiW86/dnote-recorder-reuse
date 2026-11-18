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
    /// The text of this recording, if it has been transcribed (features.md X9): a run that
    /// finished since the page opened, or the stored one.
    public var transcript: Transcript? { jobs.finished[recordingId] ?? storedTranscript }
    /// A run for this recording is going, started from this page or an earlier one (#85).
    public var isTranscribing: Bool { jobs.isRunning(recordingId) }
    /// The stored summary (features.md G1), if one was made.
    public private(set) var summary: Summary?
    public private(set) var isSummarizing = false
    /// Set after a delete; the page closes.
    public private(set) var isDeleted = false
    public var toast: Toast?

    @ObservationIgnored private let library: RecordingLibrary
    @ObservationIgnored private let deviceNames: [UUID: String]
    @ObservationIgnored private var playTask: Task<Void, Never>?
    /// Read on every use, so the switch in settings applies to an open page (#85); nil while
    /// on-device transcription is switched off.
    @ObservationIgnored private let transcriber: @MainActor () -> (any SpeechTranscribing)?
    @ObservationIgnored private let jobs: TranscriptionJobs
    /// Off once the page is left, so a page kept alive by its observation does not take a
    /// failure meant for the next page.
    @ObservationIgnored private var watchesFailures = true
    private var storedTranscript: Transcript?
    /// Deletes through home, so its "撤销" toast covers a delete made here too (#85).
    @ObservationIgnored private let onDelete: (@MainActor (UUID) -> Bool)?
    /// The user's AI service; nil when the app has none (features.md X11).
    @ObservationIgnored private let assistant: AssistantConfigSource?
    @ObservationIgnored private let summarizer: Summarizer
    @ObservationIgnored private let log = Logger(subsystem: "revive", category: "Detail")

    /// `transcriptions` is the app's one set of runs; nil gives this page its own.
    /// `onDelete` moves the recording to 最近删除 and returns whether it did.
    public init(recordingId: UUID, library: RecordingLibrary, player: RecordingPlayer,
                transcriber: @escaping @MainActor () -> (any SpeechTranscribing)? = { nil },
                transcriptions: TranscriptionJobs? = nil,
                assistant: AssistantConfigSource? = nil, summarizer: Summarizer = Summarizer(),
                onDelete: (@MainActor (UUID) -> Bool)? = nil) {
        self.recordingId = recordingId
        self.library = library
        self.player = player
        self.transcriber = transcriber
        jobs = transcriptions ?? TranscriptionJobs(library: library)
        self.assistant = assistant
        self.summarizer = summarizer
        self.onDelete = onDelete
        storedTranscript = try? library.transcript(recordingId: recordingId)
        summary = try? library.summary(recordingId: recordingId)
        recording = try? library.recording(id: recordingId)
        deviceNames = Dictionary(((try? library.pairedDevices()) ?? []).map { ($0.id, $0.name) },
                                 uniquingKeysWith: { a, _ in a })
        if let recording {
            marks = (try? library.marks(for: recording)) ?? []
            audioMissing = !FileManager.default.fileExists(atPath: library.store.url(forAudioPath: recording.audioPath).path)
        }
        watchTranscriptionFailures()
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

    /// Speeds the 倍速 button steps through, from normal.
    public static let rates: [Float] = [1, 1.25, 1.5, 2, 0.75]

    /// "1.5×" on the 倍速 button.
    public var rateText: String {
        let rate = player.rate
        let text = rate == rate.rounded() ? String(Int(rate)) : String(format: "%g", Double(rate))
        return text + "×"
    }

    /// The 倍速 button: the next speed, back to normal after the last.
    public func nextRate() {
        let i = Self.rates.firstIndex(of: player.rate) ?? 0
        player.rate = Self.rates[(i + 1) % Self.rates.count]
    }

    /// Where the marks sit along the player bar, as fractions of the length (design-spec.md §3).
    public var markFractions: [Double] {
        let length = duration
        guard length > 0 else { return [] }
        return marks.map { min(1, max(0, Double($0.offsetMs) / 1000 / length)) }
    }

    // MARK: - Transcript (features.md X9)

    /// "转成文字" is offered when transcription is switched on.
    public var canTranscribe: Bool { transcriber() != nil && recording != nil && !audioMissing }

    /// Recognizes the recording on this phone and stores the text. Replaces an earlier transcript.
    /// The run outlives the page; a second tap, here or on a reopened page, starts nothing.
    public func transcribe(language: String = "zh-CN") {
        guard let transcriber = transcriber(), let recording, !isTranscribing else { return }
        jobs.start(recording, with: transcriber, language: language)
    }

    /// A failed run is told on the page that is open when it fails, or on the next one.
    private func watchTranscriptionFailures() {
        guard watchesFailures else { return }
        if let failure = jobs.takeFailure(for: recordingId) { toast = Toast(Self.text(for: failure)) }
        withObservationTracking { _ = jobs.failures[recordingId] } onChange: {
            Task { @MainActor [weak self] in self?.watchTranscriptionFailures() }
        }
    }

    private static func text(for error: TranscriptionError) -> String {
        switch error {
        case .permissionDenied: "没有语音识别权限，请到系统「设置」里为闻笺打开"
        case .unsupportedLanguage: "这部手机不支持离线识别这种语言"
        case .noSpeech: "没有识别到说话声"
        case .audioMissing: "找不到这条录音的音频文件"
        case .unreadableAudio: "这条录音的音频无法解码，转不了文字"
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
        watchesFailures = false
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

    /// A temporary `<title>.ogg` for the share sheet (features.md E1a), named as the page shows
    /// the recording ("11月7日 14.02.ogg", #85); nil with a toast on failure.
    public func exportFile() -> URL? {
        guard let recording else { return nil }
        do {
            return try RecordingExporter.exportFile(for: recording, library: library, title: title)
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
            return try await RecordingExporter.exportM4A(for: recording, library: library, title: title)
        } catch PlayerError.audioMissing {
            audioMissing = true
        } catch {
            log.error("cannot export m4a: \(String(describing: error), privacy: .public)")
            toast = Toast("导出失败，请重试")
        }
        return nil
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
    /// (product-spec.md §3.3). Through home when it is there, which then offers "撤销".
    public func delete() {
        if isLoaded { player.stop() }
        if let onDelete {
            if onDelete(recordingId) { isDeleted = true }
            return
        }
        do {
            try library.trashRecording(id: recordingId)
            isDeleted = true
        } catch {
            toast = Toast("删除失败，请重试")
        }
    }
}
