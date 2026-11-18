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
        static let syncNotifications = "revive.syncNotifications"
        static let onDeviceTranscript = "revive.onDeviceTranscript"
        static let assistantBaseURL = Preferences.assistantBaseURLKey
        static let assistantModel = Preferences.assistantModelKey
        static func deleteAfterSync(_ id: UUID) -> String { "revive.deleteAfterSync.\(id.uuidString)" }
    }

    /// UserDefaults keys of the AI service, for reading it off the main actor.
    public nonisolated static let assistantBaseURLKey = "revive.assistant.baseURL"
    public nonisolated static let assistantModelKey = "revive.assistant.model"

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
