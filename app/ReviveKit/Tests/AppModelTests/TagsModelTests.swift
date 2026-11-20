import AppModel
import Foundation
import Library
import Testing

// D1c 标签 on 知识库: the list, a tag's recordings, rename, merge and delete with their toasts.
@MainActor
struct TagsModelTests {
    @Test func renamesMergesAndDeletes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tags-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let library = RecordingLibrary(database: try AppDatabase.inMemory(), store: try AudioStore(root: root))
        var ids: [UUID] = []
        for (i, tags) in [["发布", "排期"], ["上线"]].enumerated() {
            let file = root.appendingPathComponent("in-\(i).m4a")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try Data("audio".utf8).write(to: file)
            let recording = try library.addPhoneRecording(file: file, startedAt: Date(timeIntervalSince1970: Double(i)),
                                                          durationMs: 1_000)
            try library.saveSummary(Summary(recordingId: recording.id, scene: "meeting", title: "t", summary: "s",
                                            sections: [], todos: [], tags: tags, people: [], model: "m",
                                            createdAt: Date()))
            ids.append(recording.id)
        }
        let model = TagsModel(library: library)
        #expect(model.tags.map(\.name) == ["上线", "发布", "排期"])
        #expect(model.recordings(taggedWith: "发布").map(\.id) == [ids[0]])

        #expect(model.rename("排期", to: "计划") == "计划")
        #expect(model.toast?.text == "已改名为「计划」")
        #expect(model.rename("上线", to: "发布") == "发布")
        #expect(model.toast?.text == "已并入「发布」")
        #expect(model.tags == [TagCount(name: "发布", count: 2), TagCount(name: "计划", count: 1)])
        #expect(model.rename("发布", to: " ") == nil)

        model.delete("计划")
        #expect(model.toast?.text == "已删除标签「计划」，录音还在")
        #expect(model.tags == [TagCount(name: "发布", count: 2)])
        #expect(try library.recording(id: ids[0]) != nil)
    }
}
