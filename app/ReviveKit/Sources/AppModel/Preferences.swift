import Foundation

/// Small app settings kept in UserDefaults. Nothing secret goes here: bondIds live in the
/// Keychain (prd.md §5.1).
@MainActor
public final class Preferences {
    private let defaults: UserDefaults
    private enum Key {
        static let currentDevice = "revive.currentDevice"
        static let recordingConsent = "revive.recordingConsent"
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// The device the home screen shows (product-spec.md §4.4, P08).
    public var currentDeviceId: UUID? {
        get { defaults.string(forKey: Key.currentDevice).flatMap(UUID.init) }
        set { defaults.set(newValue?.uuidString, forKey: Key.currentDevice) }
    }

    /// The user ticked "我已征得对方同意" once; P04 is not shown again (product-spec.md P04).
    public var recordingConsentGiven: Bool {
        get { defaults.bool(forKey: Key.recordingConsent) }
        set { defaults.set(newValue, forKey: Key.recordingConsent) }
    }
}
