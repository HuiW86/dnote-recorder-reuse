import Foundation
import Library
import Player

/// Importing files picked by the user into the library (features.md E2), shared by the iPhone's
/// home screen and the Mac window (ADR-011): audio becomes a recording, a text file becomes a
/// recording without audio whose paragraphs are its transcript. Nothing is sent anywhere.
public enum LibraryImport {
    /// File extensions read as text.
    public static let textExtensions: Set<String> = ["txt", "text", "md", "markdown"]

    public struct Outcome: Equatable, Sendable {
        public var imported = 0
        public var failed = 0

        public init(imported: Int = 0, failed: Int = 0) {
            self.imported = imported
            self.failed = failed
        }

        /// "已导入", "已导入 3 个文件", "导入失败：…", "已导入 2 个，1 个无法识别".
        public var text: String {
            switch (imported, failed) {
            case (_, 0): imported == 1 ? "已导入" : "已导入 \(imported) 个文件"
            case (0, _): "导入失败：不是能识别的音频或文字文件"
            default: "已导入 \(imported) 个，\(failed) 个无法识别"
            }
        }
    }

    /// Imports each file, named after it and dated by its creation time. The caller has already
    /// opened their security scope.
    public static func run(_ urls: [URL], into library: RecordingLibrary) async -> Outcome {
        var outcome = Outcome()
        for url in urls {
            do {
                let title = url.deletingPathExtension().lastPathComponent
                let created = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
                if textExtensions.contains(url.pathExtension.lowercased()) {
                    guard let text = TextImport.decode(try Data(contentsOf: url)),
                          try library.addTextRecording(text: text, title: title, startedAt: created) != nil
                    else { throw CocoaError(.fileReadCorruptFile) }
                } else {
                    let prepared = try await AudioImporter.prepare(url)
                    try library.addLocalRecording(file: prepared.file, source: .import, startedAt: created,
                                                  durationMs: prepared.durationMs, title: title)
                    try? FileManager.default.removeItem(at: prepared.file.deletingLastPathComponent())
                }
                outcome.imported += 1
            } catch {
                outcome.failed += 1
            }
        }
        return outcome
    }
}
