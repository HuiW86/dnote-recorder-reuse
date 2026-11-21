import AppModel
import Foundation
import Library
import Observation
import Player

/// Composition root of the Mac app: the library on this Mac and one player.
@MainActor
@Observable
final class MacEnvironment {
    let library: RecordingLibrary?
    let libraryError: String?
    let player: RecordingPlayer?
    let browser: LibraryBrowserModel?

    init() {
        do {
            // Not sandboxed (ADR-011, distribution D): Application Support is shared by all apps,
            // so the library lives in a folder named after the bundle.
            let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.huiw86.revive.mac", isDirectory: true)
                .appendingPathComponent("library", isDirectory: true)
            let opened = RecordingLibrary(database: try AppDatabase.onDisk(directory: root),
                                          store: try AudioStore(root: root))
            library = opened
            libraryError = nil
            player = RecordingPlayer(library: opened)
            browser = LibraryBrowserModel(library: opened)
        } catch {
            library = nil
            libraryError = String(describing: error)
            player = nil
            browser = nil
        }
    }
}
