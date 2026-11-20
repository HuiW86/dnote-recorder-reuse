// A service the user configures (features.md X11, ADR-009): any OpenAI-compatible endpoint.
// We ship no provider key of our own; the user's key lives in the Keychain (KeyStore.swift).

import Foundation

/// Where to send requests. `apiKey` may be empty for services that need none.
public struct ServiceConfig: Equatable, Sendable {
    /// Up to the version path, such as "https://api.deepseek.com/v1"; "/chat/completions" is appended.
    public var baseURL: String
    public var model: String
    public var apiKey: String
    /// The user's job, such as "产品经理" (features.md G1 职业设定); summaries lean towards what it
    /// cares about. Empty for none. Sent to the service inside the prompt.
    public var profession: String

    public init(baseURL: String, model: String, apiKey: String, profession: String = "") {
        self.baseURL = baseURL
        self.model = model
        self.apiKey = apiKey
        self.profession = profession
    }

    /// Longest profession kept, so the setting cannot swamp the prompt.
    public static let professionLimit = 40

    /// Enough to send a request: an address and a model. The key is optional.
    public var isComplete: Bool {
        !baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

extension ServiceConfig: CustomStringConvertible, CustomDebugStringConvertible {
    /// Never prints the key, so a config that ends up in a log does not leak it.
    public var description: String {
        "ServiceConfig(baseURL: \(baseURL), model: \(model), apiKey: \(apiKey.isEmpty ? "none" : "<redacted>"))"
    }

    public var debugDescription: String { description }
}

extension ServiceConfig {
    /// Providers the settings page offers for summaries (`ServicePreset.chat`).
    public static var presets: [ServicePreset] { ServicePreset.chat }

    /// The config a preset gives before the user has entered a key.
    public init(preset: ServicePreset, apiKey: String = "") {
        self.init(baseURL: preset.baseURL, model: preset.defaultModel, apiKey: apiKey)
    }
}

/// A provider the settings page can fill in for the user.
public struct ServicePreset: Equatable, Sendable, Identifiable {
    public var name: String
    public var baseURL: String
    /// Model filled in when the preset is picked; empty means the user picks one.
    public var defaultModel: String
    /// Page where the user gets a key, if known.
    public var keyPage: String?

    public var id: String { baseURL }

    public init(name: String, baseURL: String, defaultModel: String, keyPage: String? = nil) {
        self.name = name
        self.baseURL = baseURL
        self.defaultModel = defaultModel
        self.keyPage = keyPage
    }
}

extension ServicePreset {
    /// Providers with an OpenAI-compatible `/chat/completions`, for summaries.
    /// Taken from andyhuo520/beanpod (commit 0d00fab, Shared/Settings.swift `presets`), minus the
    /// two on-device servers at 127.0.0.1, which on an iPhone would point at the phone itself.
    public static let chat: [ServicePreset] = [
        ServicePreset(name: "小米 MiMo", baseURL: "https://api.xiaomimimo.com/v1", defaultModel: "mimo-v2.6-pro",
                      keyPage: "https://platform.xiaomimimo.com"),
        ServicePreset(name: "DeepSeek", baseURL: "https://api.deepseek.com/v1", defaultModel: "deepseek-chat",
                      keyPage: "https://platform.deepseek.com/api_keys"),
        ServicePreset(name: "通义千问", baseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1",
                      defaultModel: "qwen-plus", keyPage: "https://bailian.console.aliyun.com"),
        ServicePreset(name: "Kimi", baseURL: "https://api.moonshot.cn/v1", defaultModel: "",
                      keyPage: "https://platform.moonshot.cn/console/api-keys"),
        ServicePreset(name: "豆包", baseURL: "https://ark.cn-beijing.volces.com/api/v3", defaultModel: "",
                      keyPage: "https://console.volcengine.com/ark"),
        ServicePreset(name: "智谱 GLM", baseURL: "https://open.bigmodel.cn/api/paas/v4", defaultModel: "",
                      keyPage: "https://open.bigmodel.cn"),
        ServicePreset(name: "MiniMax", baseURL: "https://api.minimaxi.com/v1", defaultModel: "",
                      keyPage: "https://platform.minimaxi.com"),
        ServicePreset(name: "硅基流动", baseURL: "https://api.siliconflow.cn/v1", defaultModel: "",
                      keyPage: "https://cloud.siliconflow.cn/account/ak"),
        ServicePreset(name: "OpenRouter", baseURL: "https://openrouter.ai/api/v1", defaultModel: "",
                      keyPage: "https://openrouter.ai/keys"),
        ServicePreset(name: "Gemini", baseURL: "https://generativelanguage.googleapis.com/v1beta/openai",
                      defaultModel: "", keyPage: "https://aistudio.google.com/apikey"),
        ServicePreset(name: "Claude", baseURL: "https://api.anthropic.com/v1", defaultModel: "",
                      keyPage: "https://console.anthropic.com/settings/keys"),
        ServicePreset(name: "OpenAI", baseURL: "https://api.openai.com/v1", defaultModel: "",
                      keyPage: "https://platform.openai.com/api-keys"),
    ]

    /// Providers with an OpenAI-compatible `/audio/transcriptions` (`CloudTranscriber`), with the
    /// model to use. Taken from andyhuo520/beanpod (commit 0d00fab, Shared/CloudASR.swift).
    public static let transcription: [ServicePreset] = [
        ServicePreset(name: "小米 MiMo", baseURL: "https://api.xiaomimimo.com/v1", defaultModel: "mimo-v2.5-asr"),
        ServicePreset(name: "硅基流动", baseURL: "https://api.siliconflow.cn/v1",
                      defaultModel: "FunAudioLLM/SenseVoiceSmall"),
        ServicePreset(name: "OpenAI", baseURL: "https://api.openai.com/v1", defaultModel: "whisper-1"),
        ServicePreset(name: "Groq", baseURL: "https://api.groq.com/openai/v1", defaultModel: "whisper-large-v3-turbo"),
    ]
}
