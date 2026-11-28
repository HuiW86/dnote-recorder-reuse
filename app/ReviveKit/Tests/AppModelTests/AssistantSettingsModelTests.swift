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

    /// Leaving the page keeps a complete form or a changed job, never half a service; 清除 is
    /// offered only for a stored service.
    @Test func leavingKeepsWhatCanBeKept() throws {
        let prefs = preferences()
        let keys = InMemoryKeyStore()
        let model = AssistantSettingsModel(preferences: prefs, keyStore: keys)
        #expect(!model.hasUnsavedChanges && !model.canSave && !model.hasSavedService)

        // Only the job: works without a service, so it can be saved.
        model.profession = "律师"
        #expect(model.canSave)
        model.saveOnLeave()
        #expect(prefs.assistantProfession == "律师" && !model.hasUnsavedChanges)

        // Half a service is not stored.
        model.baseURL = "https://example.invalid/v1"
        #expect(model.hasUnsavedChanges && !model.canSave)
        model.saveOnLeave()
        #expect(prefs.assistantBaseURL.isEmpty)

        // A complete one is.
        model.model = "m"
        model.apiKey = "sk"
        model.saveOnLeave()
        #expect(prefs.assistantBaseURL == "https://example.invalid/v1")
        #expect(try keys.read() == "sk")
        #expect(model.hasSavedService && !model.hasUnsavedChanges)
        model.clear()
        #expect(!model.hasSavedService)
    }

    /// Codex review of #154: leaving never hands the old key to a new address, and a page left
    /// open in another tab never brings back a service cleared elsewhere.
    @Test func leavingNeverMovesAKeyOrUndoesAnotherPage() throws {
        let prefs = preferences()
        let keys = InMemoryKeyStore()
        let first = AssistantSettingsModel(preferences: prefs, keyStore: keys)
        first.baseURL = "https://a.invalid/v1"
        first.model = "m"
        first.apiKey = "sk-a"
        first.save()

        // Another address, with A's key or a new one: leaving keeps A; only 保存 switches.
        let moved = AssistantSettingsModel(preferences: prefs, keyStore: keys)
        moved.baseURL = "https://b.invalid/v1"
        #expect(moved.canSave && moved.switchesService)
        moved.saveOnLeave()
        #expect(prefs.assistantBaseURL == "https://a.invalid/v1")
        moved.apiKey = "sk-b"
        moved.saveOnLeave()
        #expect(prefs.assistantBaseURL == "https://a.invalid/v1")
        #expect(try keys.read() == "sk-a")
        moved.save()
        #expect(prefs.assistantBaseURL == "https://b.invalid/v1")
        #expect(try keys.read() == "sk-b")
        // Same service, another model: kept on leaving.
        moved.model = "m3"
        moved.saveOnLeave()
        #expect(prefs.assistantModel == "m3")
        // Same address, another key (another account): only 保存.
        moved.apiKey = "sk-team"
        moved.saveOnLeave()
        #expect(try keys.read() == "sk-b")

        // Two pages open; one clears; the other, untouched or edited, does not write it back.
        let stale = AssistantSettingsModel(preferences: prefs, keyStore: keys)
        let edited = AssistantSettingsModel(preferences: prefs, keyStore: keys)
        AssistantSettingsModel(preferences: prefs, keyStore: keys).clear()
        stale.saveOnLeave()
        edited.model = "m2"
        edited.saveOnLeave()
        #expect(prefs.assistantBaseURL.isEmpty)
        #expect(try keys.read() == nil)

        // An empty page left open; another sets up a service; the old page saves only its job.
        let old = AssistantSettingsModel(preferences: prefs, keyStore: keys)
        let other = AssistantSettingsModel(preferences: prefs, keyStore: keys)
        other.baseURL = "https://c.invalid/v1"
        other.model = "m"
        other.apiKey = "sk-c"
        other.save()
        old.profession = "老师"
        old.save()
        #expect(prefs.assistantProfession == "老师")
        #expect(prefs.assistantBaseURL == "https://c.invalid/v1")
        #expect(try keys.read() == "sk-c")
    }

    /// 测试连接: a first setup is kept; another address or a new transcription model (audio
    /// upload) is not kept without 保存; a form edited while the test ran gets no result.
    @Test func passingTestKeepsOnlyWhatNeedsNoAsking() async throws {
        let prefs = preferences()
        let keys = InMemoryKeyStore()
        let client = ChatClient(session: OKReply.session())
        let first = AssistantSettingsModel(preferences: prefs, keyStore: keys, client: client)
        first.baseURL = "https://a.invalid/v1"
        first.model = "m"
        first.apiKey = "sk-a"
        first.test()
        await waitUntil("tested") { !first.isTesting }
        #expect(first.testResult == "连接成功，已保存")
        #expect(prefs.assistantBaseURL == "https://a.invalid/v1")

        let moved = AssistantSettingsModel(preferences: prefs, keyStore: keys, client: client)
        moved.baseURL = "https://b.invalid/v1"
        moved.apiKey = "sk-b"
        moved.test()
        await waitUntil("tested b") { !moved.isTesting }
        #expect(moved.testResult == "连接成功。点「保存」后改用这个服务")
        #expect(prefs.assistantBaseURL == "https://a.invalid/v1")
        #expect(try keys.read() == "sk-a")

        let upload = AssistantSettingsModel(preferences: prefs, keyStore: keys, client: client)
        upload.transcriptionModel = "whisper-1"
        upload.test()
        await waitUntil("tested upload") { !upload.isTesting }
        #expect(upload.testResult == "连接成功。点「保存」后生效")
        upload.saveOnLeave()
        #expect(prefs.assistantTranscriptionModel.isEmpty)

        let edited = AssistantSettingsModel(preferences: prefs, keyStore: keys, client: client)
        edited.test()
        edited.model = "m2"
        await waitUntil("tested edited") { !edited.isTesting }
        #expect(edited.testResult == nil)
    }

    /// With 录完自动整理 on, a first service would get new recordings' text at once: only 保存.
    @Test func autoProcessingWaitsForSaveOnAFirstService() throws {
        let prefs = preferences()
        prefs.autoProcessEnabled = true
        let keys = InMemoryKeyStore()
        let model = AssistantSettingsModel(preferences: prefs, keyStore: keys)
        model.baseURL = "https://b.invalid/v1"
        model.model = "m"
        model.apiKey = "sk-b"
        model.saveOnLeave()
        #expect(prefs.assistantBaseURL.isEmpty)
        #expect(try keys.read() == nil)
        model.save()
        #expect(prefs.assistantBaseURL == "https://b.invalid/v1")
    }

    @Test func errorsReadAsAdvice() {
        #expect(AssistantSettingsModel.text(for: .http(401, "")) == "密钥无效或没有权限")
        #expect(AssistantSettingsModel.text(for: .http(500, "")) == "服务返回错误 500")
        #expect(AssistantSettingsModel.text(for: .unreachable("x")) == "连不上这个地址，请检查网络和地址")
        #expect(AssistantSettingsModel.text(for: .offline) == AssistantError.offlineAdvice)
    }
}

/// Answers every request with a short chat completion; no network.
private final class OKReply: URLProtocol {
    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OKReply.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body = try? JSONSerialization.data(withJSONObject: [
            "choices": [["message": ["role": "assistant", "content": "可用"]]],
        ])
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body ?? Data())
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
