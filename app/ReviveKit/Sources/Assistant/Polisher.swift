// 逐句润色 (#75, an optional step after F1): each transcript line is tidied by the user's own
// service (ADR-009) — filler words and stutters out, punctuation in — with the same number of
// lines, so every line still matches its time in the audio. Only the text is sent.

import Foundation

/// The polished text of each line, and how many lines kept their text because a batch's reply
/// did not line up.
public struct PolishResult: Equatable, Sendable {
    /// One per input line; an empty string keeps that line as it was.
    public var texts: [String]
    public var unchangedLines: Int
}

public struct Polisher: Sendable {
    /// Lines per request: short enough that a model keeps the count, long enough for context.
    public static let batchSize = 40

    public let client: ChatClient

    public init(client: ChatClient = ChatClient()) {
        self.client = client
    }

    /// Polishes `lines` batch by batch. A batch whose reply has a different number of lines is
    /// left as it was (its entries are empty); if no batch lines up, throws `badReply`.
    public func polish(_ lines: [String], config: ServiceConfig) async throws -> PolishResult {
        guard config.isComplete else { throw AssistantError.notConfigured }
        var texts: [String] = []
        var unchanged = 0
        for start in stride(from: 0, to: lines.count, by: Self.batchSize) {
            try Task.checkCancellation()
            let batch = Array(lines[start..<min(start + Self.batchSize, lines.count)])
            let reply = try await client.complete(config, system: Self.systemPrompt, user: Self.numbered(batch),
                                                  json: true)
            if let polished = Self.parse(reply, lines: batch) {
                texts += polished
            } else {
                texts += Array(repeating: "", count: batch.count)
                unchanged += batch.count
            }
        }
        if !lines.isEmpty, unchanged == lines.count { throw AssistantError.badReply("润色后的句数对不上") }
        return PolishResult(texts: texts, unchangedLines: unchanged)
    }

    static let systemPrompt = """
        你在润色一段录音的文字稿。下面每行是一句，前面是序号。逐句润色：
        - 去掉语气词、口头禅和重复（嗯、啊、那个、就是说、然后然后），补上标点，改正明显的错别字
        - 不改意思，不增加内容，不合并、不拆分、不调换句子；一句只剩语气词时，原样保留
        - 保持原来的语言，不翻译
        只输出一个 JSON 对象，不要任何别的文字：{"lines": ["第 1 句润色后的文字", "第 2 句……"]}
        lines 的条数必须和输入的行数相同，按原来的顺序，不带序号。
        """

    /// "1. 第一句\n2. 第二句" as the user message.
    static func numbered(_ lines: [String]) -> String {
        lines.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
    }

    /// The `lines` of a JSON reply when there is one per input line, with any echoed "3. "
    /// numbering removed (unless the input line itself starts that way); nil otherwise.
    static func parse(_ reply: String, lines input: [String]) -> [String]? {
        let text = ChatClient.stripThinking(reply)
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end,
              let object = try? JSONSerialization.jsonObject(with: Data(text[start...end].utf8)) as? [String: Any],
              let lines = object["lines"] as? [Any], lines.count == input.count else { return nil }
        return lines.enumerated().map { index, item -> String in
            var line = (item as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            for prefix in ["\(index + 1). ", "\(index + 1).", "\(index + 1)、"]
            where line.hasPrefix(prefix) && !input[index].hasPrefix(prefix) {
                line = String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
                break
            }
            return line
        }
    }
}
