import Foundation
import Library
import Observation

/// 标签 on 知识库 (features.md D1c): the recordings a tag is on, and renaming, merging or
/// deleting a tag across all summaries. Summaries made later follow the same edits. Local only.
@MainActor
@Observable
public final class TagsModel {
    /// Every tag, most used first.
    public private(set) var tags: [TagCount] = []
    public var toast: Toast?

    @ObservationIgnored private let library: RecordingLibrary

    public init(library: RecordingLibrary) {
        self.library = library
        reload()
    }

    public func reload() {
        tags = (try? library.tagCounts()) ?? []
    }

    /// Recordings whose summary has `tag`, newest first.
    public func recordings(taggedWith tag: String) -> [Recording] {
        (try? library.recordings(taggedWith: tag)) ?? []
    }

    /// Renames `tag`; a name some recordings already carry merges the two. Returns the name the
    /// tag now has, or nil when nothing changed (an empty or unchanged name, or a failure).
    @discardableResult
    public func rename(_ tag: String, to name: String) -> String? {
        let new = name.trimmingCharacters(in: CharacterSet(charactersIn: "# ").union(.whitespacesAndNewlines))
        guard !new.isEmpty, new != tag else { return nil }
        let merges = tags.contains { $0.name == new }
        do {
            try library.renameTag(tag, to: new)
            reload()
            toast = Toast(merges ? "已并入「\(new)」" : "已改名为「\(new)」")
            return new
        } catch {
            toast = Toast("保存失败，请重试")
            return nil
        }
    }

    public func delete(_ tag: String) {
        do {
            try library.deleteTag(tag)
            reload()
            toast = Toast("已删除标签「\(tag)」，录音还在")
        } catch {
            toast = Toast("删除失败，请重试")
        }
    }
}
