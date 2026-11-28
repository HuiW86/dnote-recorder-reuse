import Foundation
import Library
import Observation

/// 总览 and 知识库 (#89): open todos across recordings, recent summaries, and what is left to
/// do. Read from the library on this phone only; nothing here uses the network (CLAUDE.md
/// rule 3).
@MainActor
@Observable
public final class OverviewModel {
    public private(set) var digest = LibraryDigest()
    /// The library could not be read.
    public private(set) var loadError: String?
    public var toast: Toast?

    /// How many open todos 总览 lists before "还有 N 件".
    public static let todoLimit = 5

    @ObservationIgnored private let library: RecordingLibrary
    @ObservationIgnored private var observation: LibraryObservation?

    public init(library: RecordingLibrary) {
        self.library = library
    }

    public func start() {
        guard observation == nil else { return }
        observation = library.observeDigest(
            onError: { [weak self] in self?.loadError = String(describing: $0) },
            onChange: { [weak self] in
                self?.digest = $0
                self?.loadError = nil
            })
    }

    public func stop() {
        observation?.cancel()
        observation = nil
    }

    /// The first open todos, newest recording first.
    public var visibleTodos: [OpenTodo] { Array(digest.openTodos.prefix(Self.todoLimit)) }

    /// "还有 3 件，在各条录音的纪要里"; nil when every open todo is listed.
    public var moreTodosText: String? {
        let more = digest.openTodos.count - Self.todoLimit
        return more > 0 ? "还有 \(more) 件，在各条录音的纪要里" : nil
    }

    /// "还有 2 条没转成文字"; nil when every recording has a transcript.
    public var untranscribedText: String? {
        digest.untranscribedCount > 0 ? "还有 \(digest.untranscribedCount) 条没转成文字" : nil
    }

    /// "来自「11月7日 14:02」" under a todo.
    public func sourceText(_ todo: OpenTodo) -> String {
        "来自「\(RecordingText.title(todo.recording))」"
    }

    /// Ticks a todo from 总览; it leaves the list with the next change. False when it could not
    /// be saved, so the box can show it is still open.
    @discardableResult
    public func complete(_ todo: OpenTodo) -> Bool {
        do {
            let summary = try library.setTodoDone(recordingId: todo.recording.id, index: todo.index, done: true)
            lastCompleted = summary.map { (todo, $0.createdAt) }
            toast = Toast("已完成", action: "撤销")
            return true
        } catch {
            toast = Toast("保存失败，请重试")
            return false
        }
    }

    /// "撤销" on the toast: the todo just ticked is open again.
    public func undoComplete() {
        guard let last = lastCompleted else { return }
        let todo = last.todo
        lastCompleted = nil
        do {
            // Only the same todo in the same summary: a summary made again meanwhile has other
            // todos at those places, and they are the user's.
            guard let summary = try library.summary(recordingId: todo.recording.id),
                  summary.createdAt == last.summaryMadeAt, summary.todos.indices.contains(todo.index),
                  summary.todos[todo.index].text == todo.text, summary.todos[todo.index].done else {
                toast = Toast("纪要已经变了，没有撤销")
                return
            }
            try library.setTodoDone(recordingId: todo.recording.id, index: todo.index, done: false)
        } catch {
            toast = Toast("恢复失败，请重试")
        }
    }

    /// The todo `complete` ticked last, for "撤销".
    @ObservationIgnored private var lastCompleted: (todo: OpenTodo, summaryMadeAt: Date)?
}
