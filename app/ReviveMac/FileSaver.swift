import AppKit
import Player
import UniformTypeIdentifiers

/// Saves an exported file where the user chooses (the Mac's counterpart of the iPhone's share
/// sheet). The export itself is the iPhone's code (`RecordingDetailModel`); nothing is sent.
@MainActor
enum FileSaver {
    /// Asks where to save a copy of `file`; false when the user cancelled or the copy failed.
    @discardableResult
    static func save(_ file: URL) -> Bool {
        defer { RecordingExporter.cleanUp() }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = file.lastPathComponent
        panel.canCreateDirectories = true
        if let type = UTType(filenameExtension: file.pathExtension) { panel.allowedContentTypes = [type] }
        guard panel.runModal() == .OK, let target = panel.url else { return false }
        do {
            if FileManager.default.fileExists(atPath: target.path) {
                try FileManager.default.removeItem(at: target)
            }
            try FileManager.default.copyItem(at: file, to: target)
            return true
        } catch {
            return false
        }
    }
}
