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
    public private(set) var isTranscribing = false
    /// Set after a delete; the page closes.
    public private(set) var isDeleted = false
    public var toast: Toast?

    @ObservationIgnored private let library: RecordingLibrary
    @ObservationIgnored private let deviceNames: [UUID: String]
    @ObservationIgnored private var playTask: Task<Void, Never>?
    /// Nil when on-device transcription is switched off.
    @ObservationIgnored private let transcriber: (any SpeechTranscribing)?
    @ObservationIgnored private let log = Logger(subsystem: "revive", category: "Detail")

    public init(recordingId: UUID, library: RecordingLibrary, player: RecordingPlayer,
                transcriber: (any SpeechTranscribing)? = nil) {
        self.recordingId = recordingId
        self.library = library
        self.player = player
        self.transcriber = transcriber
        transcript = try? library.transcript(recordingId: recordingId)
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

    // MARK: - Transcript (features.md X9)

    /// "转成文字" is offered when transcription is switched on and nothing is running.
    public var canTranscribe: Bool { transcriber != nil && recording != nil && !audioMissing }

    /// Recognizes the recording on this phone and stores the text. Replaces an earlier transcript.
    public func transcribe(language: String = "zh-CN") {
        guard let transcriber, let recording, !isTranscribing else { return }
        isTranscribing = true
        Task {
            defer { isTranscribing = false }
            do {
                let segments = try await transcriber.transcribe(recording, language: language)
                let result = Transcript(recordingId: recording.id, engine: OnDeviceTranscriber.engineName,
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
