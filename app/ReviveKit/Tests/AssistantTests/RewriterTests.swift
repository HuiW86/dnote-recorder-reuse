import Foundation
import Library
import Testing
@testable import Assistant

// X15 rewrite and G3 single-recording questions.
struct RewriterTests {
    @Test func materialPutsSummaryFirstAndIsCapped() {
        let id = UUID()
        let summary = Summary(recordingId: id, scene: "meeting", title: "t", summary: "周三发布。",
                              sections: [SummarySection(heading: "结论", items: ["下周三"]),
                                         SummarySection(heading: "空", items: [])],
                              todos: [], tags: [], people: [], model: "m", createdAt: Date())
        let transcript = Transcript(recordingId: id, engine: "t", language: "zh-CN",
                                    segments: [TranscriptSegment(startMs: 0, text: "那就下周三。")], createdAt: Date())
        let text = Rewriter.material(summary: summary, transcript: transcript)
        #expect(text.hasPrefix("【纪要】\n周三发布。\n结论：\n- 下周三\n\n【文字稿】\n"))
        #expect(!text.contains("空："))
        #expect(Rewriter.material(summary: nil, transcript: nil).isEmpty)
        let long = Transcript(recordingId: id, engine: "t", language: "zh-CN",
                              segments: [TranscriptSegment(startMs: 0, text: String(repeating: "字", count: 30_000))],
                              createdAt: Date())
        #expect(Rewriter.material(summary: nil, transcript: long).count == Rewriter.maxMaterial)
    }

    @Test func rewriteAndAnswerSendTheRightPrompts() async throws {
        let log = RequestLog()
        let base = StubURLProtocol.register { request, body in
            log.append(request, body)
            return (200, chatReply("<think>x</think>成品"))
        }
        let rewriter = Rewriter(client: ChatClient(session: StubURLProtocol.session()))
        let config = ServiceConfig(baseURL: base, model: "m", apiKey: "")
        #expect(try await rewriter.rewrite(material: "材料", style: .email, extra: "给张总", config: config) == "成品")
        #expect(try await rewriter.answer(question: "几号发布？", material: "材料", config: config) == "成品")

        let messages = log.entries.map { ($0.json["messages"] as? [[String: String]]) ?? [] }
        #expect(messages.count == 2)
        #expect(messages[0][0]["content"]?.contains(RewriteStyle.email.instruction) == true)
        #expect(messages[0][0]["content"]?.contains("补充要求：给张总") == true)
        #expect(messages[0][1]["content"] == "材料")
        #expect(messages[1][0]["content"]?.contains("没有记录到") == true)
        #expect(messages[1][1]["content"] == "材料：\n材料\n\n问题：几号发布？")
        #expect(log.entries.allSatisfy { $0.json["response_format"] == nil })  // plain text, not JSON

        // G3: the streamed versions send the same prompts, asking for a stream.
        var streamed = ""
        for try await piece in rewriter.answerStream(question: "几号发布？", material: "材料", config: config) {
            streamed += piece
        }
        #expect(ChatClient.visibleText(streamed) == "成品")
        let last = try #require(log.entries.last?.json)
        #expect(last["stream"] as? Bool == true)
        #expect((last["messages"] as? [[String: String]])?[1]["content"] == "材料：\n材料\n\n问题：几号发布？")
        for try await _ in rewriter.rewriteStream(material: "材料", style: .email, config: config) {}
        #expect((log.entries.last?.json["messages"] as? [[String: String]])?[0]["content"]?
            .contains(RewriteStyle.email.instruction) == true)
    }
}
