import Foundation
import Library

public enum TranscriptionError: Error, Equatable, Sendable {
    /// The user has not allowed speech recognition.
    case permissionDenied
    /// This phone cannot recognize this language without the network.
    case unsupportedLanguage
    /// The recognizer heard no speech.
    case noSpeech
    case audioMissing
    case failed(String)
}

/// Turns a stored recording into text. Implementations must not use the network
/// (CLAUDE.md rule 3; features.md X9).
public protocol SpeechTranscribing: Sendable {
    /// Stored with the transcript: "on-device", or "cloud" for the user's own service.
    var engineName: String { get }
    /// True when the audio leaves the phone (the user's own service, ADR-009).
    var usesNetwork: Bool { get }
    func transcribe(_ recording: Recording, language: String) async throws -> [TranscriptSegment]
}

extension SpeechTranscribing {
    public var engineName: String { "on-device" }
    public var usesNetwork: Bool { false }
}
