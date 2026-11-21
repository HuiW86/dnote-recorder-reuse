import Foundation
import Library

/// Which summaries a 知识库 question is sent with (features.md G3). The service only reads a
/// limited number, so the ones that share words with the question go first; the newest fill
/// the rest, so a question about "最近" still gets the latest. Runs on the phone: nothing is
/// sent to choose them, and only the chosen summaries leave it.
enum QuestionSources {
    /// The summaries to send, most relevant first, then newest first; at most `limit`.
    /// `items` is newest summary first, as the library gives it.
    static func pick(_ question: String, from items: [SummarizedRecording], limit: Int) -> [SummarizedRecording] {
        let terms = terms(of: question)
        guard !terms.isEmpty else { return Array(items.prefix(limit)) }
        let scored = items.enumerated().map { index, item in
            (index: index, item: item, score: score(haystack(item), terms: terms))
        }
        let relevant = scored.filter { $0.score > 0 }
            .sorted { $0.score != $1.score ? $0.score > $1.score : $0.index < $1.index }
            .prefix(limit)
        let chosen = Set(relevant.map { $0.item.id })
        let newest = items.filter { !chosen.contains($0.id) }.prefix(limit - relevant.count)
        return relevant.map { $0.item } + newest
    }

    /// Words of the question worth matching: Latin and digit runs of two or more characters,
    /// and every two-character piece of a Chinese run (there are no spaces to split on).
    /// Question words such as "什么" and "有没有" are left out.
    static func terms(of question: String) -> Set<String> {
        var terms = Set<String>()
        for run in runs(question.lowercased()) {
            if run.isCJK {
                let chars = Array(run.text)
                if chars.count == 1 { continue }
                for i in 0..<(chars.count - 1) {
                    let pair = String(chars[i...i + 1])
                    if !stopPairs.contains(pair) { terms.insert(pair) }
                }
            } else if run.text.count >= 2, !stopWords.contains(run.text) {
                terms.insert(run.text)
            }
        }
        return terms
    }

    /// How many of the terms appear in the text.
    static func score(_ text: String, terms: Set<String>) -> Int {
        terms.reduce(0) { $0 + (text.contains($1) ? 1 : 0) }
    }

    /// Everything of a summary that the question may name, lowercased.
    static func haystack(_ item: SummarizedRecording) -> String {
        let s = item.summary
        var parts = [item.recording.title, s.title, s.summary]
        parts += s.sections.flatMap { [$0.heading] + $0.items }
        parts += s.todos.map(\.text)
        parts += s.tags + s.people + s.quotes
        parts += s.outline.flatMap { [$0.title] + $0.points }
        return parts.joined(separator: "\n").lowercased()
    }

    private struct Run {
        var text: String
        var isCJK: Bool
    }

    /// Splits text into runs of Chinese characters and runs of letters or digits; anything else
    /// (spaces, punctuation) ends a run.
    private static func runs(_ text: String) -> [Run] {
        var runs: [Run] = []
        var current: Run?
        for ch in text {
            let kind: Bool?
            if ch.unicodeScalars.allSatisfy(isCJK) {
                kind = true
            } else if ch.isLetter || ch.isNumber {
                kind = false
            } else {
                kind = nil
            }
            if let kind, current?.isCJK == kind {
                current?.text.append(ch)
            } else {
                if let current { runs.append(current) }
                current = kind.map { Run(text: String(ch), isCJK: $0) }
            }
        }
        if let current { runs.append(current) }
        return runs
    }

    private static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x20000...0x2FA1F: true
        default: false
        }
    }

    /// Two-character pieces that say how a question is asked, not what it is about.
    private static let stopPairs: Set<String> = [
        "什么", "哪些", "哪个", "哪里", "怎么", "怎样", "如何", "为什", "为何", "是否", "有没", "没有",
        "我们", "你们", "他们", "我的", "一下", "一些", "这个", "那个", "这些", "那些", "关于", "的是",
        "是什", "么时", "时候", "多少", "可以", "能不", "不能", "了吗", "过吗", "提到", "说过",
        "录音", "里面", "所有", "哪次", "之前", "以前",
    ]

    private static let stopWords: Set<String> = ["the", "and", "what", "when", "who", "how", "did", "about"]
}
