import AppModel
import Assistant
import Foundation
import Testing

// X11: the service form saves address and model to Preferences and the key to the key store.
@MainActor
struct AssistantSettingsModelTests {
    private func preferences() -> Preferences {
        Preferences(defaults: UserDefaults(suiteName: "assistant-\(UUID().uuidString)")!)
    }

    /// G1 职业设定: saved on one line and capped, part of the config summaries use, and kept
    /// when the service is cleared.
    @Test func professionIsSavedWithTheService() throws {
        let prefs = preferences()
        let keys = InMemoryKeyStore()
        let model = AssistantSettingsModel(preferences: prefs, keyStore: keys)
        model.baseURL = "https://example.invalid/v1"
        model.model = "m"
        model.profession = "  产品\n经理  "
        #expect(model.config.profession == "产品 经理")
        model.save()
        #expect(prefs.assistantProfession == "产品 经理")
        let again = AssistantSettingsModel(preferences: prefs, keyStore: keys)
        #expect(again.profession == "产品 经理" && again.config.profession == "产品 经理")
        #expect(AssistantSettingsModel.cleaned(String(repeating: "长", count: 60)).count == ServiceConfig.professionLimit)
        again.clear()
        #expect(prefs.assistantProfession == "产品 经理")
    }

    @Test func savesLoadsAndClears() throws {
        let prefs = preferences()
        let keys = InMemoryKeyStore()
        let model = AssistantSettingsModel(preferences: prefs, keyStore: keys)
        #expect(!model.isConfigured && model.selectedPreset == nil)

        let preset = try #require(model.presets.first { !$0.defaultModel.isEmpty })
        model.choose(preset)
        #expect(model.selectedPreset == preset && model.model == preset.defaultModel)
        model.apiKey = "  sk-test  "
        model.save()
        #expect(prefs.assistantBaseURL == preset.baseURL)
        #expect(try keys.read() == "sk-test")
        #expect(model.toast?.text == "已保存")

        let again = AssistantSettingsModel(preferences: prefs, keyStore: keys)
        #expect(again.config == ServiceConfig(baseURL: preset.baseURL, model: preset.defaultModel, apiKey: "sk-test"))

        #expect(again.transcriptionModel.isEmpty)  // audio upload stays off until the user fills it

        // A provider that also transcribes suggests its model; saving keeps it.
        let both = try #require(ServicePreset.chat.first { chat in
            ServicePreset.transcription.contains { $0.baseURL == chat.baseURL } })
        again.choose(both)
        #expect(again.transcriptionModel.isEmpty)
        let suggested = try #require(again.suggestedTranscriptionModel)
        again.transcriptionModel = suggested
        again.save()
        #expect(prefs.assistantTranscriptionModel == suggested)

        again.clear()
        #expect(prefs.assistantTranscriptionModel.isEmpty)
        #expect(prefs.assistantBaseURL.isEmpty && prefs.assistantModel.isEmpty)
        #expect(try keys.read() == nil)
    }

    @Test func errorsReadAsAdvice() {
        #expect(AssistantSettingsModel.text(for: .http(401, "")) == "密钥无效或没有权限")
        #expect(AssistantSettingsModel.text(for: .http(500, "")) == "服务返回错误 500")
        #expect(AssistantSettingsModel.text(for: .unreachable("x")) == "连不上这个地址，请检查网络和地址")
    }
}
