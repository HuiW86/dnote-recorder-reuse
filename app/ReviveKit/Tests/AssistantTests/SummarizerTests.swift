import Foundation
import Testing
import Library
@testable import Assistant

struct SummaryParsingTests {
    private let good = """
        {"scene": "meeting", "title": " 周会排期 ", "summary": "下周三上线。",
         "sections": [{"heading": "结论与决定", "items": ["下周三上线", " "]}, {"heading": "分歧与风险", "items": []}],
         "todos": ["老王周二前测完", ""], "tags": ["#排期", "上线"], "people": ["老王"]}
        """

    @Test func readsAGoodReply() throws {
        let draft = try Summarizer.parse(good, fixedScene: nil, model: "m1")
        #expect(draft.scene == .meeting)
        #expect(draft.title == "周会排期")
        #expect(draft.summary == "下周三上线。")
        // Empty items and sections with no items are dropped.
        #expect(draft.sections == [SummarySection(heading: "结论与决定", items: ["下周三上线"])])
        #expect(draft.todos == ["老王周二前测完"])
        #expect(draft.tags == ["排期", "上线"])
        #expect(draft.people == ["老王"])
        #expect(draft.model == "m1" && !draft.isFallback)
    }

    @Test func readsJSONWrappedInProseAndThinking() throws {
        let reply = "<think>这是会议吗？{\"scene\":\"call\"}</think>好的，整理如下：\n```json\n\(good)\n```\n希望有帮助。"
        let draft = try Summarizer.parse(reply, fixedScene: nil, model: "m")
        #expect(draft.scene == .meeting && draft.summary == "下周三上线。")
    }

    /// G1 大纲、金句: topics with their points in order, quotes without their quote marks, both
    /// capped; a reply without them still parses (an older prompt or a terse model).
    @Test func readsOutlineAndQuotes() throws {
        let points = (1...9).map { "\"点\($0)\"" }.joined(separator: ",")
        let topics = (1...10).map { #"{"title":"话题\#($0)","points":[\#(points)]}"# }.joined(separator: ",")
        let quotes = (1...7).map { "\"「原话\($0)」\"" }.joined(separator: ",")
        let reply = #"{"scene":"meeting","title":"t","summary":"s","outline":[{"title":"","points":["x"]},"#
            + topics + #"],"quotes":[" ",\#(quotes)]}"#
        let draft = try Summarizer.parse(reply, fixedScene: nil, model: "m")
        #expect(draft.outline.count == 8 && draft.outline.first?.title == "话题1")
        #expect(draft.outline.first?.points == (1...6).map { "点\($0)" })
        #expect(draft.quotes == (1...5).map { "原话\($0)" })
        let row = draft.record(recordingId: UUID())
        #expect(row.outline == draft.outline && row.quotes == draft.quotes)

        let plain = try Summarizer.parse(#"{"scene":"memo","title":"t","summary":"s"}"#, fixedScene: nil, model: "m")
        #expect(plain.outline.isEmpty && plain.quotes.isEmpty)
        #expect(Summarizer.systemPrompt(fixedScene: nil).contains("\"outline\""))
    }

    /// G1 "换一个角度重起": the title of a JSON reply, or a bare line; quotes trimmed; capped.
    @Test func readsANewTitle() throws {
        #expect(try Summarizer.parseTitle(#"{"title": " 周四发外部测试 "}"#) == "周四发外部测试")
        #expect(try Summarizer.parseTitle("<think>想一想</think>\n「定下发布日」\n多余的话") == "定下发布日")
        #expect(try Summarizer.parseTitle(String(repeating: "长", count: 40)).count == 30)
        #expect(throws: AssistantError.badReply("没有标题")) { try Summarizer.parseTitle(#"{"title": ""}"#) }
        #expect(Summarizer.retitlePrompt.contains("不要和「现在的标题」相同"))
    }

    @Test func missingSummaryIsBadReply() {
        for reply in [#"{"scene": "meeting", "title": "t"}"#, #"{"summary": "   "}"#, "没有 JSON", "} 反了 {"] {
            #expect(throws: AssistantError.self) { try Summarizer.parse(reply, fixedScene: nil, model: "m") }
        }
        do {
            _ = try Summarizer.parse(#"{"title": "t"}"#, fixedScene: nil, model: "m")
            Issue.record("expected badReply")
        } catch let error as AssistantError {
            #expect(error == .badReply("没有摘要"))
        } catch {
            Issue.record("unexpected \(error)")
        }
    }

    @Test func sceneIsReadTolerantly() throws {
        #expect(try Summarizer.parse(#"{"scene": "podcast", "summary": "s"}"#, fixedScene: nil, model: "m").scene == .other)
        #expect(try Summarizer.parse(#"{"summary": "s"}"#, fixedScene: nil, model: "m").scene == .other)
        #expect(try Summarizer.parse(#"{"scene": " Sales ", "summary": "s"}"#, fixedScene: nil, model: "m").scene == .sales)
        #expect(try Summarizer.parse(#"{"scene": "课程", "summary": "s"}"#, fixedScene: nil, model: "m").scene == .lesson)
        // The scene the user picked wins over the model's.
        #expect(try Summarizer.parse(#"{"scene": "sales", "summary": "s"}"#, fixedScene: .call, model: "m").scene == .call)
    }

    @Test func capsTitleTagsAndPeople() throws {
        let title = String(repeating: "长", count: 40)
        let tags = (1...8).map { "\"#标签\($0)\"" }.joined(separator: ",")
        let people = (1...15).map { "\"人\($0)\"" }.joined(separator: ",")
        // Two #s: the text holds "# and "#" ends a one-# raw string.
        let reply = ##"{"summary": "s", "title": "\##(title)", "tags": [\##(tags), "#"], "people": [\##(people)]}"##
        let draft = try Summarizer.parse(reply, fixedScene: nil, model: "m")
        #expect(draft.title.count == 30)
        #expect(draft.tags == (1...6).map { "标签\($0)" })
        #expect(draft.people == (1...12).map { "人\($0)" })
    }

    @Test func draftBecomesALibraryRow() throws {
        let draft = try Summarizer.parse(good, fixedScene: nil, model: "m1")
        let id = UUID()
        let created = Date(timeIntervalSince1970: 1_800_000_000)
        let row = draft.record(recordingId: id, createdAt: created)
        #expect(row.recordingId == id && row.createdAt == created)
        #expect(row.scene == "meeting" && row.title == draft.title && row.summary == draft.summary)
        #expect(row.todos == [SummaryTodo(text: "老王周二前测完", done: false)])
        #expect(row.sections == draft.sections && row.tags == draft.tags && row.people == draft.people)
        #expect(row.model == "m1")
    }
}

struct SummaryTextTests {
    @Test func splitPrefersSentenceEnds() {
        let text = String(repeating: "字", count: 35) + "。" + String(repeating: "字", count: 20)
        let pieces = Summarizer.split(text, size: 40)
        #expect(pieces.count == 2)
        #expect(pieces[0].count == 36 && pieces[0].hasSuffix("。"))
        #expect(pieces.joined() == text)
    }

    @Test func splitCutsAtSizeWithoutASentenceEnd() {
        let text = String(repeating: "字", count: 100)
        let pieces = Summarizer.split(text, size: 40)
        #expect(pieces.map(\.count) == [40, 40, 20])
        #expect(pieces.joined() == text)
    }

    @Test func splitLeavesShortTextWhole() {
        #expect(Summarizer.split("一句话。", size: 6000) == ["一句话。"])
        #expect(Summarizer.split("", size: 6000).isEmpty)
    }

    @Test func fallbackGuessesTheSceneFromKeywords() {
        let draft = Summarizer.fallback(transcript: "各位，今天周会对齐一下排期。下周三上线。", durationMs: 600_000)
        #expect(draft.scene == .meeting)
        #expect(draft.title == "各位，今天周会对齐一下排期")
        #expect(draft.summary == "各位，今天周会对齐一下排期。下周三上线。")
        #expect(draft.sections.isEmpty && draft.todos.isEmpty && draft.tags.isEmpty && draft.people.isEmpty)
        #expect(draft.isFallback && draft.model == Summarizer.fallbackModel)
    }

    @Test func fallbackWithoutKeywords() {
        #expect(Summarizer.fallback(transcript: "嗯好的明天再说吧", durationMs: 30_000).scene == .memo)
        #expect(Summarizer.fallback(transcript: "嗯好的明天再说吧", durationMs: 600_000).scene == .other)
        #expect(Summarizer.fallback(transcript: "嗯好的明天再说吧", durationMs: 600_000, fixedScene: .call).scene == .call)
        let empty = Summarizer.fallback(transcript: "", durationMs: 0)
        #expect(empty.title.isEmpty && empty.summary.isEmpty)
    }

    @Test func promptDurationReadsLikeSpeech() {
        #expect(Summarizer.promptDuration(ms: 45_000) == "45 秒")
        #expect(Summarizer.promptDuration(ms: 125_000) == "2 分钟")
        #expect(Summarizer.promptDuration(ms: 3_600_000) == "1 小时")
        #expect(Summarizer.promptDuration(ms: 3_900_000) == "1 小时 5 分")
    }

    @Test func materialJoinsSegmentsByLine() {
        let transcript = Transcript(recordingId: UUID(), engine: "on-device", language: "zh-CN",
                                    segments: [TranscriptSegment(startMs: 0, text: "第一句。"),
                                               TranscriptSegment(startMs: 900, text: "第二句。")],
                                    createdAt: Date())
        #expect(Summarizer.material(from: transcript) == "第一句。\n第二句。")
    }

    @Test func promptKeepsTheRules() {
        let open = Summarizer.systemPrompt(fixedScene: nil)
        #expect(open.contains("只写录音里真有的内容"))
        #expect(open.contains("听不清的不要猜"))
        #expect(open.contains("全部用简体中文"))
        #expect(open.contains("先判断场景"))
        for scene in RecordingScene.allCases {
            #expect(open.contains("- \(scene.rawValue)（\(scene.name)）"))
        }
        #expect(Summarizer.systemPrompt(fixedScene: .sales).contains("场景已经确定是 sales"))
    }
}

struct SummarizerRequestTests {
    private let reply = #"{"scene": "meeting", "title": "周会", "summary": "下周三上线。", "todos": ["测试"]}"#

    @Test func shortTranscriptIsOneRequest() async throws {
        let log = RequestLog()
        let answer = reply
        let base = StubURLProtocol.register { request, body in
            log.append(request, body)
            return (200, chatReply(answer))
        }
        let summarizer = Summarizer(client: ChatClient(session: StubURLProtocol.session()))
        let config = ServiceConfig(baseURL: base, model: "m1", apiKey: "")
        let draft = try await summarizer.summarize(transcript: "各位，下周三上线。", durationMs: 125_000,
                                                   config: config, fixedScene: .meeting)
        #expect(draft.scene == .meeting && draft.summary == "下周三上线。" && draft.todos == ["测试"])
        #expect(draft.model == "m1")

        let entries = log.entries
        #expect(entries.count == 1)
        let json = try #require(entries.first?.json)
        #expect((json["response_format"] as? [String: Any])?["type"] as? String == "json_object")
        let messages = try #require(json["messages"] as? [[String: Any]])
        let system = try #require(messages.first?["content"] as? String)
        let user = try #require(messages.last?["content"] as? String)
        #expect(system.contains("场景已经确定是 meeting"))
        #expect(user.hasPrefix("录音时长：2 分钟"))
        #expect(user.contains("各位，下周三上线。"))
    }

    @Test func longTranscriptIsCompressedChunkByChunkFirst() async throws {
        let transcript = String(repeating: "这是一句用来测试长录音分段的话，没有别的意思。", count: 500)
        #expect(transcript.count > Summarizer.longTranscriptThreshold)
        let chunks = Summarizer.split(transcript, size: Summarizer.chunkSize).count
        #expect(chunks >= 2)

        let log = RequestLog()
        let answer = reply
        let base = StubURLProtocol.register { request, body in
            log.append(request, body)
            let wantsJSON = ((try? JSONSerialization.jsonObject(with: body)) as? [String: Any])?["response_format"] != nil
            return (200, chatReply(wantsJSON ? answer : "要点：下周三上线"))
        }
        let summarizer = Summarizer(client: ChatClient(session: StubURLProtocol.session()))
        let config = ServiceConfig(baseURL: base, model: "m1", apiKey: "")
        let draft = try await summarizer.summarize(transcript: transcript, durationMs: 3_600_000, config: config)
        #expect(draft.summary == "下周三上线。")

        let entries = log.entries
        #expect(entries.count == chunks + 1)
        for (i, entry) in entries.dropLast().enumerated() {
            let json = entry.json
            #expect(!json.keys.contains("response_format"))
            let messages = try #require(json["messages"] as? [[String: Any]])
            #expect((messages.first?["content"] as? String)?.contains("这是其中第 \(i + 1) 段") == true)
        }
        let last = try #require(entries.last?.json)
        #expect(last.keys.contains("response_format"))
        let messages = try #require(last["messages"] as? [[String: Any]])
        let user = try #require(messages.last?["content"] as? String)
        for i in 1...chunks {
            #expect(user.contains("【第 \(i) 段】\n要点：下周三上线"))
        }
        // The final request carries the notes, not the raw transcript.
        #expect(!user.contains(transcript))
    }

    @Test func incompleteConfigSendsNothing() async throws {
        let summarizer = Summarizer(client: ChatClient(session: StubURLProtocol.session()))
        await #expect(throws: AssistantError.notConfigured) {
            try await summarizer.summarize(transcript: "t", durationMs: 1000,
                                           config: ServiceConfig(baseURL: "", model: "", apiKey: ""))
        }
    }
}

struct KeyStoreTests {
    @Test func inMemoryStoreSavesReadsAndDeletes() throws {
        let store: any ServiceKeyStoring = InMemoryKeyStore()
        #expect(try store.read() == nil)
        try store.save("test-key-not-real")
        #expect(try store.read() == "test-key-not-real")
        try store.save("")
        #expect(try store.read() == nil)
        try store.save("again")
        try store.delete()
        #expect(try store.read() == nil)
        try store.delete()
    }
}
