import Foundation
import Testing
@testable import Assistant

// G3 全局对话: one question across the latest summaries, answered with numbered citations.
struct LibraryAskerTests {
    private func source(_ n: Int, _ text: String) -> LibrarySource {
        LibrarySource(id: UUID(), label: "录音\(n)", date: "11月\(n)日 09:00", text: text)
    }

    @Test func citationsAreKnownNumbersInOrderOfFirstUse() {
        #expect(LibraryAsker.citations(in: "周三上线 [2]。测试由老王负责 [1][2]，另见 [1，3] 和 [9]、[x]。", count: 3)
            == [2, 1, 3])
        #expect(LibraryAsker.citations(in: "没有记录到。", count: 3).isEmpty)
        #expect(LibraryAsker.citations(in: "未闭合 [1", count: 3).isEmpty)
    }

    @Test func materialIsNumberedAndStopsAtTheLimit() {
        let short = LibraryAsker.material([source(1, "周三上线"), source(2, "老王测试")])
        #expect(short.used == 2)
        #expect(short.text == "[1] 录音1（11月1日 09:00）\n周三上线\n\n[2] 录音2（11月2日 09:00）\n老王测试")

        let big = String(repeating: "长", count: LibraryAsker.maxMaterial - 100)
        let capped = LibraryAsker.material([source(1, big), source(2, big), source(3, "短")])
        #expect(capped.used == 1)  // newest first; the rest do not fit
        let huge = LibraryAsker.material([source(1, big + big)])
        #expect(huge.used == 1 && huge.text.count == LibraryAsker.maxMaterial)  // one is always sent, cut
    }

    @Test func answersWithItsCitationsAndSendsOnlySummaries() async throws {
        let log = RequestLog()
        let base = StubURLProtocol.register { request, body in
            log.append(request, body)
            return (200, chatReply("<think>先看纪要</think>下周三上线 [2]。"))
        }
        let asker = LibraryAsker(client: ChatClient(session: StubURLProtocol.session()))
        let config = ServiceConfig(baseURL: base, model: "m", apiKey: "k")
        let answer = try await asker.answer(question: "什么时候上线？",
                                            sources: [source(1, "灵感"), source(2, "周三上线")], config: config)
        #expect(answer == LibraryAnswer(text: "下周三上线 [2]。", cited: [2]))
        let messages = try #require(log.entries.first?.json["messages"] as? [[String: Any]])
        let user = try #require(messages.last?["content"] as? String)
        #expect(user.hasPrefix("纪要：\n[1] 录音1") && user.hasSuffix("问题：什么时候上线？"))

        await #expect(throws: AssistantError.badReply("没有可以参考的纪要")) {
            try await asker.answer(question: "q", sources: [], config: config)
        }
        await #expect(throws: AssistantError.notConfigured) {
            try await asker.answer(question: "q", sources: [source(1, "x")],
                                   config: ServiceConfig(baseURL: "", model: "", apiKey: ""))
        }

        // G3 "SSE 流式": the same message, asked as a stream; citations read from the whole text.
        let streamed = try asker.answerStream(question: "什么时候上线？",
                                              sources: [source(1, "灵感"), source(2, "周三上线")], config: config)
        #expect(streamed.used == 2)
        var raw = ""
        for try await piece in streamed.pieces { raw += piece }
        let text = ChatClient.visibleText(raw)
        #expect(text == "下周三上线 [2]。")
        #expect(LibraryAsker.citations(in: text, count: streamed.used) == [2])
        let last = try #require(log.entries.last?.json)
        #expect(last["stream"] as? Bool == true)
        #expect((last["messages"] as? [[String: Any]])?.last?["content"] as? String == user)
        #expect(throws: AssistantError.badReply("没有可以参考的纪要")) {
            _ = try asker.answerStream(question: "q", sources: [], config: config)
        }
    }
}
