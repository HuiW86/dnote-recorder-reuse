import Foundation
import Library
import Testing
@testable import Assistant

/// X20 单词分级: words worth learning in a foreign-language transcript, with CEFR levels.
struct WordGraderTests {
    @Test func levelsAreReadLoosely() {
        #expect(WordLevel(loosely: " b2 ") == .b2)
        #expect(WordLevel(loosely: "C1 高级") == .c1)
        #expect(WordLevel(loosely: "advanced") == nil)
        #expect(WordLevel.a1 < .c2 && WordLevel.b2 > .b1)
    }

    @Test func foreignMeansMostlyLatinLetters() {
        #expect(WordGrader.isForeign(["Let's ship the release on Wednesday after the tests pass."]))
        #expect(!WordGrader.isForeign(["我们周三发布，测试通过以后就上线。", "OK"]))
        #expect(!WordGrader.isForeign(["Hi"]))  // too little to judge
    }

    @Test func parseDropsWhatItCannotUse() {
        let reply: String = [
            #"<think>…</think>{"words":[{"word":" mitigate ","level":"C1","meaning":"缓解","line":2},"#,
            #"{"word":"","level":"B2","line":1},{"word":"ship","level":"??","line":1},{"word":"x","level":"B1","line":9},"#,
            #"{"word":"rollout","level":"b2","meaning":"上线","line":"1"}]}"#,
        ].joined()
        let words = WordGrader.parse(reply, lineCount: 2)
        #expect(words == [StudyWord(word: "mitigate", level: .c1, meaning: "缓解", segmentIndex: 1),
                          StudyWord(word: "rollout", level: .b2, meaning: "上线", segmentIndex: 0)])
        #expect(WordGrader.parse("没有 JSON", lineCount: 2) == nil)
        #expect(WordGrader.parse(#"{"items":[]}"#, lineCount: 2) == nil)
    }

    /// Only lines with Latin letters are sent, numbered within the batch; words come back placed
    /// on the transcript's own lines, each word once, in transcript order.
    @Test func gradeSendsForeignLinesAndPlacesWords() async throws {
        let log = RequestLog()
        let base = StubURLProtocol.register { request, body in
            log.append(request, body)
            let reply: String = [
                #"{"words":[{"word":"Mitigate","level":"C1","meaning":"缓解","line":2},"#,
                #"{"word":"rollout","level":"B2","meaning":"上线","line":1},"#,
                #"{"word":"mitigate","level":"C1","meaning":"重复","line":1}]}"#,
            ].joined()
            return (200, chatReply(reply))
        }
        let grader = WordGrader(client: ChatClient(session: StubURLProtocol.session()))
        let config = ServiceConfig(baseURL: base, model: "m", apiKey: "")
        let lines = ["大家好。", "The rollout is next week.", "嗯", "We need to mitigate the risk."]
        let words = try await grader.grade(lines, config: config)
        #expect(words.map(\.word) == ["rollout", "Mitigate"])
        #expect(words.map(\.segmentIndex) == [1, 3])
        let entry = try #require(log.entries.first)
        #expect(log.entries.count == 1)
        let messages = try #require(entry.json["messages"] as? [[String: Any]])
        #expect(messages.last?["content"] as? String == "1. The rollout is next week.\n2. We need to mitigate the risk.")
        #expect((entry.json["response_format"] as? [String: Any])?["type"] as? String == "json_object")

        #expect(try await grader.grade(["只有中文。"], config: config).isEmpty)
        let junk = StubURLProtocol.register { _, _ in (200, chatReply("看不懂")) }
        await #expect(throws: AssistantError.badReply("没有读出生词")) {
            try await grader.grade(["Hello there, friend."], config: ServiceConfig(baseURL: junk, model: "m", apiKey: ""))
        }
    }
}
