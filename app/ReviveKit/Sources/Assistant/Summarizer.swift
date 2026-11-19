// Transcript -> scene, title, summary, sections, todos, tags, people, outline, quotes
// (features.md G1, G2a).
//
// The prompts, the long-transcript chunking and the reply rules are adapted from
// andyhuo520/beanpod, commit 0d00fab, Shared/Analyzer.swift (`analyze`, `parse`, `fallback`,
// `split`), MIT License, Copyright (c) 2026 berryxia. See NOTICE at the repository root.
// Changes: no profession or notes-language settings (always Simplified Chinese), durations in
// milliseconds, todos become `SummaryTodo` rows.

import Foundation
import Library

/// A summary as the model (or the keyword fallback) produced it, before it is tied to a recording.
public struct SummaryDraft: Equatable, Sendable {
    public var scene: RecordingScene
    public var title: String
    public var summary: String
    public var sections: [SummarySection]
    public var todos: [String]
    public var tags: [String]
    public var people: [String]
    /// Topics in the order discussed (G1 大纲).
    public var outline: [OutlineItem]
    /// Sentences quoted as said (G1 金句).
    public var quotes: [String]
    /// The model name, or `Summarizer.fallbackModel` for the keyword fallback.
    public var model: String

    public init(scene: RecordingScene, title: String, summary: String, sections: [SummarySection],
                todos: [String], tags: [String], people: [String], outline: [OutlineItem] = [],
                quotes: [String] = [], model: String) {
        self.scene = scene
        self.title = title
        self.summary = summary
        self.sections = sections
        self.todos = todos
        self.tags = tags
        self.people = people
        self.outline = outline
        self.quotes = quotes
        self.model = model
    }

    /// The row to store with `RecordingLibrary.saveSummary`. Todos start unticked.
    public func record(recordingId: UUID, createdAt: Date = Date()) -> Summary {
        Summary(recordingId: recordingId, scene: scene.rawValue, title: title, summary: self.summary,
                sections: sections, todos: todos.map { SummaryTodo(text: $0) }, tags: tags, people: people,
                outline: outline, quotes: quotes, model: model, createdAt: createdAt)
    }

    /// True when it came from the keyword fallback; the UI says the result is rough.
    public var isFallback: Bool { model == Summarizer.fallbackModel }
}

public struct Summarizer: Sendable {
    /// `Summary.model` of a keyword-fallback summary.
    public static let fallbackModel = "keywords"
    /// Longer transcripts are first compressed chunk by chunk, to stay inside the model's context.
    public static let longTranscriptThreshold = 9000
    public static let chunkSize = 6000

    public let client: ChatClient

    public init(client: ChatClient = ChatClient()) {
        self.client = client
    }

    /// Asks the configured service for a summary: one request, or one per chunk plus one for a
    /// transcript longer than `longTranscriptThreshold` characters. `fixedScene` is the scene the
    /// user picked; nil lets the model choose.
    public func summarize(transcript: String, durationMs: Int, config: ServiceConfig,
                          fixedScene: RecordingScene? = nil) async throws -> SummaryDraft {
        guard config.isComplete else { throw AssistantError.notConfigured }
        var material = transcript
        if transcript.count > Self.longTranscriptThreshold {
            var notes: [String] = []
            for (i, chunk) in Self.split(transcript, size: Self.chunkSize).enumerated() {
                try Task.checkCancellation()
                let note = try await client.complete(config, system: Self.chunkPrompt(index: i + 1),
                                                     user: chunk, json: false)
                notes.append("【第 \(i + 1) 段】\n" + note)
            }
            material = notes.joined(separator: "\n\n")
        }
        let user = "录音时长：\(Self.promptDuration(ms: durationMs))\n\n文字稿：\n\(material)"
        let reply = try await client.complete(config, system: Self.systemPrompt(fixedScene: fixedScene),
                                              user: user, json: true)
        return try Self.parse(reply, fixedScene: fixedScene, model: config.model)
    }

    /// A new title from another angle (features.md G1 "换一个角度重起"): one request, answered
    /// in the same JSON shape as a summary's title. `avoiding` is the title to move away from.
    public func retitle(material: String, avoiding current: String, config: ServiceConfig) async throws -> String {
        guard config.isComplete else { throw AssistantError.notConfigured }
        let user = "现在的标题：\(current)\n\n内容：\n\(String(material.prefix(Self.longTranscriptThreshold)))"
        let reply = try await client.complete(config, system: Self.retitlePrompt, user: user, json: true)
        return try Self.parseTitle(reply)
    }

    static let retitlePrompt = """
        你在给一段录音起标题。换一个角度重新起一个：可以突出结论、人物、数字或要做的事，但不要和「现在的标题」相同或只改几个字。不超过 18 个字，简体中文，只写录音里真有的内容。
        只输出一个 JSON 对象，不要任何别的文字：{"title": "新标题"}
        """

    /// The `title` of a JSON reply; a reply that is just a line of text is taken as the title.
    public static func parseTitle(_ reply: String) throws -> String {
        let text = ChatClient.stripThinking(reply)
        var title = ""
        if let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end,
           let object = try? JSONSerialization.jsonObject(with: Data(text[start...end].utf8)) as? [String: Any] {
            title = trimmed(object["title"])
        } else {
            title = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
            title = title.trimmingCharacters(in: CharacterSet(charactersIn: " \"'“”「」《》").union(.whitespaces))
        }
        guard !title.isEmpty else { throw AssistantError.badReply("没有标题") }
        return String(title.prefix(30))
    }

    /// The text of a stored transcript, one segment per line, as `summarize` expects it.
    public static func material(from transcript: Transcript) -> String {
        transcript.segments.map(\.text).joined(separator: "\n")
    }

    // MARK: Prompts

    static func chunkPrompt(index: Int) -> String {
        "你在帮人整理一段长录音的文字稿。这是其中第 \(index) 段。用简体中文列出这一段里的事实、观点、数字、人名、约定和待办，每条一行，不要评论，不要编造。"
    }

    public static func systemPrompt(fixedScene: RecordingScene?) -> String {
        let sceneGuide = RecordingScene.allCases
            .map { "- \($0.rawValue)（\($0.name)）：\($0.definition)。栏目：\($0.headings.joined(separator: "、"))" }
            .joined(separator: "\n")
        let sceneRule = fixedScene.map { "场景已经确定是 \($0.rawValue)，不要改。" }
            ?? "先判断场景，从下面的英文代号里选一个。"
        return """
        你是录音整理助手。整理时抓住结论、事实和后续要做的事。

        \(sceneRule)
        \(sceneGuide)

        然后只输出一个 JSON 对象，不要任何别的文字：
        {
          "scene": "场景的英文代号",
          "title": "一句话标题，不超过 18 个字，说清这段录音是什么事",
          "summary": "两到四句话的摘要，先说结论",
          "sections": [{"heading": "所选场景的栏目名", "items": ["这一栏下的要点，每条一句完整的话"]}],
          "todos": ["后续要做的事，写清谁、做什么、什么时候；没有就给空数组"],
          "tags": ["2 到 5 个主题标签，名词，不带 #"],
          "people": ["出现的人名或称呼；没有就给空数组"],
          "outline": [{"title": "按录音里谈到的先后，一个话题一条", "points": ["这个话题下的要点，每条一句"]}],
          "quotes": ["录音里值得记住的原话，一字不改地摘出来；没有就给空数组"]
        }

        要求：
        - sections 必须使用所选场景的栏目名，某一栏没有内容就不要输出这一栏。
        - outline 按时间顺序，3 到 7 个话题；quotes 最多 5 句，必须是文字稿里的原话。
        - 只写录音里真有的内容。数字、金额、日期、人名照原样写，听不清的不要猜。
        - 全部用简体中文。
        """
    }

    /// "45 秒", "12 分钟", "1 小时 5 分".
    static func promptDuration(ms: Int) -> String {
        let seconds = max(0, ms) / 1000
        let minutes = seconds / 60
        if minutes >= 60 {
            return minutes % 60 == 0 ? "\(minutes / 60) 小时" : "\(minutes / 60) 小时 \(minutes % 60) 分"
        }
        return minutes >= 1 ? "\(minutes) 分钟" : "\(seconds) 秒"
    }

    // MARK: Reply

    /// Reads the model's JSON tolerantly: the text from the first `{` to the last `}`, trimmed
    /// fields, empty entries dropped, title at most 30 characters, at most 6 tags and 12 people,
    /// at most 8 outline topics of 6 points and 5 quotes (quote marks dropped), an unknown scene
    /// read as `other`. A reply without a summary is `badReply`; one without outline or quotes
    /// (an older prompt, a terse model) still parses.
    public static func parse(_ reply: String, fixedScene: RecordingScene?, model: String) throws -> SummaryDraft {
        let text = ChatClient.stripThinking(reply)
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end,
              let object = try? JSONSerialization.jsonObject(with: Data(text[start...end].utf8)) as? [String: Any]
        else {
            throw AssistantError.badReply("不是 JSON")
        }
        let summaryText = trimmed(object["summary"])
        guard !summaryText.isEmpty else { throw AssistantError.badReply("没有摘要") }

        let sceneText = trimmed(object["scene"]).lowercased()
        let scene = fixedScene
            ?? RecordingScene(rawValue: sceneText)
            ?? RecordingScene.allCases.first { $0.name == sceneText }
            ?? .other
        let sections = (object["sections"] as? [Any] ?? []).compactMap { entry -> SummarySection? in
            guard let section = entry as? [String: Any] else { return nil }
            let heading = trimmed(section["heading"])
            let items = strings(section["items"])
            guard !heading.isEmpty, !items.isEmpty else { return nil }
            return SummarySection(heading: heading, items: items)
        }
        let tags = strings(object["tags"])
            .map { $0.replacingOccurrences(of: "#", with: "").trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let outline = (object["outline"] as? [Any] ?? []).compactMap { entry -> OutlineItem? in
            guard let item = entry as? [String: Any] else { return nil }
            let title = trimmed(item["title"])
            guard !title.isEmpty else { return nil }
            return OutlineItem(title: String(title.prefix(40)), points: Array(strings(item["points"]).prefix(6)))
        }
        let quotes = strings(object["quotes"])
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "“”\"「」『』")) }
            .filter { !$0.isEmpty }
        return SummaryDraft(scene: scene, title: String(trimmed(object["title"]).prefix(30)), summary: summaryText,
                            sections: sections, todos: strings(object["todos"]), tags: Array(tags.prefix(6)),
                            people: Array(strings(object["people"]).prefix(12)),
                            outline: Array(outline.prefix(8)), quotes: Array(quotes.prefix(5)), model: model)
    }

    private static func trimmed(_ value: Any?) -> String {
        (value as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func strings(_ value: Any?) -> [String] {
        (value as? [Any] ?? []).compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    // MARK: Without a model

    /// A rough summary when no service is configured: the scene from keyword counts (a short
    /// recording with no match is a memo), the first sentence as the title and the first two as
    /// the summary. No sections, todos, tags or people.
    public static func fallback(transcript: String, durationMs: Int, fixedScene: RecordingScene? = nil) -> SummaryDraft {
        var best: (scene: RecordingScene, hits: Int) = (.other, 0)
        for scene in RecordingScene.allCases {
            let hits = scene.keywords.reduce(0) { $0 + transcript.components(separatedBy: $1).count - 1 }
            if hits > best.hits { best = (scene, hits) }
        }
        var scene = best.scene
        if scene == .other, durationMs < 90_000 { scene = .memo }
        let sentences = transcript
            .split(whereSeparator: { "。！？!?\n".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.count > 3 }
        let summaryText = sentences.isEmpty ? "" : sentences.prefix(2).joined(separator: "。") + "。"
        return SummaryDraft(scene: fixedScene ?? scene, title: String((sentences.first ?? "").prefix(16)),
                            summary: summaryText, sections: [], todos: [], tags: [], people: [], model: fallbackModel)
    }

    // MARK: Chunks

    /// Cuts `text` into pieces of at most `size` characters, each ending at the last sentence end
    /// (。！？!? or a newline) within the final quarter of the piece (at most 400 characters back);
    /// a piece with no sentence end there is cut at `size`.
    public static func split(_ text: String, size: Int) -> [String] {
        let size = max(1, size)
        var pieces: [String] = []
        var rest = Substring(text)
        while rest.count > size {
            let cut = rest.index(rest.startIndex, offsetBy: size)
            let window = rest[rest.index(cut, offsetBy: -min(400, size / 4))..<cut]
            let end = window.lastIndex(where: { "。！？!?\n".contains($0) }).map { rest.index(after: $0) } ?? cut
            pieces.append(String(rest[..<end]))
            rest = rest[end...]
        }
        if !rest.isEmpty { pieces.append(String(rest)) }
        return pieces
    }
}
