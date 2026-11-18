import Foundation
import Library
import Player
@preconcurrency import Speech

/// The system speech recognizer, forced to stay on the device: the audio never leaves the
/// phone (features.md X9). Does not tell speakers apart. How well it does on long Chinese
/// recordings is not measured yet (#67), so the app keeps this behind a switch.
public final class OnDeviceTranscriber: SpeechTranscribing {
    public static let engineName = "on-device"

    private let library: RecordingLibrary

    public init(library: RecordingLibrary) {
        self.library = library
    }

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
            // A file that is there but does not decode is not "missing" (#85).
            throw TranscriptionError.unreadableAudio
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
