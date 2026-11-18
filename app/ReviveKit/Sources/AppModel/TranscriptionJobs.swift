import Foundation
import Observation

/// Recordings being transcribed right now, shared by every recording page. A transcription
/// outlives the page that started it, so a page opened again for the same recording must see
/// that one is running instead of starting a second (#85).
@MainActor
@Observable
public final class TranscriptionJobs {
    public static let shared = TranscriptionJobs()

    public private(set) var running: Set<UUID> = []

    public init() {}

    /// False when this recording is already being transcribed.
    func begin(_ id: UUID) -> Bool {
        running.insert(id).inserted
    }

    func end(_ id: UUID) {
        running.remove(id)
    }
}
