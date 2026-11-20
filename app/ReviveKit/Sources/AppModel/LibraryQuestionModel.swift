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
    public struct Answer: Equatable, Sendable, Identifiable {
        public let id: UUID
        public let question: String
        /// What has arrived so far, without the model's `<think>` part.
        public var text: String
        /// Filled in when the whole answer is in: its `[n]` marks are read then.
        public var sources: [SummarizedRecording]
        /// More is still coming (features.md G3 "SSE 流式").
        public var isStreaming: Bool
        /// The reply stopped part way; `text` is what arrived.
        public var isCutOff: Bool

        public init(id: UUID = UUID(), question: String, text: String, sources: [SummarizedRecording] = [],
                    isStreaming: Bool = false, isCutOff: Bool = false) {
            self.id = id
            self.question = question
            self.text = text
            self.sources = sources
            self.isStreaming = isStreaming
            self.isCutOff = isCutOff
        }
    }

    public private(set) var answer: Answer?
    public private(set) var isAsking = false
    public var toast: Toast?

    /// How many of the latest summaries are offered to the service.
    public static let sourceLimit = 30

    @ObservationIgnored private let library: RecordingLibrary
    @ObservationIgnored private let assistant: AssistantConfigSource?
    @ObservationIgnored private let asker: LibraryAsker
    @ObservationIgnored private var askTask: Task<Void, Never>?

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
        let started: (pieces: AsyncThrowingStream<String, Error>, used: Int)
        do {
            started = try asker.answerStream(question: question, sources: items.map(Self.source), config: config)
        } catch {
            toast = Toast(Self.text(for: error))
            return
        }
        // The answer shows as it arrives; the recordings it cites are listed once it is complete.
        let current = Answer(question: question, text: "", isStreaming: true)
        answer = current
        isAsking = true
        askTask = Task {
            defer { isAsking = false }
            var raw = ""
            var shown: Bool { answer?.id == current.id }
            do {
                for try await piece in started.pieces {
                    raw += piece
                    guard shown else { return }
                    answer?.text = ChatClient.visibleText(raw)
                }
                guard shown else { return }
                let text = ChatClient.visibleText(raw)
                guard !text.isEmpty else {
                    answer = nil
                    toast = Toast(AssistantSettingsModel.text(for: .badReply("回复是空的")))
                    return
                }
                answer?.text = text
                answer?.sources = LibraryAsker.citations(in: text, count: started.used).map { items[$0 - 1] }
                answer?.isStreaming = false
            } catch is CancellationError {
                // Cleared, or left the page.
            } catch {
                guard shown else { return }
                if ChatClient.visibleText(raw).isEmpty {
                    answer = nil
                    toast = Toast(Self.text(for: error))
                } else {
                    answer?.isStreaming = false
                    answer?.isCutOff = true
                    toast = Toast("回答没有收完整：" + Self.text(for: error))
                }
            }
        }
    }

    /// Clears the answer; one still arriving stops.
    public func clear() {
        askTask?.cancel()
        askTask = nil
        answer = nil
    }

    private static func text(for error: Error) -> String {
        (error as? AssistantError).map(AssistantSettingsModel.text(for:)) ?? "提问失败，请重试"
    }

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
