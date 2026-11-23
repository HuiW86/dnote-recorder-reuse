import Assistant
import Foundation
import Library
import Transcription

// Which AI service and which transcriber the app uses, read fresh on every use so a change in
// settings applies at once (#85). Shared by the iPhone and the Mac app (ADR-011).

extension AssistantConfigSource {
    /// The service saved in settings (features.md X11): address, model and job from
    /// UserDefaults, the key from the Keychain. Nil until an address and a model are saved.
    public static func saved(keyStore: KeychainKeyStore = KeychainKeyStore()) -> AssistantConfigSource {
        AssistantConfigSource {
            let defaults = UserDefaults.standard
            let config = ServiceConfig(baseURL: defaults.string(forKey: Preferences.assistantBaseURLKey) ?? "",
                                       model: defaults.string(forKey: Preferences.assistantModelKey) ?? "",
                                       apiKey: (try? keyStore.read()) ?? "",
                                       profession: defaults.string(forKey: Preferences.assistantProfessionKey) ?? "")
            return config.isComplete ? config : nil
        }
    }
}

public enum TranscriberChoice {
    /// The same service for transcription, when the user gave it a transcription model; nil
    /// otherwise, and then no audio is ever uploaded (ADR-009).
    @MainActor
    public static func cloudConfig(preferences: Preferences, assistant: AssistantConfigSource) -> ServiceConfig? {
        guard let chat = assistant.current() else { return nil }
        let model = preferences.assistantTranscriptionModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else { return nil }
        return ServiceConfig(baseURL: chat.baseURL, model: model, apiKey: chat.apiKey)
    }

    /// On this device when 本机转写 is on (#67 keeps it behind a switch); otherwise the user's
    /// own service if they gave it a transcription model (the audio is then uploaded, and the
    /// page says so); nil when neither.
    @MainActor
    public static func current(preferences: Preferences, library: RecordingLibrary,
                               assistant: AssistantConfigSource) -> (any SpeechTranscribing)? {
        if preferences.onDeviceTranscriptEnabled { return OnDeviceTranscriber(library: library) }
        if let cloud = cloudConfig(preferences: preferences, assistant: assistant) {
            return CloudTranscriber(library: library, config: cloud)
        }
        return nil
    }
}
