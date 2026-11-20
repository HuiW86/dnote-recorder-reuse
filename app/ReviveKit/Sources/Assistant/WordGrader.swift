// 单词分级 (features.md X20): the words worth learning in a foreign-language transcript, each
// with its CEFR level, its meaning here and the line it was heard in, from the user's own
// service (ADR-009). Only transcript lines that contain Latin letters are sent; no audio.

import Foundation
import Library

public struct WordGrader: Sendable {
    /// Lines per request.
    public static let batchSize = 80
    /// Words kept from one batch, so a long recording does not list hundreds.
    public static let perBatch = 30

    public let client: ChatClient

    public init(client: ChatClient = ChatClient()) {
        self.client = client
    }

    /// True when most letters in the transcript are Latin, so a word list makes sense.
    public static func isForeign(_ lines: [String]) -> Bool {
        var latin = 0, other = 0
        for scalar in lines.joined().unicodeScalars where scalar.properties.isAlphabetic {
            if scalar.isASCII { latin += 1 } else { other += 1 }
        }
        return latin >= 20 && latin > other
    }

    /// Words from every batch, in transcript order, each word once (the first time it is
    /// heard). A batch whose reply cannot be read adds nothing; if none can, throws `badReply`.
    public func grade(_ lines: [String], config: ServiceConfig) async throws -> [StudyWord] {
        guard config.isComplete else { throw AssistantError.notConfigured }
        let candidates = lines.enumerated().filter { line in
            line.element.unicodeScalars.contains { scalar in scalar.isASCII && scalar.properties.isAlphabetic }
        }
        guard !candidates.isEmpty else { return [] }
        var words: [StudyWord] = []
        var seen = Set<String>()
        var readable = 0
        for start in stride(from: 0, to: candidates.count, by: Self.batchSize) {
            try Task.checkCancellation()
            let batch = Array(candidates[start..<min(start + Self.batchSize, candidates.count)])
            let user = batch.enumerated().map { "\($0.offset + 1). \($0.element.element)" }.joined(separator: "\n")
            let reply = try await client.complete(config, system: Self.systemPrompt, user: user, json: true)
            guard let found = Self.parse(reply, lineCount: batch.count) else { continue }
            readable += 1
            for word in found.prefix(Self.perBatch) {
                let key = word.word.lowercased()
                guard seen.insert(key).inserted else { continue }
                var placed = word
                placed.segmentIndex = batch[word.segmentIndex].offset
                words.append(placed)
            }
        }
        guard readable > 0 else { throw AssistantError.badReply("没有读出生词") }
        return words.sorted { $0.segmentIndex < $1.segmentIndex }
    }

    static let systemPrompt = """
        你在帮中文母语的用户学外语。下面是一段录音的文字稿，每行前面是序号。
        挑出值得学的词和短语（常见的基础词不要），每个给出 CEFR 等级（A1、A2、B1、B2、C1、C2 之一）、在这句里的中文意思，以及它出现在第几行。
        只输出一个 JSON 对象，不要任何别的文字：
        {"words": [{"word": "原形或短语", "level": "B2", "meaning": "中文意思", "line": 3}]}
        同一个词只列一次，按出现的先后排列；没有值得学的词时给空数组。
        """

    /// The words of a reply, with `segmentIndex` as a 0-based position in the batch. Entries with
    /// no word, no readable level or a line outside the batch are dropped; nil when the reply is
    /// not a JSON object with a `words` list.
    static func parse(_ reply: String, lineCount: Int) -> [StudyWord]? {
        let text = ChatClient.stripThinking(reply)
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end,
              let object = try? JSONSerialization.jsonObject(with: Data(text[start...end].utf8)) as? [String: Any],
              let items = object["words"] as? [[String: Any]] else { return nil }
        return items.compactMap { item -> StudyWord? in
            let word = (item["word"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let meaning = (item["meaning"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let line = (item["line"] as? Int) ?? Int(item["line"] as? String ?? "") ?? 0
            guard !word.isEmpty, word.count <= 40, let level = WordLevel(loosely: item["level"] as? String ?? ""),
                  (1...lineCount).contains(line) else { return nil }
            return StudyWord(word: word, level: level, meaning: meaning, segmentIndex: line - 1)
        }
    }
}
