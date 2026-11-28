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
            throw TranscriptionError.failed("decode: \(error)")
        }

        let request = SFSpeechURLRecognitionRequest(url: audio)
        request.requiresOnDeviceRecognition = true  // never the network
        request.shouldReportPartialResults = false
        request.addsPunctuation = true

        let pieces: [SpokenPiece] = try await withCheckedThrowingContinuation { continuation in
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
                    continuation.resume(throwing: TranscriptionError.failed(error.localizedDescription))
                }
            }
        }
        let segments = TranscriptGrouper.group(pieces)
        guard !segments.isEmpty else { throw TranscriptionError.noSpeech }
        return segments
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
