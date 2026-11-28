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
    /// Transcription model on the same service; empty keeps audio on the phone.
    public var transcriptionModel: String
    /// The user's job (features.md G1 职业设定); optional, works without a service too.
    public var profession: String
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
        transcriptionModel = preferences.assistantTranscriptionModel
        profession = preferences.assistantProfession
        apiKey = (try? keyStore.read()) ?? ""
        opened = stored
    }

    /// The settings as stored when the page opened, or when this page last saved or cleared them.
    @ObservationIgnored private var opened = Stored(baseURL: "", model: "", apiKey: "", transcriptionModel: "",
                                                    profession: "")

    /// The transcription model the chosen provider suggests, if it transcribes at all.
    public var suggestedTranscriptionModel: String? {
        ServicePreset.transcription.first { $0.baseURL == baseURL.trimmingCharacters(in: .whitespacesAndNewlines) }?
            .defaultModel
    }

    /// The preset whose address is filled in, if any.
    public var selectedPreset: ServicePreset? {
        presets.first { $0.baseURL == baseURL.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    public func choose(_ preset: ServicePreset) {
        baseURL = preset.baseURL
        if !preset.defaultModel.isEmpty || model.isEmpty { model = preset.defaultModel }
        // Fill the transcription model only when this provider also transcribes; never turn
        // audio upload on by itself if the user had left it empty.
        if !transcriptionModel.isEmpty {
            transcriptionModel = ServicePreset.transcription.first { $0.baseURL == preset.baseURL }?.defaultModel ?? ""
        }
        testResult = nil
    }

    public var config: ServiceConfig {
        ServiceConfig(baseURL: baseURL.trimmingCharacters(in: .whitespacesAndNewlines),
                      model: model.trimmingCharacters(in: .whitespacesAndNewlines),
                      apiKey: apiKey.trimmingCharacters(in: .whitespacesAndNewlines),
                      profession: Self.cleaned(profession))
    }

    public var isConfigured: Bool { config.isComplete }

    /// Stores address and model in Preferences and the key in the Keychain; an empty key is removed.
    public func save() {
        if persist() {
            toast = Toast("已保存")
        } else {
            toast = Toast("密钥保存失败，请重试")
        }
    }

    @discardableResult private func persist() -> Bool {
        let form = self.form
        preferences.assistantBaseURL = form.baseURL
        preferences.assistantModel = form.model
        preferences.assistantTranscriptionModel = form.transcriptionModel
        preferences.assistantProfession = form.profession
        do {
            try keyStore.save(form.apiKey)
            opened = form
            return true
        } catch {
            return false
        }
    }

    /// What the service settings hold, or what the form says, in stored (trimmed) form.
    private struct Stored: Equatable {
        var baseURL, model, apiKey, transcriptionModel, profession: String

        func sameService(as other: Stored) -> Bool {
            baseURL == other.baseURL && model == other.model && apiKey == other.apiKey
                && transcriptionModel == other.transcriptionModel
        }
    }

    private var form: Stored {
        let current = config
        return Stored(baseURL: current.baseURL, model: current.model, apiKey: current.apiKey,
                      transcriptionModel: transcriptionModel.trimmingCharacters(in: .whitespacesAndNewlines),
                      profession: current.profession)
    }

    /// As stored now; another page may have changed it since this one opened.
    private var stored: Stored {
        Stored(baseURL: preferences.assistantBaseURL, model: preferences.assistantModel,
               apiKey: (try? keyStore.read()) ?? "", transcriptionModel: preferences.assistantTranscriptionModel,
               profession: preferences.assistantProfession)
    }

    /// A service is stored on this phone: 「清除这个服务」 has something to clear.
    public var hasSavedService: Bool { !opened.baseURL.isEmpty || !opened.apiKey.isEmpty }

    /// The user edited the form since it was opened or last saved.
    public var hasUnsavedChanges: Bool { form != opened }

    /// Saving makes sense: something changed, and the service is complete or untouched (only the
    /// job changed, which works without a service).
    public var canSave: Bool { hasUnsavedChanges && (isConfigured || form.sameService(as: opened)) }

    /// Leaving the page keeps what can be kept, so a filled-in form is never lost to a missed 保存.
    /// It never stores a key for an address it was not typed for, and never overwrites what
    /// another page saved or cleared meanwhile.
    public func saveOnLeave() {
        guard canSave, mayKeepWithoutAsking else { return }
        persist()
    }

    private var mayKeepWithoutAsking: Bool {
        let form = self.form
        let keyFollowedNewAddress = form.baseURL != opened.baseURL && !opened.apiKey.isEmpty
            && form.apiKey == opened.apiKey
        return !keyFollowedNewAddress && stored == opened
    }

    /// Removes the service: the app goes back to working without AI.
    public func clear() {
        baseURL = ""
        model = ""
        apiKey = ""
        transcriptionModel = ""
        testResult = nil
        preferences.assistantBaseURL = ""
        preferences.assistantModel = ""
        preferences.assistantTranscriptionModel = ""
        // The job is about the user, not the service: it stays.
        try? keyStore.delete()
        opened = stored
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
                // It works: keep it, unless the form was edited while the test ran.
                if config == current, mayKeepWithoutAsking, persist() {
                    testResult = "连接成功，已保存"
                } else {
                    testResult = "连接成功"
                }
            } catch let error as AssistantError {
                testResult = Self.text(for: error)
            } catch {
                testResult = "连接失败：\(error.localizedDescription)"
            }
        }
    }

    /// The job as stored: one line, trimmed, at most `ServiceConfig.professionLimit` characters.
    public nonisolated static func cleaned(_ profession: String) -> String {
        let oneLine = profession.split(whereSeparator: \.isNewline).joined(separator: " ")
        return String(oneLine.trimmingCharacters(in: .whitespaces).prefix(ServiceConfig.professionLimit))
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
        case .offline: AssistantError.offlineAdvice
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
