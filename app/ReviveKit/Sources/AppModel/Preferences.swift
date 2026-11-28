import AIRoute
import Foundation
import Observation

/// Small app settings kept in UserDefaults. Nothing secret goes here: bondIds live in the
/// Keychain (prd.md §5.1).
@MainActor
@Observable
public final class Preferences {
    @ObservationIgnored private let defaults: UserDefaults
    private enum Key {
        static let currentDevice = "revive.currentDevice"
        static let recordingConsent = "revive.recordingConsent"
        static let usesWithoutCard = "revive.usesWithoutCard"
        static let syncNotifications = "revive.syncNotifications"
        static let onDeviceTranscript = "revive.onDeviceTranscript"
        static let appearance = "revive.appearance"
        static let assistantBaseURL = Preferences.assistantBaseURLKey
        static let assistantModel = Preferences.assistantModelKey
        static let assistantTranscriptionModel = Preferences.assistantTranscriptionModelKey
        static let assistantProfession = Preferences.assistantProfessionKey
        static let autoProcessSince = "revive.autoProcessSince"
        static let defaultTranscriptionPath = "revive.ai.defaultTranscription"
        static let defaultSummaryPath = "revive.ai.defaultSummary"
        static let aiConsentsAccount = "revive.ai.consentsAccount"
        static let autoTranscriptionSkipped = "revive.ai.autoTranscriptionSkipped"
        static let earlierAIDefaultsAdopted = "revive.ai.earlierDefaultsAdopted"
        static func consent(_ consent: AIConsent) -> String { "revive.ai.consent.\(consent.rawValue)" }
        static func deleteAfterSync(_ id: UUID) -> String { "revive.deleteAfterSync.\(id.uuidString)" }
    }

    /// UserDefaults keys of the AI service, for reading it off the main actor.
    public nonisolated static let assistantBaseURLKey = "revive.assistant.baseURL"
    public nonisolated static let assistantModelKey = "revive.assistant.model"
    public nonisolated static let assistantTranscriptionModelKey = "revive.assistant.transcriptionModel"
    /// The user's job (features.md G1 职业设定), sent with summary requests.
    public nonisolated static let assistantProfessionKey = "revive.assistant.profession"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// The device the home screen shows (product-spec.md §4.4, P08). Observed, so switching
    /// cards on P08 redraws home.
    public var currentDeviceId: UUID? {
        get {
            access(keyPath: \.currentDeviceId)
            return defaults.string(forKey: Key.currentDevice).flatMap(UUID.init)
        }
        set {
            withMutation(keyPath: \.currentDeviceId) { defaults.set(newValue?.uuidString, forKey: Key.currentDevice) }
        }
    }

    /// The user ticked "我已征得对方同意" once; P04 is not shown again (product-spec.md P04).
    public var recordingConsentGiven: Bool {
        get { defaults.bool(forKey: Key.recordingConsent) }
        set { defaults.set(newValue, forKey: Key.recordingConsent) }
    }

    /// "先不连卡，直接用" on P01 (product-spec.md §2.1): the tabs open without a paired card, also
    /// after a relaunch. Cleared by "添加录音卡" while no Bluetooth stack exists, which goes back
    /// to P01. Observed, so the root view switches at once.
    public var usesWithoutCard: Bool {
        get {
            access(keyPath: \.usesWithoutCard)
            return defaults.bool(forKey: Key.usesWithoutCard)
        }
        set {
            withMutation(keyPath: \.usesWithoutCard) { defaults.set(newValue, forKey: Key.usesWithoutCard) }
        }
    }

    /// "同步完成时通知": a local notification after a background sync stored recordings
    /// (features.md X8). Off by default; turning it on asks for the system permission.
    public var syncNotificationsEnabled: Bool {
        get {
            access(keyPath: \.syncNotificationsEnabled)
            return defaults.bool(forKey: Key.syncNotifications)
        }
        set {
            withMutation(keyPath: \.syncNotificationsEnabled) { defaults.set(newValue, forKey: Key.syncNotifications) }
        }
    }

    /// "本机转写（试验）" (features.md X9). Off by default until its quality on real recordings
    /// has been measured (#67).
    public var onDeviceTranscriptEnabled: Bool {
        get {
            access(keyPath: \.onDeviceTranscriptEnabled)
            return defaults.bool(forKey: Key.onDeviceTranscript)
        }
        set {
            withMutation(keyPath: \.onDeviceTranscriptEnabled) { defaults.set(newValue, forKey: Key.onDeviceTranscript) }
        }
    }

    /// The user's AI service (features.md X11, ADR-009): address and model only. The key is
    /// secret and lives in the Keychain (`KeychainKeyStore`), never here.
    public var assistantBaseURL: String {
        get {
            access(keyPath: \.assistantBaseURL)
            return defaults.string(forKey: Key.assistantBaseURL) ?? ""
        }
        set {
            withMutation(keyPath: \.assistantBaseURL) { defaults.set(newValue, forKey: Key.assistantBaseURL) }
        }
    }

    public var assistantModel: String {
        get {
            access(keyPath: \.assistantModel)
            return defaults.string(forKey: Key.assistantModel) ?? ""
        }
        set {
            withMutation(keyPath: \.assistantModel) { defaults.set(newValue, forKey: Key.assistantModel) }
        }
    }

    /// The user's job (features.md G1 职业设定); empty when not given.
    public var assistantProfession: String {
        get {
            access(keyPath: \.assistantProfession)
            return defaults.string(forKey: Key.assistantProfession) ?? ""
        }
        set {
            withMutation(keyPath: \.assistantProfession) {
                defaults.set(newValue, forKey: Key.assistantProfession)
            }
        }
    }

    /// Transcription model on the same service, such as "whisper-1"; empty means the service is
    /// not used for transcription (the audio then never leaves the phone).
    public var assistantTranscriptionModel: String {
        get {
            access(keyPath: \.assistantTranscriptionModel)
            return defaults.string(forKey: Key.assistantTranscriptionModel) ?? ""
        }
        set {
            withMutation(keyPath: \.assistantTranscriptionModel) {
                defaults.set(newValue, forKey: Key.assistantTranscriptionModel)
            }
        }
    }

    /// "录完自动整理" (features.md X22): a recording that reaches the phone is transcribed and
    /// summarized without a tap. Off by default, as it sends every new recording to the
    /// services the user configured.
    public var autoProcessEnabled: Bool {
        get { autoProcessSince != nil }
        set {
            guard newValue != autoProcessEnabled else { return }
            withMutation(keyPath: \.autoProcessSince) {
                defaults.set(newValue ? Date().timeIntervalSince1970 : nil, forKey: Key.autoProcessSince)
            }
        }
    }

    /// When "录完自动整理" was turned on; nil while it is off. Only recordings stored since then
    /// are processed, so turning it on does not send the whole library.
    public var autoProcessSince: Date? {
        access(keyPath: \.autoProcessSince)
        let seconds = defaults.double(forKey: Key.autoProcessSince)
        return seconds > 0 ? Date(timeIntervalSince1970: seconds) : nil
    }

    // MARK: AI paths (product-spec.md §7.3b)

    /// P09 默认转写方式; nil until the user chose one (then this phone is used).
    public var defaultTranscriptionPath: AIPath? {
        get {
            access(keyPath: \.defaultTranscriptionPath)
            return defaults.string(forKey: Key.defaultTranscriptionPath).flatMap(AIPath.init(rawValue:))
        }
        set {
            withMutation(keyPath: \.defaultTranscriptionPath) {
                defaults.set(newValue?.rawValue, forKey: Key.defaultTranscriptionPath)
            }
        }
    }

    /// P09 默认纪要方式; nil until the user chose one (the first summary then asks). Never the phone.
    public var defaultSummaryPath: AIPath? {
        get {
            access(keyPath: \.defaultSummaryPath)
            return defaults.string(forKey: Key.defaultSummaryPath).flatMap(AIPath.init(rawValue:))
                .flatMap { AIWork.summarize.paths.contains($0) ? $0 : nil }
        }
        set {
            withMutation(keyPath: \.defaultSummaryPath) {
                let kept = newValue.flatMap { AIWork.summarize.paths.contains($0) ? $0 : nil }
                defaults.set(kept?.rawValue, forKey: Key.defaultSummaryPath)
            }
        }
    }

    /// What the user agreed to send the 闻笺 account (§7.3b 上传前的确认), each kept apart.
    public var aiConsents: Set<AIConsent> {
        access(keyPath: \.aiConsents)
        return Set(AIConsent.allCases.filter { defaults.bool(forKey: Key.consent($0)) })
    }

    public func grant(_ consent: AIConsent) {
        withMutation(keyPath: \.aiConsents) { defaults.set(true, forKey: Key.consent(consent)) }
    }

    /// The account signed out or was deleted: signing in again asks again (§7.3b).
    public func forgetAIConsents() {
        withMutation(keyPath: \.aiConsents) {
            for consent in AIConsent.allCases { defaults.removeObject(forKey: Key.consent(consent)) }
        }
    }

    /// An earlier phone's 录完自动整理 had no way to transcribe and skipped that step; it keeps
    /// skipping until the user chooses a 默认转写方式 (then `defaultTranscriptionPath` is set).
    public var autoTranscriptionSkippedBefore: Bool { defaults.bool(forKey: Key.autoTranscriptionSkipped) }

    /// The consents belong to the account signed in when they were given: for any other account,
    /// or none (a sign-in that ran out without 退出登录), they are forgotten.
    public func keepAIConsents(for account: UUID?) {
        let current = account?.uuidString
        guard defaults.string(forKey: Key.aiConsentsAccount) != current else { return }
        forgetAIConsents()
        defaults.set(current, forKey: Key.aiConsentsAccount)
    }

    /// Once, on a phone that had the app before §7.3b: keeps the way it transcribed and
    /// summarized (the old 本机转写（试验） switch, the user's service) as the defaults, so nothing
    /// changes under the user. A new phone keeps no default and follows §7.3b.
    public func adoptEarlierAIDefaults(ownTranscription: Bool, ownService: Bool) {
        guard !defaults.bool(forKey: Key.earlierAIDefaultsAdopted) else { return }
        defaults.set(true, forKey: Key.earlierAIDefaultsAdopted)
        let earlier = AIRoute.earlierDefaults(onDeviceSwitch: onDeviceTranscriptEnabled,
                                              ownTranscription: ownTranscription, ownService: ownService)
        // 录完自动整理 was on and could not transcribe: it skipped that step (see below).
        if autoProcessEnabled, earlier.transcribe == nil {
            defaults.set(true, forKey: Key.autoTranscriptionSkipped)
        }
        if defaultTranscriptionPath == nil, let path = earlier.transcribe { defaultTranscriptionPath = path }
        if defaultSummaryPath == nil, let path = earlier.summarize { defaultSummaryPath = path }
    }

    /// 外观 in settings (#89): follow the system, or always light or dark.
    public enum Appearance: String, CaseIterable, Identifiable, Sendable {
        case system, light, dark

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .system: "跟随系统"
            case .light: "浅色"
            case .dark: "深色"
            }
        }
    }

    public var appearance: Appearance {
        get {
            access(keyPath: \.appearance)
            return defaults.string(forKey: Key.appearance).flatMap(Appearance.init(rawValue:)) ?? .system
        }
        set {
            withMutation(keyPath: \.appearance) { defaults.set(newValue.rawValue, forKey: Key.appearance) }
        }
    }

    /// "同步后删除卡上录音", per card and off by default (product-spec.md P07, prd.md §4.5).
    public func deleteAfterSync(for deviceId: UUID) -> Bool {
        defaults.bool(forKey: Key.deleteAfterSync(deviceId))
    }

    public func setDeleteAfterSync(_ on: Bool, for deviceId: UUID) {
        defaults.set(on, forKey: Key.deleteAfterSync(deviceId))
    }

    /// Forgets a card's settings when it is unpaired, so pairing it again starts from the defaults.
    public func forget(_ deviceId: UUID) {
        defaults.removeObject(forKey: Key.deleteAfterSync(deviceId))
        if currentDeviceId == deviceId { currentDeviceId = nil }
    }
}
