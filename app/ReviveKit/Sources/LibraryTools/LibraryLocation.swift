import Foundation

/// Where the apps keep their library, for tools that run outside them (features.md X19).
public enum LibraryLocation {
    /// The Mac app is not sandboxed (ADR-011), so its library is in a folder named after its
    /// bundle id under the user's Application Support: the same path `ReviveMac` opens.
    public static let macAppBundleId = "com.huiw86.revive.mac"

    public static var macApp: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent(macAppBundleId, isDirectory: true)
            .appendingPathComponent("library", isDirectory: true)
    }
}
