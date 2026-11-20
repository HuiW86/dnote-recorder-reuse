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
    /// An M4A or WAV export is being made; the share button shows progress meanwhile.
    public private(set) var isExporting = false
    /// Points marked while recording, in playback order (features.md X7).
    public private(set) var marks: [PlaybackMark] = []
    /// The stored text of this recording, if it has been transcribed (features.md X9).
    public private(set) var transcript: Transcript?
    /// A transcription of this recording is running, started from this page or an earlier one.
    public var isTranscribing: Bool { jobs.running.contains(recordingId) }
    /// "预计还要 3 分钟" while this recording is being transcribed (#75); nil otherwise.
    public var transcriptionRemainingText: String? { jobs.remainingText(recordingId) }
    /// The stored summary (features.md G1), if one was made.
    public private(set) var summary: Summary?
    /// A summary of this recording is being made, from this page or by 录完自动整理.
    public var isSummarizing: Bool { jobs.summarizing.contains(recordingId) }
    /// Result of the last rewrite or question (features.md X15, G3); shown in a sheet while it
    /// is still arriving. Closing the sheet (setting nil) stops the request.
    public var assistantOutput: AssistantOutput? {
        didSet { if assistantOutput == nil { askTask?.cancel() } }
    }
    public private(set) var isAsking = false
    /// Set after a delete; the page closes.
    public private(set) var isDeleted = false
    public var toast: Toast?

    @ObservationIgnored private let library: RecordingLibrary
    @ObservationIgnored private let deviceNames: [UUID: String]
    @ObservationIgnored private var playTask: Task<Void, Never>?
    @ObservationIgnored private var askTask: Task<Void, Never>?
    /// Read on every use, so turning transcription on or off in settings applies to a page that
    /// is already open (#85). Nil while transcription is switched off.
    @ObservationIgnored private let transcriberSource: @MainActor () -> (any SpeechTranscribing)?
    private var transcriber: (any SpeechTranscribing)? { transcriberSource() }
    /// The user's AI service; nil when the app has none (features.md X11).
    @ObservationIgnored private let assistant: AssistantConfigSource?
    @ObservationIgnored private let jobs: TranscriptionJobs
    @ObservationIgnored private let summarizer: Summarizer
    @ObservationIgnored private let polisher: Polisher
    @ObservationIgnored private let grader: WordGrader
    @ObservationIgnored private let log = Logger(subsystem: "revive", category: "Detail")

    public init(recordingId: UUID, library: RecordingLibrary, player: RecordingPlayer,
                transcriber: (any SpeechTranscribing)? = nil,
                transcriberSource: (@MainActor () -> (any SpeechTranscribing)?)? = nil,
                assistant: AssistantConfigSource? = nil,
                summarizer: Summarizer = Summarizer(), polisher: Polisher? = nil,
                jobs: TranscriptionJobs = .shared) {
        self.recordingId = recordingId
        self.library = library
        self.player = player
        self.transcriberSource = transcriberSource ?? { transcriber }
        self.assistant = assistant
        self.summarizer = summarizer
        self.polisher = polisher ?? Polisher(client: summarizer.client)
        grader = WordGrader(client: summarizer.client)
        self.jobs = jobs
        transcript = try? library.transcript(recordingId: recordingId)
        summary = try? library.summary(recordingId: recordingId)
        wordList = try? library.wordList(recordingId: recordingId)
        recording = try? library.recording(id: recordingId)
        deviceNames = Dictionary(((try? library.pairedDevices()) ?? []).map { ($0.id, $0.name) },
                                 uniquingKeysWith: { a, _ in a })
        if let recording {
            marks = (try? library.playbackMarks(for: recording)) ?? []
            // A text-only recording (features.md E2) has no audio to miss.
            audioMissing = recording.hasAudio
                && !FileManager.default.fileExists(atPath: library.store.url(forAudioPath: recording.audioPath).path)
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
        guard hasAudio else { return }
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
        stopLoop()
        player.seek(to: player.currentTime + seconds)
    }

    public func seek(to time: TimeInterval) {
        guard isLoaded else { return }
        stopLoop()
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
    public var canTranscribe: Bool { transcriber != nil && hasAudio && !audioMissing }

    /// False for an imported text file (features.md E2): no player, no audio exports, no times.
    public var hasAudio: Bool { recording?.hasAudio ?? false }

    /// Recognizes the recording on this phone and stores the text. Replaces an earlier transcript.
    public func transcribe(language: String = "zh-CN") {
        guard let transcriber, let recording,
              jobs.begin(recording.id, audioMs: recording.durationMs, usesNetwork: transcriber.usesNetwork)
        else { return }
        Task { [jobs] in
            var succeeded = false
            defer { jobs.end(recording.id, succeeded: succeeded) }
            do {
                // 纠错词库 (#75): words the user corrected before are fixed in the new text.
                let segments = library.corrected(try await transcriber.transcribe(recording, language: language))
                let result = Transcript(recordingId: recording.id, engine: transcriber.engineName,
                                        language: language, segments: segments, createdAt: Date())
                try library.saveTranscript(result)
                transcript = result
                succeeded = true
            } catch let error as TranscriptionError {
                toast = Toast(Self.text(for: error))
            } catch AssistantError.offline {
                // Transcribing with the user's service, and the phone has no connection.
                toast = Toast(AssistantError.offlineAdvice)
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
    /// `scene` is the template the user picked ("按场景重新生成", features.md G2a); nil lets the
    /// model choose. The summary's title becomes the recording's unless the user renamed it (G1).
    public func summarize(scene: RecordingScene? = nil) {
        guard let transcript, let recording, let config = assistant?.current(),
              jobs.beginSummary(recording.id) else { return }
        let material = Summarizer.material(from: transcript)
        Task { [jobs] in
            defer { jobs.endSummary(recording.id) }
            do {
                let draft = try await summarizer.summarize(transcript: material, durationMs: recording.durationMs,
                                                           config: config, fixedScene: scene)
                // What was stored, with the user's tag rules applied (a deleted tag stays gone).
                let stored = try library.saveSummary(draft.record(recordingId: recording.id))
                summary = stored
                if let titled = try library.applyAITitle(id: recording.id, stored.title) { self.recording = titled }
            } catch let error as AssistantError {
                toast = Toast(AssistantSettingsModel.text(for: error))
            } catch is CancellationError {
                // Left the page.
            } catch {
                toast = Toast("生成纪要失败，请重试")
            }
        }
    }

    /// The scenes "按场景重新生成" offers (features.md G2a).
    public var scenes: [RecordingScene] { RecordingScene.allCases }

    /// "让 AI 重新起标题" needs some text and a configured service.
    public var canRetitle: Bool { canRewrite && !isRetitling }
    public private(set) var isRetitling = false

    /// Asks the user's service for a title from another angle and uses it, replacing even a
    /// title the user typed: they asked for a new one (features.md G1).
    public func retitle() {
        guard let recording, let config = assistant?.current(), !isRetitling else { return }
        let material = summary.map { "\($0.title)\n\($0.summary)" } ?? transcript.map(Summarizer.material(from:)) ?? ""
        guard !material.isEmpty else { return }
        isRetitling = true
        let current = title
        Task {
            defer { isRetitling = false }
            do {
                let new = try await summarizer.retitle(material: material, avoiding: current, config: config)
                if let titled = try library.applyAITitle(id: recording.id, new, replacingUserTitle: true) {
                    self.recording = titled
                    toast = Toast("已换成「\(titled.title)」")
                }
            } catch let error as AssistantError {
                toast = Toast(AssistantSettingsModel.text(for: error))
            } catch is CancellationError {
                // Left the page.
            } catch {
                toast = Toast("起标题失败，请重试")
            }
        }
    }

    // MARK: - Rewrite and ask (features.md X15, G3)

    /// Rewriting and asking need some text and a configured service.
    public var canRewrite: Bool { (transcript != nil || summary != nil) && assistant?.current() != nil }

    public func rewrite(_ style: RewriteStyle, extra: String = "") {
        run(title: style.name) { config, material, rewriter in
            rewriter.rewriteStream(material: material, style: style, extra: extra, config: config)
        }
    }

    public func ask(_ question: String) {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        run(title: trimmed) { config, material, rewriter in
            rewriter.answerStream(question: trimmed, material: material, config: config)
        }
    }

    /// 「解释这一句」(features.md X20 难句解析): the line, with its neighbours as context, explained
    /// by the user's service in the same sheet as a rewrite. Only those lines are sent.
    public func explainLine(_ index: Int) {
        guard let segments = transcript?.segments, segments.indices.contains(index) else { return }
        let line = segments[index].text
        let before = index > 0 ? segments[index - 1].text : nil
        let after = index + 1 < segments.count ? segments[index + 1].text : nil
        run(title: "解释这一句") { config, _, rewriter in
            rewriter.explainStream(line: line, before: before, after: after, config: config)
        }
    }

    /// Opens the sheet at once and fills it as the reply arrives (features.md G3 "SSE 流式").
    /// A reply cut off part way keeps what arrived and says so; one with nothing closes the sheet.
    private func run(title: String,
                     _ stream: @escaping (ServiceConfig, String, Rewriter) -> AsyncThrowingStream<String, Error>) {
        guard let config = assistant?.current(), !isAsking else { return }
        let material = Rewriter.material(summary: summary, transcript: transcript)
        guard !material.isEmpty else { return }
        isAsking = true
        let rewriter = Rewriter(client: summarizer.client)
        let output = AssistantOutput(title: title, text: "", isStreaming: true)
        assistantOutput = output
        let pieces = stream(config, material, rewriter)
        askTask = Task {
            defer { isAsking = false }
            var raw = ""
            /// Still the sheet this request fills (not closed, not replaced).
            var shown: Bool { assistantOutput?.id == output.id }
            do {
                for try await piece in pieces {
                    raw += piece
                    guard shown else { return }
                    assistantOutput?.text = ChatClient.visibleText(raw)
                }
                guard shown else { return }
                if ChatClient.visibleText(raw).isEmpty {
                    assistantOutput = nil
                    toast = Toast(AssistantSettingsModel.text(for: .badReply("回复是空的")))
                } else {
                    assistantOutput?.isStreaming = false
                }
            } catch is CancellationError {
                // The sheet was closed.
            } catch {
                guard shown else { return }
                let why = (error as? AssistantError).map(AssistantSettingsModel.text(for:)) ?? "请求失败，请重试"
                if ChatClient.visibleText(raw).isEmpty {
                    assistantOutput = nil
                    toast = Toast(why)
                } else {
                    assistantOutput?.isStreaming = false
                    assistantOutput?.isCutOff = true
                    toast = Toast("回答没有收完整：" + why)
                }
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

    /// Re-reads the summary and the title, after one was made elsewhere (录完自动整理).
    public func reloadSummary() {
        summary = try? library.summary(recordingId: recordingId)
        if let fresh = try? library.recording(id: recordingId) { recording = fresh }
    }

    /// Reads the stored transcript again: a transcription started from an earlier page may
    /// have finished while this one was open.
    public func reloadTranscript() {
        transcript = try? library.transcript(recordingId: recordingId)
    }

    /// Fixes the text of one transcript line; a short word swap goes into 纠错词库 (#75) so later
    /// transcripts get it right. Empty text changes nothing.
    public func editLine(_ index: Int, to text: String) {
        do {
            let before = try library.corrections().count
            guard let updated = try library.editTranscriptLine(recordingId: recordingId, index: index, to: text) else {
                return
            }
            transcript = updated
            let learned = try library.corrections().count > before
            toast = Toast(learned ? "已修改，以后转写会自动改正这个词" : "已修改")
        } catch {
            toast = Toast("保存失败，请重试")
        }
    }

    // MARK: - 单词分级 (features.md X20)

    /// The graded words of this recording, once made.
    public private(set) var wordList: WordList?
    public private(set) var isListingWords = false

    /// The transcript is mostly in a foreign language, so 「生词」 is offered.
    public var transcriptIsForeign: Bool {
        transcript.map { WordGrader.isForeign($0.segments.map(\.text)) } ?? false
    }

    /// 「列出生词」 needs a foreign-language transcript and a configured service.
    public var canListWords: Bool { transcriptIsForeign && assistant?.current() != nil && !isListingWords }

    /// Sends the transcript lines with Latin letters (text only) to the user's service and keeps
    /// the words it picks, replacing an earlier list.
    public func listWords() {
        guard let transcript, let config = assistant?.current(), !isListingWords else { return }
        isListingWords = true
        let lines = transcript.segments.map(\.text)
        Task {
            defer { isListingWords = false }
            do {
                let words = try await grader.grade(lines, config: config)
                let list = WordList(recordingId: recordingId, words: words, model: config.model)
                try library.saveWordList(list)
                wordList = list
                toast = Toast(words.isEmpty ? "没有找到值得学的词" : "找到 \(words.count) 个生词")
            } catch let error as AssistantError {
                toast = Toast(AssistantSettingsModel.text(for: error))
            } catch is CancellationError {
                // Left the page.
            } catch {
                toast = Toast("列出生词失败，请重试")
            }
        }
    }

    /// The words at `minimum` or above, grouped by level from the hardest down.
    public func words(atLeast minimum: WordLevel) -> [(level: WordLevel, words: [StudyWord])] {
        let words = (wordList?.words ?? []).filter { $0.level >= minimum }
        return WordLevel.allCases.reversed().compactMap { level -> (level: WordLevel, words: [StudyWord])? in
            let group = words.filter { $0.level == level }
            if group.isEmpty { return nil }
            return (level: level, words: group)
        }
    }

    /// Plays the line a word was heard in.
    public func play(word: StudyWord) {
        guard let segments = transcript?.segments, segments.indices.contains(word.segmentIndex) else { return }
        play(from: segments[word.segmentIndex])
    }

    // MARK: - 逐句润色 (#75)

    public private(set) var isPolishing = false

    /// "润色文字稿" needs a transcript with text and a configured service.
    public var canPolish: Bool {
        transcript.map { !$0.segments.isEmpty } == true && assistant?.current() != nil && !isPolishing
    }

    /// Sends the transcript's lines (text only) to the user's service and puts the polished text
    /// on each line, keeping times; the lines as transcribed are kept for `restoreOriginal`.
    public func polish() {
        guard let transcript, let config = assistant?.current(), !isPolishing else { return }
        isPolishing = true
        let lines = transcript.segments.map(\.text)
        Task {
            defer { isPolishing = false }
            do {
                let result = try await polisher.polish(lines, config: config)
                guard let stored = try library.savePolishedTranscript(recordingId: recordingId, texts: result.texts),
                      stored.segments.count == lines.count else {
                    toast = Toast("文字稿已经变了，请再润色一次")
                    reloadTranscript()
                    return
                }
                self.transcript = stored
                toast = Toast(result.unchangedLines > 0
                              ? "已润色，有 \(result.unchangedLines) 句没能润色，保留了原文"
                              : "已润色，可以随时恢复原文")
            } catch let error as AssistantError {
                toast = Toast(AssistantSettingsModel.text(for: error))
            } catch is CancellationError {
                // Left the page.
            } catch {
                toast = Toast("润色失败，请重试")
            }
        }
    }

    /// Goes back to the text as transcribed.
    public func restoreOriginal() {
        do {
            if let restored = try library.restoreOriginalTranscript(recordingId: recordingId) {
                transcript = restored
                toast = Toast("已恢复原文")
            }
        } catch {
            toast = Toast("保存失败，请重试")
        }
    }

    /// "00:18:06" for a transcript line.
    public func timeText(_ segment: TranscriptSegment) -> String {
        RecordingText.clock(seconds: segment.startMs / 1000)
    }

    /// The transcript line being played (#89): the last one that starts at or before the
    /// playback position. Nil while this recording is not in the player.
    public var currentSegmentIndex: Int? {
        guard isLoaded, let segments = transcript?.segments else { return nil }
        return Self.segmentIndex(segments.map(\.startMs), atMs: Int(currentTime * 1000))
    }

    /// Index of the last start at or before `atMs` in ascending `starts`; nil before the first.
    public nonisolated static func segmentIndex(_ starts: [Int], atMs: Int) -> Int? {
        var low = 0, high = starts.count
        while low < high {
            let mid = (low + high) / 2
            if starts[mid] <= atMs { low = mid + 1 } else { high = mid }
        }
        return low == 0 ? nil : low - 1
    }

    /// Plays from a transcript line; a line on loop stops looping.
    public func play(from segment: TranscriptSegment) {
        stopLoop()
        play(fromMs: segment.startMs)
    }

    /// Plays from a mark; loads the recording first when it is not the one in the player.
    public func play(from mark: PlaybackMark) {
        play(fromMs: mark.offsetMs)
    }

    private func play(fromMs offsetMs: Int) {
        guard hasAudio else { return }  // text only (features.md E2): nothing to play
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

    // MARK: - 单句循环 (features.md X20)

    /// The transcript line being played over and over; nil when no line is on loop.
    public private(set) var loopingIndex: Int?
    @ObservationIgnored private var loopTask: Task<Void, Never>?

    /// Plays line `index` over and over until `stopLoop`, another line is played, the user seeks
    /// or skips, or the player moves to another recording. Pausing keeps the loop; playing on
    /// resumes it. Calling it for the line already on loop stops it.
    public func toggleLoop(lineAt index: Int) {
        if loopingIndex == index {
            stopLoop()
            return
        }
        guard let recording, let segments = transcript?.segments,
              let range = Self.loopRange(segments.map(\.startMs), index: index,
                                         durationMs: Int(duration * 1000)) else { return }
        stopLoop()
        loopingIndex = index
        loopTask = Task {
            do {
                if !isLoaded || !isPlaying { try await player.play(recording) }
            } catch is CancellationError {
                return
            } catch PlayerError.audioMissing {
                audioMissing = true
                loopingIndex = nil
                return
            } catch {
                toast = Toast("无法播放这条录音")
                loopingIndex = nil
                return
            }
            player.seek(to: Double(range.lowerBound) / 1000)
            while !Task.isCancelled, loopingIndex == index {
                guard isLoaded else { break }  // stopped, or another recording is playing
                let finished = player.state == .idle
                if player.state != .paused {
                    switch Self.loopStep(positionMs: Int(player.currentTime * 1000), range: range, finished: finished) {
                    case .wait:
                        break
                    case .restart:
                        player.seek(to: Double(range.lowerBound) / 1000)
                        if finished { try? await player.play(recording) }
                    case .stop:
                        loopingIndex = nil
                    }
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
            if loopingIndex == index { loopingIndex = nil }
        }
    }

    public func stopLoop() {
        loopTask?.cancel()
        loopTask = nil
        loopingIndex = nil
    }

    /// Line `index` in ms: from its start to the next line's start, or to the end of the
    /// recording for the last line. Nil out of range or for a line with no length.
    public nonisolated static func loopRange(_ starts: [Int], index: Int, durationMs: Int) -> Range<Int>? {
        guard starts.indices.contains(index) else { return nil }
        let end = index + 1 < starts.count ? starts[index + 1] : durationMs
        return starts[index] < end ? starts[index]..<end : nil
    }

    public enum LoopStep: Equatable, Sendable {
        case wait, restart, stop
    }

    /// What the loop does at `positionMs`: start the line again once playback reaches its end
    /// (or the recording finished); stop when the position is well outside the line, which only
    /// happens when something else moved it.
    public nonisolated static func loopStep(positionMs: Int, range: Range<Int>, finished: Bool) -> LoopStep {
        let slack = 1500
        if finished { return .restart }
        if positionMs >= range.upperBound { return positionMs < range.upperBound + slack ? .restart : .stop }
        if positionMs < range.lowerBound - slack { return .stop }
        return .wait
    }

    /// "00:18:06" for a mark row.
    public func markText(_ mark: PlaybackMark) -> String {
        RecordingText.clock(seconds: mark.offsetMs / 1000)
    }

    /// Leaving the page while a decode runs cancels it; playback that already started goes on.
    public func leave() {
        stopLoop()
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

    public var durationText: String {
        guard let recording else { return "" }
        return recording.hasAudio ? RecordingText.longDuration(ms: recording.durationMs) : "文字"
    }

    /// The card's name for a card recording; "手机录音" or "导入" otherwise (features.md D1c).
    public var sourceText: String? {
        guard let recording else { return nil }
        if recording.source == .card { return recording.deviceId.flatMap { deviceNames[$0] } ?? "录音卡" }
        return RecordingText.sourceName(recording.source)
    }

    public var sizeText: String {
        guard let recording, recording.hasAudio else { return "" }
        let url = library.store.url(forAudioPath: recording.audioPath)
        let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    // MARK: - Export and delete

    /// A temporary `<title>.ogg` for the share sheet (features.md E1a), named as the page shows
    /// the recording ("11月7日 14.02.ogg", #85); nil with a toast on failure.
    public func exportFile() -> URL? {
        guard let recording, recording.hasAudio else { return nil }
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
        guard let recording, recording.hasAudio, !isExporting else { return nil }
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

    /// "OGG" for a card recording, "M4A" for a phone one: what 「原始文件」 shares as it is
    /// stored (an imported OGG Opus stays OGG, anything else became M4A).
    public var originalFormat: String {
        let ext = recording.map { URL(fileURLWithPath: $0.audioPath).pathExtension.uppercased() } ?? ""
        return ext.isEmpty ? "OGG" : ext
    }

    /// A temporary `<title>.wav` for the share sheet (features.md E1c); nil with a toast on failure.
    public func exportWAV() async -> URL? {
        guard let recording, recording.hasAudio, !isExporting else { return nil }
        isExporting = true
        defer { isExporting = false }
        do {
            return try await RecordingExporter.exportWAV(for: recording, library: library, title: title)
        } catch PlayerError.audioMissing {
            audioMissing = true
        } catch {
            log.error("cannot export wav: \(String(describing: error), privacy: .public)")
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
        return writeExport(Data(text.utf8), fileExtension: "md")
    }

    #if canImport(CoreText)
    /// The same content as the Markdown export, as a PDF (features.md J1).
    public func exportPDF() -> URL? {
        guard let recording else { return nil }
        let data = PDFExport.pdf(title: title, recording: recording, sceneName: sceneName,
                                 summary: summary, transcript: transcript)
        guard !data.isEmpty else {
            toast = Toast("导出失败，请重试")
            return nil
        }
        return writeExport(data, fileExtension: "pdf")
    }
    #endif

    /// The same content as the PDF, as a Word document to keep editing (features.md J1).
    public func exportDOCX() -> URL? {
        guard let recording else { return nil }
        let data = DOCXExport.docx(title: title, recording: recording, sceneName: sceneName,
                                   summary: summary, transcript: transcript)
        return writeExport(data, fileExtension: "docx")
    }

    /// The summary has an outline to export as a mind map (features.md J1).
    public var canExportMindMap: Bool { !(summary?.outline.isEmpty ?? true) }

    /// The outline as `<title>.opml` for XMind, 幕布 and other outliners (features.md J1 思维导图).
    public func exportMindMap() -> URL? {
        guard let summary, !summary.outline.isEmpty else { return nil }
        let heading = summary.title.isEmpty ? title : summary.title
        return writeExport(Data(MindMapExport.opml(title: heading, outline: summary.outline).utf8),
                           fileExtension: "opml")
    }

    /// `<title>.<ext>` in its own directory under the export folder `RecordingExporter.cleanUp`
    /// empties; nil with a toast on failure.
    private func writeExport(_ data: Data, fileExtension: String) -> URL? {
        do {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("export", isDirectory: true)
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent(RecordingExporter.fileName(for: title, fileExtension: fileExtension))
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            toast = Toast("导出失败，请重试")
            return nil
        }
    }

    /// The title to start a rename from: the user's own, or empty for the default one.
    public var editableTitle: String {
        guard let recording, recording.hasCustomTitle || recording.hasAITitle else { return "" }
        return recording.title
    }

    // MARK: - Folder (features.md D1c)

    /// Folders to offer in "移到文件夹", by name.
    public var folders: [Folder] { (try? library.folders()) ?? [] }

    /// The folder this recording is in, if any.
    public var folderName: String? {
        guard let id = recording?.folderId else { return nil }
        return folders.first { $0.id == id }?.name
    }

    /// Puts the recording in a folder, or takes it out with nil.
    public func move(toFolder folderId: UUID?) {
        do {
            try library.moveRecording(id: recordingId, toFolder: folderId)
            recording = try library.recording(id: recordingId)
            toast = Toast(folderId == nil ? "已移出文件夹" : "已移到「\(folderName ?? "")」")
        } catch {
            toast = Toast("移动失败，请重试")
        }
    }

    /// "新建文件夹…" in the menu: creates it and moves the recording in.
    public func moveToNewFolder(named name: String) {
        do {
            guard let folder = try library.createFolder(named: name) else { return }
            move(toFolder: folder.id)
        } catch {
            toast = Toast("新建文件夹失败，请重试")
        }
    }

    public var isStarred: Bool { recording?.isStarred ?? false }

    /// "标星" / "取消星标" in the page's menu (features.md X21).
    public func toggleStar() {
        do {
            if let updated = try library.setStarred(id: recordingId, !isStarred) {
                recording = updated
                toast = Toast(updated.isStarred ? "已标星" : "已取消星标")
            }
        } catch {
            toast = Toast("保存失败，请重试")
        }
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
    public let id: UUID
    public let title: String
    /// What has arrived so far, without the model's `<think>` part.
    public var text: String
    /// More is still coming.
    public var isStreaming: Bool
    /// The reply stopped part way (lost connection, service error); `text` is what arrived.
    public var isCutOff = false

    public init(id: UUID = UUID(), title: String, text: String, isStreaming: Bool = false) {
        self.id = id
        self.title = title
        self.text = text
        self.isStreaming = isStreaming
    }
}
