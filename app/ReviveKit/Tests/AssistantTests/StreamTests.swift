import Foundation
import Testing
@testable import Assistant

/// G3 "SSE 流式": replies read piece by piece, and services that do not stream.
struct StreamTests {
    private func event(_ content: String) -> String {
        let object: [String: Any] = ["choices": [["index": 0, "delta": ["content": content]]]]
        let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        return "data: " + String(decoding: data, as: UTF8.self)
    }

    @Test func readerTakesDeltasUntilDone() throws {
        var reader = StreamReader()
        #expect(try reader.feed(": keep-alive") == nil)
        #expect(try reader.feed(event("你")) == "你")
        #expect(try reader.feed("") == nil)
        #expect(try reader.feed(#"data: {"choices":[{"delta":{"role":"assistant"}}]}"#) == nil)
        #expect(try reader.feed(event("好")) == "好")
        #expect(try reader.feed("data: [DONE]") == nil)
        #expect(reader.isDone)
        #expect(try reader.finish() == nil)
    }

    /// v105 device acceptance: with the network gone the stream just stopped, and the page said
    /// 「完成」. A stream that ends without `[DONE]` or a `finish_reason` is cut off.
    @Test func streamWithoutAnEndIsCutOff() throws {
        var cut = StreamReader()
        #expect(try cut.feed(event("第一段")) == "第一段")
        #expect(throws: ChatClient.cutOff) { try cut.finish() }

        var finished = StreamReader()
        _ = try finished.feed(event("全文"))
        _ = try finished.feed(#"data: {"choices":[{"delta":{},"finish_reason":"stop"}]}"#)
        #expect(try finished.finish() == nil)
    }

    @Test func readerReportsAnErrorEvent() {
        var reader = StreamReader()
        #expect(throws: AssistantError.badReply("rate limited")) {
            try reader.feed(#"data: {"error":{"message":"rate limited"}}"#)
        }
    }

    /// A service that ignores `stream` answers with one ordinary JSON body.
    @Test func readerFallsBackToAWholeReply() throws {
        var reader = StreamReader()
        let body = String(decoding: chatReply("整段回答"), as: UTF8.self)
        for line in body.split(separator: "\n", omittingEmptySubsequences: false) {
            #expect(try reader.feed(String(line)) == nil)
        }
        #expect(try reader.finish() == "整段回答")
        var junk = StreamReader()
        _ = try junk.feed("<html>")
        #expect(throws: AssistantError.self) { try junk.finish() }
    }

    @Test func visibleTextHidesThinking() {
        #expect(ChatClient.visibleText("<think>想</think>\n答案") == "答案")
        #expect(ChatClient.visibleText("开头<think>还在想") == "开头")
        #expect(ChatClient.visibleText("<think>还在想") == "")
    }

    @Test func streamsPiecesAndAsksForAStream() async throws {
        let log = RequestLog()
        let lines = [event("<think>嗯"), event("</think>周三"), event("发布。"), "data: [DONE]", "", event("多余")]
        let base = StubURLProtocol.register { request, body in
            log.append(request, body)
            return (200, Data((lines.joined(separator: "\n") + "\n").utf8))
        }
        let client = ChatClient(session: StubURLProtocol.session())
        let config = ServiceConfig(baseURL: base, model: "m", apiKey: "")
        var pieces: [String] = []
        for try await piece in client.stream(config, system: "系统", user: "用户") { pieces.append(piece) }
        #expect(pieces == ["<think>嗯", "</think>周三", "发布。"])
        #expect(ChatClient.visibleText(pieces.joined()) == "周三发布。")
        let entry = try #require(log.entries.first)
        #expect(entry.json["stream"] as? Bool == true)
        #expect(entry.json["response_format"] == nil)
        #expect(entry.request.value(forHTTPHeaderField: "Accept") == "text/event-stream")
        // A silent stream gives up after a minute, not the whole-request timeout.
        #expect(entry.request.timeoutInterval == ChatClient.streamIdleTimeout)
    }

    @Test func streamThatStopsEarlyThrows() async throws {
        let base = StubURLProtocol.register { _, _ in (200, Data((event("一半") + "\n").utf8)) }
        let client = ChatClient(session: StubURLProtocol.session())
        var pieces: [String] = []
        await #expect(throws: ChatClient.cutOff) {
            for try await piece in client.stream(ServiceConfig(baseURL: base, model: "m", apiKey: ""), system: "s",
                                                 user: "u") {
                pieces.append(piece)
            }
        }
        #expect(pieces == ["一半"])
    }

    @Test func streamFallsBackAndReportsErrors() async throws {
        let whole = StubURLProtocol.register { _, _ in (200, chatReply("一次给完")) }
        let client = ChatClient(session: StubURLProtocol.session())
        var pieces: [String] = []
        for try await piece in client.stream(ServiceConfig(baseURL: whole, model: "m", apiKey: ""), system: "s", user: "u") {
            pieces.append(piece)
        }
        #expect(pieces == ["一次给完"])

        let denied = StubURLProtocol.register { _, _ in (401, Data(#"{"error":"bad key"}"#.utf8)) }
        await #expect(throws: AssistantError.http(401, #"{"error":"bad key"}"#)) {
            for try await _ in client.stream(ServiceConfig(baseURL: denied, model: "m", apiKey: ""), system: "s", user: "u") {}
        }
        await #expect(throws: AssistantError.notConfigured) {
            for try await _ in client.stream(ServiceConfig(baseURL: "", model: "", apiKey: ""), system: "s", user: "u") {}
        }
    }
}
