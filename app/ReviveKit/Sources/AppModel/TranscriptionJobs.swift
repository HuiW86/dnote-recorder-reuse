import Foundation
import Library
import Observation
import Transcription

/// On-device transcriptions (features.md X9), kept outside the detail page: leaving the page and
/// opening it again shows the run still going instead of offering a second one whose result
/// would overwrite the first (#85). One per app, like the player.
@MainActor
@Observable
public final class TranscriptionJobs {
    /// Recordings being transcribed now.
    public private(set) var running: Set<UUID> = []
    /// Transcripts finished since launch, by recording; already saved to the library.
    public private(set) var finished: [UUID: Transcript] = [:]
    /// Failures no page has shown yet, by recording.
    public private(set) var failures: [UUID: TranscriptionError] = [:]

    @ObservationIgnored private let library: RecordingLibrary

    public init(library: RecordingLibrary) {
        self.library = library
    }

    public func isRunning(_ recordingId: UUID) -> Bool { running.contains(recordingId) }

    /// Starts recognizing `recording` and stores the text when done, replacing an earlier
    /// transcript. Returns false, and starts nothing, while one runs for the same recording.
    @discardableResult
    public func start(_ recording: Recording, with transcriber: any SpeechTranscribing,
                      language: String) -> Bool {
        let id = recording.id
        guard !running.contains(id) else { return false }
        running.insert(id)
        failures[id] = nil
        Task {
            do {
                let segments = try await transcriber.transcribe(recording, language: language)
                let result = Transcript(recordingId: id, engine: OnDeviceTranscriber.engineName,
                                        language: language, segments: segments, createdAt: Date())
                try library.saveTranscript(result)
                finished[id] = result
            } catch let error as TranscriptionError {
                failures[id] = error
            } catch {
                failures[id] = .failed(String(describing: error))
            }
            // Last, so a page that sees the run end also sees its result.
            running.remove(id)
        }
        return true
    }

    /// The failure of the last run for `recordingId`, once: the page that shows it clears it.
    public func takeFailure(for recordingId: UUID) -> TranscriptionError? {
        failures.removeValue(forKey: recordingId)
    }
}
