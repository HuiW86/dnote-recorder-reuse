import AppModel
import Foundation
import Library
import Testing

// The Mac window's recording list (ADR-011, M5 step one) and the import it shares with the iPhone.
@MainActor
struct LibraryBrowserModelTests {
    private func library() throws -> (RecordingLibrary, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("browser-\(UUID().uuidString)")
        return (RecordingLibrary(database: try AppDatabase.inMemory(), store: try AudioStore(root: root)), root)
    }

    private func file(_ name: String, _ text: String, in root: URL) throws -> URL {
        let url = root.appendingPathComponent("in-\(UUID().uuidString)").appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        return url
    }

    @Test func importedTextShowsUpAndIsSearchable() async throws {
        let (library, root) = try library()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = LibraryBrowserModel(library: library)
        model.start()
        #expect(model.shown.isEmpty && model.searchResults == nil)

        let notes = try file("周会记录.md", "周三发布。\n\n记得发通知。", in: root)
        let broken = try file("坏的.mp3", "not audio", in: root)
        await model.importFiles([notes, broken])
        #expect(model.toast?.text == "已导入 1 个，1 个无法识别")
        await waitUntil("listed") { model.recordings.count == 1 }
        let recording = try #require(model.shown.first)
        #expect(model.rowTitle(recording) == "周会记录")
        #expect(model.rowSubtitle(recording).hasSuffix("文字 · 导入"))

        // Search runs on every change and follows the library.
        model.query = "通知"
        #expect(model.shown.map(\.id) == [recording.id])
        model.query = "没有这个词"
        #expect(model.shown.isEmpty && model.searchResults == [])
        model.query = "  "
        #expect(model.searchResults == nil && model.shown.count == 1)
        model.stop()
    }

    @Test func outcomeTexts() {
        #expect(LibraryImport.Outcome(imported: 1, failed: 0).text == "已导入")
        #expect(LibraryImport.Outcome(imported: 3, failed: 0).text == "已导入 3 个文件")
        #expect(LibraryImport.Outcome(imported: 0, failed: 2).text == "导入失败：不是能识别的音频或文字文件")
        #expect(LibraryImport.Outcome(imported: 2, failed: 1).text == "已导入 2 个，1 个无法识别")
        #expect(HomeModel.textExtensions == LibraryImport.textExtensions)
    }
}
