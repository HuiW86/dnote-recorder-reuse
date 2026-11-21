import AppModel
import Assistant
import Foundation
import Library
import Testing

// Which transcriber the iPhone and the Mac use (ADR-009, ADR-011): 本机转写 first, then the
// user's service with a transcription model, else none (no audio is ever uploaded).
@MainActor
struct TranscriberChoiceTests {
    @Test func onDeviceFirstThenServiceWithATranscriptionModel() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("choice-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let library = RecordingLibrary(database: try AppDatabase.inMemory(), store: try AudioStore(root: root))
        let preferences = Preferences(defaults: UserDefaults(suiteName: "choice-\(UUID().uuidString)")!)
        let chat = ServiceConfig(baseURL: "https://example.invalid/v1", model: "chat-model", apiKey: "k")
        let none = AssistantConfigSource { nil }
        let service = AssistantConfigSource { chat }

        #expect(TranscriberChoice.current(preferences: preferences, library: library, assistant: none) == nil)
        // A service without a transcription model uploads nothing.
        #expect(TranscriberChoice.current(preferences: preferences, library: library, assistant: service) == nil)

        preferences.assistantTranscriptionModel = "  whisper-1 "
        let cloud = try #require(TranscriberChoice.cloudConfig(preferences: preferences, assistant: service))
        #expect(cloud.model == "whisper-1" && cloud.baseURL == chat.baseURL && cloud.apiKey == chat.apiKey)
        let viaService = try #require(TranscriberChoice.current(preferences: preferences, library: library, assistant: service))
        #expect(viaService.usesNetwork)

        preferences.onDeviceTranscriptEnabled = true
        let onDevice = try #require(TranscriberChoice.current(preferences: preferences, library: library, assistant: service))
        #expect(!onDevice.usesNetwork && onDevice.engineName == "on-device")
    }
}
