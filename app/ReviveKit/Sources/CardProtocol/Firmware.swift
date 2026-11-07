/// Firmware version table (prd.md §2.4, features.md X1).
///
/// Unverified versions keep working with v1.50 behaviour; the caller shows a warning
/// and logs the version. When a version is found to behave differently, branch on it
/// in this module and add it to `verified` (#8).
public enum Firmware {
    public static let verified: Set<String> = ["1.50"]

    public enum Check: Equatable, Sendable {
        case verified
        /// Maps to the app warning `firmwareUnverified`; never blocks use.
        case unverified(version: String)
    }

    /// Accepts both "1.50" (from `0x80`) and "v1.50".
    public static func check(_ version: String) -> Check {
        let v = version.hasPrefix("v") ? String(version.dropFirst()) : version
        return verified.contains(v) ? .verified : .unverified(version: v)
    }
}
