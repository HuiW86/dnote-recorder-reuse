import Foundation

/// Small app settings kept in UserDefaults. Nothing secret goes here: bondIds live in the
/// Keychain (prd.md §5.1).
@MainActor
public final class Preferences {
    private let defaults: UserDefaults
    private enum Key {
        static let currentDevice = "revive.currentDevice"
        static let recordingConsent = "revive.recordingConsent"
        static func deleteAfterSync(_ id: UUID) -> String { "revive.deleteAfterSync.\(id.uuidString)" }
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
