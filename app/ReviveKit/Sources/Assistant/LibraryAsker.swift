// Asking a question across the user's recordings (features.md G3, 全局对话), through the user's
// own service (ADR-009). Only summaries are sent, never audio or transcripts. The idea of
// answering only from the user's material and citing it is adapted from andyhuo520/beanpod
// (commit 0d00fab, Shared/Analyzer.swift `answer`), MIT.

import Foundation

/// One recording's summary as the service reads it, numbered by its place in the list.
public struct LibrarySource: Equatable, Sendable {
    public let id: UUID
    /// What the page shows for the recording, such as "周四发外部测试".
    public let label: String
    /// "11月18日 14:02".
    public let date: String
    /// Summary text, sections and todos.
    public let text: String

    public init(id: UUID, label: String, date: String, text: String) {
        self.id = id
        self.label = label
        self.date = date
        self.text = text
    }
}

/// The service's answer and the sources it cited, as 1-based positions in the list it was given.
public struct LibraryAnswer: Equatable, Sendable {
    public let text: String
    public let cited: [Int]

    public init(text: String, cited: [Int]) {
        self.text = text
        self.cited = cited
    }
}

public struct LibraryAsker: Sendable {
    /// Summaries beyond this many characters are left out, newest kept, so one request stays
    /// within common context limits.
    public static let maxMaterial = 24_000

    public let client: ChatClient

    public init(client: ChatClient = ChatClient()) {
        self.client = client
    }

    /// The sources that fit, in order, numbered from 1: "[1] 标题（日期）\n内容".
    public static func material(_ sources: [LibrarySource]) -> (text: String, used: Int) {
        var blocks: [String] = []
        var length = 0
        for (index, source) in sources.enumerated() {
            let block = "[\(index + 1)] \(source.label)（\(source.date)）\n\(source.text)"
            if length + block.count > maxMaterial, !blocks.isEmpty { break }
            blocks.append(String(block.prefix(maxMaterial)))
            length += block.count + 2
        }
        return (blocks.joined(separator: "\n\n"), blocks.count)
    }

    static let systemPrompt = """
        你根据用户自己的录音纪要回答问题。下面每条纪要前面有编号 [1]、[2]……
        只用这些纪要里的内容回答；没有相关记录就直说没有记录到，不要编。
        在用到某条纪要的句子末尾标上它的编号，比如「下周三上线 [2]」。回答简洁，用提问所用的语言。
        """

    public func answer(question: String, sources: [LibrarySource], config: ServiceConfig) async throws -> LibraryAnswer {
        guard config.isComplete else { throw AssistantError.notConfigured }
        let (material, used) = Self.material(sources)
        guard used > 0 else { throw AssistantError.badReply("没有可以参考的纪要") }
        let reply = try await client.complete(config, system: Self.systemPrompt,
                                              user: "纪要：\n\(material)\n\n问题：\(question)", json: false)
        let text = ChatClient.stripThinking(reply).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw AssistantError.badReply("回复是空的") }
        return LibraryAnswer(text: text, cited: Self.citations(in: text, count: used))
    }

    /// The `[n]` marks in `text` that name one of `count` sources, in order of first use.
    public static func citations(in text: String, count: Int) -> [Int] {
        var seen: [Int] = []
        var rest = Substring(text)
        while let open = rest.firstIndex(of: "[") {
            let after = rest[rest.index(after: open)...]
            guard let close = after.firstIndex(of: "]") else { break }
            for part in after[..<close].split(whereSeparator: { $0 == "," || $0 == "，" || $0 == " " }) {
                if let n = Int(part), (1...count).contains(n), !seen.contains(n) { seen.append(n) }
            }
            rest = after[after.index(after: close)...]
        }
        return seen
    }
}
