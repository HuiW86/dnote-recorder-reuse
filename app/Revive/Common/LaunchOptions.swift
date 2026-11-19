import Foundation
import Library

/// Launch arguments for screenshots (`scripts/shots.sh`): open a tab, a recording or a pane
/// directly, as `-startTab knowledge`. DEBUG builds only; release builds ignore them.
enum LaunchOptions {
    /// `-startTab overview|recordings|knowledge|card`.
    static var startTab: MainTab? {
        string("startTab").flatMap(MainTab.init(rawValue:))
    }

    /// `-startPane summary|transcript|rewrite`.
    static var startPane: DetailPane? {
        string("startPane").flatMap(DetailPane.init(rawValue:))
    }

    /// `-openRecording first` opens the newest recording; a UUID opens that one.
    static func openRecording(in recordings: [Recording]) -> UUID? {
        guard let value = string("openRecording") else { return nil }
        if value == "first" { return recordings.first?.id }
        return UUID(uuidString: value)
    }

    /// `-demoLibrary YES`: a made-up library and a card that never connects (`DemoLibrary`).
    static var demoLibrary: Bool {
        #if DEBUG
        UserDefaults.standard.bool(forKey: "demoLibrary")
        #else
        false
        #endif
    }

    private static func string(_ key: String) -> String? {
        #if DEBUG
        UserDefaults.standard.string(forKey: key)
        #else
        nil
        #endif
    }
}
