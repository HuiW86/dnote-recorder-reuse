import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import Account

// 纪要、换角度重起标题、用量 with the 闻笺 account (test-spec.md T-M2-49), against the stub server.

private let recordingId = UUID(uuidString: "0c1d2e3f-0000-4000-8000-0000000000aa")!

private func signedInSession(_ stub: StubTransport) async throws -> AccountSession {
    let clock = TestClock()
    let session = AccountSession(client: AccountClient(baseURL: base, transport: stub), store: InMemorySessionStore(),
                                 now: { clock.now })
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    try await session.adopt(try decoder.decode(AccountTokens.self, from: Data(tokens(1).utf8)))
    return session
}

private func body(_ request: URLRequest) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]) ?? [:]
}

private func task(_ kind: String, _ status: String, result: String = "null") -> String {
    #"{"id":"0c1d2e3f-0000-4000-8000-0000000000bb","kind":"\#(kind)","recording_id":"0c1d2e3f-0000-4000-8000-0000000000aa","status":"\#(status)","attempts":1,"error":null,"result":\#(result),"created_at":"2026-11-27T15:00:00+00:00","updated_at":"2026-11-27T15:00:00+00:00","finished_at":null}"#
}

struct AccountSummaryTests {
    @Test func summarizingSendsTheSceneAndProfession() async throws {
        let stub = StubTransport([.json(202, task("summarize", "queued")), .json(202, task("summarize", "queued"))])
        let session = try await signedInSession(stub)
        let started = try await session.summarize(recordingId: recordingId, templateId: "meeting",
                                                  profession: "产品经理", idempotencyKey: "sum-1")
        #expect(started.kind == "summarize" && started.status == .queued && started.result == nil)
        let first = stub.requests[0]
        #expect(first.httpMethod == "POST" && first.url!.path == "/v1/recordings/\(AccountClient.id(recordingId))/summaries")
        #expect(body(first)["template_id"] as? String == "meeting" && body(first)["profession"] as? String == "产品经理")
        #expect(first.value(forHTTPHeaderField: "Idempotency-Key") == "sum-1")
        // No scene: the model chooses, and the field is left out.
        _ = try await session.summarize(recordingId: recordingId, templateId: nil, profession: "", idempotencyKey: "sum-2")
        #expect(body(stub.requests[1])["template_id"] == nil)
    }

    @Test func summariesReadEveryField() async throws {
        let summary = #"[{"id":"0c1d2e3f-0000-4000-8000-0000000000cc","recording_id":"0c1d2e3f-0000-4000-8000-0000000000aa","scene":"meeting","title":"周会","summary":"定了上线时间","sections":[{"heading":"决定","items":["周五上线"]}],"todos":["写发布说明"],"tags":["发布"],"people":["王老师"],"outline":[{"title":"上线","points":["周五"]}],"quotes":["先上再说"],"model":"stand-in","created_at":"2026-11-27T15:00:00+00:00"}]"#
        let stub = StubTransport([.json(200, summary)])
        let session = try await signedInSession(stub)
        let summaries = try await session.summaries(recordingId: recordingId)
        let first = try #require(summaries.first)
        #expect(first.title == "周会" && first.scene == "meeting" && first.summary == "定了上线时间")
        #expect(first.sections == [RemoteSummary.Section(heading: "决定", items: ["周五上线"])])
        #expect(first.todos == ["写发布说明"] && first.tags == ["发布"] && first.people == ["王老师"])
        #expect(first.outline.first?.points == ["周五"] && first.quotes == ["先上再说"] && first.model == "stand-in")
        #expect(stub.requests[0].httpMethod == "GET")
    }

    /// The new title comes back on the finished task (`result.title`).
    @Test func retitleAnswersOnTheTask() async throws {
        let stub = StubTransport([
            .json(202, task("retitle", "queued")),
            .json(200, task("retitle", "succeeded", result: #"{"title":"周五上线的决定","model":"stand-in"}"#)),
        ])
        let session = try await signedInSession(stub)
        let started = try await session.retitle(recordingId: recordingId, currentTitle: "周会", idempotencyKey: "rt-1")
        #expect(body(stub.requests[0])["current_title"] as? String == "周会")
        let done = try await session.waitForTask(started.id) { _ in }
        #expect(done.result?.title == "周五上线的决定")
    }

    @Test func templatesAndUsage() async throws {
        let templates = #"[{"id":"meeting","name":"会议","definition":"多人讨论并做决定","headings":["决定","待办"],"is_builtin":true}]"#
        let usage = #"{"period_start":"2026-11-01T00:00:00+08:00","period_end":"2026-12-01T00:00:00+08:00","asr_seconds":{"used":600,"reserved":120,"limit":36000,"remaining":35280},"llm_tokens":{"used":5000,"limit":null,"remaining":null}}"#
        let stub = StubTransport([.json(200, templates), .json(200, usage)])
        let session = try await signedInSession(stub)
        #expect(try await session.templates() == [SummaryTemplate(id: "meeting", name: "会议", definition: "多人讨论并做决定",
                                                                   headings: ["决定", "待办"])])
        let used = try await session.usage()
        #expect(used.asrSeconds.used == 600 && used.asrSeconds.reserved == 120 && used.asrSeconds.remaining == 35_280)
        #expect(used.llmTokens.limit == nil && used.llmTokens.remaining == nil && used.llmTokens.reserved == nil)
        #expect(used.periodStart.hasPrefix("2026-11-01"))
        #expect(stub.requests.map(\.url!.path) == ["/v1/templates", "/v1/me/usage"])
    }
}
