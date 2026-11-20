import Foundation
import Testing
@testable import Assistant

struct ChatClientTests {
    @Test func sendsAnOpenAICompatibleRequest() async throws {
        let log = RequestLog()
        let base = StubURLProtocol.register { request, body in
            log.append(request, body)
            return (200, chatReply("<think>先想想</think>\n好的"))
        }
        let client = ChatClient(session: StubURLProtocol.session())
        let config = ServiceConfig(baseURL: base + "/", model: "test-model", apiKey: "test-key-not-real")

        let reply = try await client.complete(config, system: "系统", user: "用户", json: true)
        #expect(reply == "好的")

        let entry = try #require(log.entries.first)
        #expect(log.entries.count == 1)
        #expect(entry.request.httpMethod == "POST")
        #expect(entry.request.url?.path == "/v1/chat/completions")
        #expect(entry.request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key-not-real")
        #expect(entry.request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let json = entry.json
        #expect(json["model"] as? String == "test-model")
        #expect(json["temperature"] as? Double == 0.2)
        #expect((json["response_format"] as? [String: Any])?["type"] as? String == "json_object")
        let messages = try #require(json["messages"] as? [[String: Any]])
        #expect(messages.map { $0["role"] as? String } == ["system", "user"])
        #expect(messages.map { $0["content"] as? String } == ["系统", "用户"])
    }

    @Test func noKeyMeansNoAuthorizationAndNoJSONModeWhenNotAsked() async throws {
        let log = RequestLog()
        let base = StubURLProtocol.register { request, body in
            log.append(request, body)
            return (200, chatReply("要点"))
        }
        let client = ChatClient(session: StubURLProtocol.session())
        let config = ServiceConfig(baseURL: base, model: "local", apiKey: "  ")
        #expect(try await client.complete(config, system: "s", user: "u", json: false) == "要点")
        let entry = try #require(log.entries.first)
        #expect(entry.request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(!entry.json.keys.contains("response_format"))
    }

    @Test func httpErrorsCarryStatusAndBody() async throws {
        let base = StubURLProtocol.register { _, _ in (401, Data(#"{"error":"invalid key"}"#.utf8)) }
        let client = ChatClient(session: StubURLProtocol.session())
        let config = ServiceConfig(baseURL: base, model: "m", apiKey: "wrong")
        await #expect(throws: AssistantError.http(401, #"{"error":"invalid key"}"#)) {
            try await client.complete(config, system: "s", user: "u", json: true)
        }
    }

    @Test func replyWithoutChoicesIsBadReply() async throws {
        let base = StubURLProtocol.register { _, _ in (200, Data(#"{"choices":[]}"#.utf8)) }
        let client = ChatClient(session: StubURLProtocol.session())
        let config = ServiceConfig(baseURL: base, model: "m", apiKey: "")
        do {
            _ = try await client.complete(config, system: "s", user: "u", json: false)
            Issue.record("expected badReply")
        } catch let error as AssistantError {
            guard case .badReply = error else {
                Issue.record("expected badReply, got \(error)")
                return
            }
        }
    }

    @Test func unknownHostIsUnreachable() async throws {
        let client = ChatClient(session: StubURLProtocol.session())
        let config = ServiceConfig(baseURL: "https://nobody.stub.test/v1", model: "m", apiKey: "")
        do {
            _ = try await client.complete(config, system: "s", user: "u", json: false)
            Issue.record("expected unreachable")
        } catch let error as AssistantError {
            guard case .unreachable = error else {
                Issue.record("expected unreachable, got \(error)")
                return
            }
        }
    }

    /// No connection (or 无线数据 turned off for 闻笺) is advice, not a raw system error, on both
    /// the whole-reply and the streamed path.
    @Test func noConnectionIsOffline() async throws {
        let client = ChatClient(session: StubURLProtocol.session())
        let config = ServiceConfig(baseURL: StubURLProtocol.offlineBase, model: "m", apiKey: "")
        await #expect(throws: AssistantError.offline) {
            try await client.complete(config, system: "s", user: "u", json: false)
        }
        await #expect(throws: AssistantError.offline) {
            for try await _ in client.stream(config, system: "s", user: "u") {}
        }
        #expect(AssistantError.offline.errorDescription == AssistantError.offlineAdvice)
        #expect(AssistantError.offlineAdvice.contains("无线数据"))
    }

    @Test func onlyConnectionErrorsCountAsOffline() {
        for code in [URLError.Code.notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff] {
            #expect(AssistantError.network(URLError(code)) == .offline)
        }
        for code in [URLError.Code.cannotConnectToHost, .timedOut, .cannotFindHost, .secureConnectionFailed] {
            guard case .unreachable = AssistantError.network(URLError(code)) else {
                Issue.record("\(code) should stay unreachable")
                continue
            }
        }
    }

    @Test func incompleteConfigIsNotConfigured() async throws {
        let client = ChatClient(session: StubURLProtocol.session())
        for config in [ServiceConfig(baseURL: "", model: "m", apiKey: ""),
                       ServiceConfig(baseURL: "https://api.example.com/v1", model: " ", apiKey: ""),
                       ServiceConfig(baseURL: "api.example.com/v1", model: "m", apiKey: "")] {
            await #expect(throws: AssistantError.notConfigured) {
                try await client.complete(config, system: "s", user: "u", json: false)
            }
        }
    }

    @Test func endpointAppendsThePath() {
        #expect(ChatClient.endpoint("https://api.deepseek.com/v1/")?.absoluteString
            == "https://api.deepseek.com/v1/chat/completions")
        #expect(ChatClient.endpoint(" http://192.168.1.5:11434/v1 ")?.absoluteString
            == "http://192.168.1.5:11434/v1/chat/completions")
        #expect(ChatClient.endpoint("ftp://example.com") == nil)
    }

    @Test func stripThinkingRemovesEveryClosedBlock() {
        #expect(ChatClient.stripThinking("<think>a</think>答<think>b\nc</think>案 ") == "答案")
        #expect(ChatClient.stripThinking("没有思考") == "没有思考")
        #expect(ChatClient.stripThinking("<think>没闭合") == "<think>没闭合")
    }

    @Test func descriptionNeverShowsTheKey() {
        let config = ServiceConfig(baseURL: "https://api.example.com/v1", model: "m", apiKey: "secret-value")
        #expect(!config.description.contains("secret-value"))
        #expect(!"\(config)".contains("secret-value"))
    }

    @Test func presetsAreUsableAddresses() {
        #expect(!ServiceConfig.presets.isEmpty)
        for preset in ServicePreset.chat + ServicePreset.transcription {
            #expect(ChatClient.endpoint(preset.baseURL)?.scheme == "https", "\(preset.name)")
        }
        #expect(Set(ServicePreset.chat.map(\.baseURL)).count == ServicePreset.chat.count)
    }
}
