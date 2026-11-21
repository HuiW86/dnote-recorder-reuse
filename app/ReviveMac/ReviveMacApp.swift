import AppModel
import SwiftUI

/// 闻笺 on the Mac (ADR-011, features.md X13): a native macOS target that shares ReviveKit and
/// AppModel with the iPhone app. M5 step one starts with the part that needs no card: the
/// recordings on this Mac, playback and importing. Pairing and sync follow once they have
/// evidence from a card on a Mac (CLAUDE.md rule 6).
@main
struct ReviveMacApp: App {
    @State private var env = MacEnvironment()

    var body: some Scene {
        WindowGroup("闻笺") {
            if let browser = env.browser, let player = env.player {
                LibraryWindow(model: browser, player: player)
            } else {
                ContentUnavailableView("打不开录音库", systemImage: "exclamationmark.triangle",
                                       description: Text(env.libraryError ?? ""))
            }
        }
        .defaultSize(width: 980, height: 660)
    }
}
