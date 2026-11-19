import Assistant
import Foundation
import Library
import Observation

/// "问问你的录音" on 知识库 (features.md G3): one question across the latest summaries, answered
/// by the user's own service with the recordings it used. Only summaries leave the phone, and
/// only when the user asks; nothing here runs on its own.
@MainActor
@Observable
public final class LibraryQuestionModel {
    /// The answer and the recordings it cited, in order of first use.
    public struct Answer: Equatable, Sendable {
        public let question: String
        public let text: String
        public let sources: [SummarizedRecording]
    }

    public private(set) var answer: Answer?
    public private(set) var isAsking = false
    public var toast: Toast?

    /// How many of the latest summaries are offered to the service.
    public static let sourceLimit = 30

    @ObservationIgnored private let library: RecordingLibrary
    @ObservationIgnored private let assistant: AssistantConfigSource?
    @ObservationIgnored private let asker: LibraryAsker

    public init(library: RecordingLibrary, assistant: AssistantConfigSource?, asker: LibraryAsker = LibraryAsker()) {
        self.library = library
        self.assistant = assistant
        self.asker = asker
    }

    /// A service is set; whether there are summaries to ask about is the page's call.
    public var isConfigured: Bool { assistant?.current() != nil }

    /// "会把最近 N 条纪要发给……" under the field.
    public var privacyNote: String {
        "提问时，会把最近 \(Self.sourceLimit) 条以内的纪要发给你在设置里填的 AI 服务；录音音频和文字稿不会发送。"
    }

    public func ask(_ question: String) {
        let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !isAsking, let config = assistant?.current() else { return }
        let items = (try? library.recentSummaries(limit: Self.sourceLimit)) ?? []
        guard !items.isEmpty else {
            toast = Toast("还没有整理好的纪要可以参考")
            return
        }
        let sources = items.map(Self.source)
        isAsking = true
        Task {
            defer { isAsking = false }
            do {
                let reply = try await asker.answer(question: question, sources: sources, config: config)
                answer = Answer(question: question, text: reply.text,
                                sources: reply.cited.map { items[$0 - 1] })
            } catch let error as AssistantError {
                toast = Toast(AssistantSettingsModel.text(for: error))
            } catch is CancellationError {
                // Left the page.
            } catch {
                toast = Toast("提问失败，请重试")
            }
        }
    }

    public func clear() { answer = nil }

    /// What the service reads for one recording: summary, sections and todos.
    static func source(_ item: SummarizedRecording) -> LibrarySource {
        let summary = item.summary
        var text = summary.summary
        for section in summary.sections where !section.items.isEmpty {
            text += "\n\(section.heading)：" + section.items.joined(separator: "；")
        }
        if !summary.todos.isEmpty {
            text += "\n待办：" + summary.todos.map(\.text).joined(separator: "；")
        }
        let label = summary.title.isEmpty ? RecordingText.title(item.recording) : summary.title
        return LibrarySource(id: item.recording.id, label: label,
                             date: RecordingText.dateTime(item.recording.startedAt), text: text)
    }
}
