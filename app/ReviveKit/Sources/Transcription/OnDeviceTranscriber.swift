import AVFoundation
import Foundation
import Library
import Player
@preconcurrency import Speech

/// The system speech recognizer, forced to stay on the device: the audio never leaves the
/// phone (features.md X9). Does not tell speakers apart. How well it does on long Chinese
/// recordings is not measured yet (#67); since product-spec.md §7.3b it is the first way to try.
public final class OnDeviceTranscriber: SpeechTranscribing {
    public static let engineName = "on-device"

    private let library: RecordingLibrary

    public init(library: RecordingLibrary) {
        self.library = library
    }

    /// This phone can recognize `language` without the network (§7.3b: the first 转成文字 uses
    /// the phone when it can). Asks no permission; that comes with the first transcription.
    public static func isSupported(language: String = "zh-CN") -> Bool {
        SFSpeechRecognizer(locale: Locale(identifier: language))?.supportsOnDeviceRecognition ?? false
    }

    /// Speech recognition was allowed already: transcribing asks nothing (录完自动整理).
    public static var isAuthorized: Bool { SFSpeechRecognizer.authorizationStatus() == .authorized }

    public func transcribe(_ recording: Recording, language: String) async throws -> [TranscriptSegment] {
        let status = await withCheckedContinuation { (continuation: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard status == .authorized else { throw TranscriptionError.permissionDenied }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: language)),
              recognizer.isAvailable, recognizer.supportsOnDeviceRecognition else {
            throw TranscriptionError.unsupportedLanguage
        }
        let audio: URL
        do {
            audio = try await RecordingExporter.decodedPCM(for: recording, library: library)
        } catch PlayerError.audioMissing {
            throw TranscriptionError.audioMissing
        } catch {
            // The file is there but could not be decoded: not the same as a missing file (#85).
            throw Self.failure("decode", error)
        }

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("speech-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let input: AVAudioFile
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            input = try AVAudioFile(forReading: audio)
        } catch {
            throw Self.failure("prepare", error)
        }
        let rate = input.processingFormat.sampleRate
        let durationMs = Int(ceil(Double(input.length) / rate * 1000))
        var pieces: [SpokenPiece] = []
        for window in SpeechRecognitionWindow.covering(durationMs) {
            try Task.checkCancellation()
            let chunk = directory.appendingPathComponent("\(window.owned.lowerBound).caf")
            defer { try? FileManager.default.removeItem(at: chunk) }
            do {
                try Self.writeWindow(window.input, from: input, to: chunk)
            } catch {
                throw Self.failure("window", error)
            }
            let words = try await Self.recognize(chunk, with: recognizer)
            pieces.append(contentsOf: window.place(words))
        }

        let segments = TranscriptGrouper.group(pieces.sorted { $0.startMs < $1.startMs })
        guard !segments.isEmpty else { throw TranscriptionError.noSpeech }
        return segments
    }

    static func writeWindow(_ range: Range<Int>, from input: AVAudioFile, to url: URL) throws {
        let format = input.processingFormat
        let framesPerMillisecond = format.sampleRate / 1000
        let start = min(input.length, AVAudioFramePosition(Double(range.lowerBound) * framesPerMillisecond))
        let end = min(input.length, AVAudioFramePosition(Double(range.upperBound) * framesPerMillisecond))
        input.framePosition = start
        let output = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: format.commonFormat,
                                     interleaved: format.isInterleaved)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_384) else {
            throw CocoaError(.fileReadUnknown)
        }
        var remaining = end - start
        while remaining > 0 {
            try input.read(into: buffer, frameCount: AVAudioFrameCount(min(remaining, Int64(buffer.frameCapacity))))
            guard buffer.frameLength > 0 else { throw CocoaError(.fileReadCorruptFile) }
            try output.write(from: buffer)
            remaining -= AVAudioFramePosition(buffer.frameLength)
        }
    }

    private static func recognize(_ audio: URL, with recognizer: SFSpeechRecognizer) async throws -> [SpokenPiece] {
        let request = SFSpeechURLRecognitionRequest(url: audio)
        request.requiresOnDeviceRecognition = true  // never the network
        request.shouldReportPartialResults = false
        request.addsPunctuation = true

        return try await withCheckedThrowingContinuation { continuation in
            let once = Once()
            _ = recognizer.recognitionTask(with: request) { result, error in
                if let result, result.isFinal {
                    guard once.claim() else { return }
                    continuation.resume(returning: result.bestTranscription.segments.map {
                        SpokenPiece(text: $0.substring, startMs: Int($0.timestamp * 1000),
                                    durationMs: Int($0.duration * 1000))
                    })
                } else if let error {
                    guard once.claim() else { return }
                    let speechError = error as NSError
                    // Silence in this window does not invalidate speech in the other windows.
                    if speechError.domain == "kAFAssistantErrorDomain", speechError.code == 1110 {
                        continuation.resume(returning: [])
                    } else {
                        continuation.resume(throwing: Self.failure("recognize", speechError))
                    }
                }
            }
        }
    }

    private static func failure(_ stage: String, _ error: any Error) -> TranscriptionError {
        let underlying = error as NSError
        return .failed("\(stage): \(underlying.domain) (\(underlying.code))")
    }
}

/// The recognizer can call back more than once; a continuation may be resumed only once.
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
}
