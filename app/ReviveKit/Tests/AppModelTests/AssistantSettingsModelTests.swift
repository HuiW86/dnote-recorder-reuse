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

        again.clear()
        #expect(prefs.assistantBaseURL.isEmpty && prefs.assistantModel.isEmpty)
        #expect(try keys.read() == nil)
    }

    @Test func errorsReadAsAdvice() {
        #expect(AssistantSettingsModel.text(for: .http(401, "")) == "密钥无效或没有权限")
        #expect(AssistantSettingsModel.text(for: .http(500, "")) == "服务返回错误 500")
        #expect(AssistantSettingsModel.text(for: .unreachable("x")) == "连不上这个地址，请检查网络和地址")
    }
}
