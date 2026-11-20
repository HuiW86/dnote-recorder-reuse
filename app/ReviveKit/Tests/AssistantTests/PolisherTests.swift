import Foundation
import Testing
@testable import Assistant

/// 逐句润色 (#75): one polished line per input line, or the batch is left alone.
struct PolisherTests {
    @Test func parseKeepsTheCountAndDropsEchoedNumbers() {
        let input = ["嗯那个我们下周三上线", "1. 预算先不动", "啊"]
        let reply = #"<think>想想</think>{"lines": ["1. 我们下周三上线。", " 1. 预算先不动。 ", "3、啊"]}"#
        #expect(Polisher.parse(reply, lines: input) == ["我们下周三上线。", "1. 预算先不动。", "啊"])
        #expect(Polisher.parse(#"{"lines": ["只有一句"]}"#, lines: input) == nil)
        #expect(Polisher.parse(#"{"text": "x"}"#, lines: ["x"]) == nil)
        #expect(Polisher.parse("不是 JSON", lines: ["x"]) == nil)
        // A non-string entry keeps that line (empty means unchanged).
        #expect(Polisher.parse(#"{"lines": [3]}"#, lines: ["x"]) == [""])
    }

    @Test func promptKeepsTheRules() {
        #expect(Polisher.systemPrompt.contains("不合并、不拆分、不调换句子"))
        #expect(Polisher.systemPrompt.contains("条数必须和输入的行数相同"))
        #expect(Polisher.numbered(["甲", "乙"]) == "1. 甲\n2. 乙")
    }

    /// Lines go out in batches; a batch whose reply does not line up is left as it was.
    @Test func batchesAndKeepsAMismatchedBatch() async throws {
        let lines = (1...(Polisher.batchSize + 3)).map { "嗯第\($0)句" }
        let log = RequestLog()
        let base = StubURLProtocol.register { request, body in
            log.append(request, body)
            let messages = (try? JSONSerialization.jsonObject(with: body) as? [String: Any])?["messages"]
                as? [[String: Any]]
            let user = messages?.last?["content"] as? String ?? ""
            let count = user.split(separator: "\n").count
            // The first batch lines up; the second answers one line short.
            let reply = count == Polisher.batchSize
                ? (1...count).map { "\"第\($0)句。\"" }
                : ["\"少了\""]
            return (200, chatReply(#"{"lines": ["# + reply.joined(separator: ",") + "]}"))
        }
        let polisher = Polisher(client: ChatClient(session: StubURLProtocol.session()))
        let config = ServiceConfig(baseURL: base, model: "m", apiKey: "")
        let result = try await polisher.polish(lines, config: config)
        #expect(result.texts.count == lines.count)
        #expect(result.texts.first == "第1句。")
        #expect(result.texts.suffix(3) == ["", "", ""])
        #expect(result.unchangedLines == 3)
        let entries = log.entries
        #expect(entries.count == 2)
        #expect((entries.first?.json["response_format"] as? [String: Any])?["type"] as? String == "json_object")
    }

    @Test func nothingLinesUpIsBadReply() async throws {
        let base = StubURLProtocol.register { _, _ in (200, chatReply(#"{"lines": []}"#)) }
        let polisher = Polisher(client: ChatClient(session: StubURLProtocol.session()))
        await #expect(throws: AssistantError.badReply("润色后的句数对不上")) {
            try await polisher.polish(["一", "二"], config: ServiceConfig(baseURL: base, model: "m", apiKey: ""))
        }
        // No lines, no requests.
        let empty = try await polisher.polish([], config: ServiceConfig(baseURL: base, model: "m", apiKey: ""))
        #expect(empty == PolishResult(texts: [], unchangedLines: 0))
        await #expect(throws: AssistantError.notConfigured) {
            try await polisher.polish(["一"], config: ServiceConfig(baseURL: "", model: "", apiKey: ""))
        }
    }
}
