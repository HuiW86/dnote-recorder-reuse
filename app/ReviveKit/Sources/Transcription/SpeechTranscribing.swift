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
    /// The audio file is there but could not be decoded for the recognizer.
    case unreadableAudio
    case failed(String)
}

/// Turns a stored recording into text. Implementations must not use the network
/// (CLAUDE.md rule 3; features.md X9).
public protocol SpeechTranscribing: Sendable {
    func transcribe(_ recording: Recording, language: String) async throws -> [TranscriptSegment]
}
