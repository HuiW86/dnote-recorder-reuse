import Assistant
import Foundation
import Observation

/// "AI 服务" in settings (features.md X11, ADR-009): the user's own OpenAI-compatible service.
/// The address and model go to Preferences, the key to the Keychain.
@MainActor
@Observable
public final class AssistantSettingsModel {
    public var baseURL: String
    public var model: String
    public var apiKey: String
    public private(set) var isTesting = false
    /// Result of the last "测试连接", in words.
    public private(set) var testResult: String?
    public var toast: Toast?

    public let presets: [ServicePreset] = ServicePreset.chat

    @ObservationIgnored private let preferences: Preferences
    @ObservationIgnored private let keyStore: any ServiceKeyStoring
    @ObservationIgnored private let client: ChatClient

    public init(preferences: Preferences, keyStore: any ServiceKeyStoring, client: ChatClient = ChatClient()) {
        self.preferences = preferences
        self.keyStore = keyStore
        self.client = client
        baseURL = preferences.assistantBaseURL
        model = preferences.assistantModel
        apiKey = (try? keyStore.read()) ?? ""
    }

    /// The preset whose address is filled in, if any.
    public var selectedPreset: ServicePreset? {
        presets.first { $0.baseURL == baseURL.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    public func choose(_ preset: ServicePreset) {
        baseURL = preset.baseURL
        if !preset.defaultModel.isEmpty || model.isEmpty { model = preset.defaultModel }
        testResult = nil
    }

    public var config: ServiceConfig {
        ServiceConfig(baseURL: baseURL.trimmingCharacters(in: .whitespacesAndNewlines),
                      model: model.trimmingCharacters(in: .whitespacesAndNewlines),
                      apiKey: apiKey.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    public var isConfigured: Bool { config.isComplete }

    /// Stores address and model in Preferences and the key in the Keychain; an empty key is removed.
    public func save() {
        let current = config
        preferences.assistantBaseURL = current.baseURL
        preferences.assistantModel = current.model
        do {
            try keyStore.save(current.apiKey)
            toast = Toast("已保存")
        } catch {
            toast = Toast("密钥保存失败，请重试")
        }
    }

    /// Removes the service: the app goes back to working without AI.
    public func clear() {
        baseURL = ""
        model = ""
        apiKey = ""
        testResult = nil
        preferences.assistantBaseURL = ""
        preferences.assistantModel = ""
        try? keyStore.delete()
        toast = Toast("已清除")
    }

    /// Sends one short request with what is on the form (saved or not).
    public func test() {
        guard !isTesting else { return }
        let current = config
        guard current.isComplete else {
            testResult = "请先填写地址和模型"
            return
        }
        isTesting = true
        testResult = nil
        Task {
            defer { isTesting = false }
            do {
                _ = try await client.complete(current, system: "只回复两个字：可用", user: "测试", json: false)
                testResult = "可以连接"
            } catch let error as AssistantError {
                testResult = Self.text(for: error)
            } catch {
                testResult = "连接失败：\(error.localizedDescription)"
            }
        }
    }

    public nonisolated static func text(for error: AssistantError) -> String {
        switch error {
        case .notConfigured: "请先填写地址和模型"
        case .http(401, _), .http(403, _): "密钥无效或没有权限"
        case .http(404, _): "地址或模型不对（服务返回 404）"
        case .http(429, _): "请求太频繁或额度已用完"
        case .http(let code, _): "服务返回错误 \(code)"
        case .badReply: "服务的回复看不懂，请换一个模型试试"
        case .unreachable: "连不上这个地址，请检查网络和地址"
        }
    }
}

/// Reads the saved service for the recording page. Nil until an address and a model are saved.
public struct AssistantConfigSource: Sendable {
    private let read: @Sendable () -> ServiceConfig?

    public init(_ read: @escaping @Sendable () -> ServiceConfig?) {
        self.read = read
    }

    public func current() -> ServiceConfig? { read() }
}
