import Foundation

/// Small app settings kept in UserDefaults. Nothing secret goes here: bondIds live in the
/// Keychain (prd.md §5.1).
@MainActor
public final class Preferences {
    private let defaults: UserDefaults
    private enum Key {
        static let currentDevice = "revive.currentDevice"
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// The device the home screen shows (product-spec.md §4.4, P08).
    public var currentDeviceId: UUID? {
        get { defaults.string(forKey: Key.currentDevice).flatMap(UUID.init) }
        set { defaults.set(newValue?.uuidString, forKey: Key.currentDevice) }
    }
}
