import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import Account

// Transcribing and summarizing a local recording with the 闻笺 account end to end
// (test-spec.md T-M2-51, product-spec.md §7.3b), against the stub server.

private let local = UUID(uuidString: "11111111-0000-4000-8000-000000000001")!
private let account = UUID(uuidString: "6f1c2d3e-0000-4000-8000-000000000001")!  // userJSON's id
private let serverA = "0c1d2e3f-0000-4000-8000-0000000000aa"
private let serverB = "0c1d2e3f-0000-4000-8000-0000000000ab"
private let taskId = "0c1d2e3f-0000-4000-8000-0000000000bb"

private func recording(_ id: String, audio: Bool) -> String {
    let audioJSON = audio
        ? #"{"sha256":"\#(String(repeating: "a", count: 64))","size":10,"content_type":"audio/ogg","uploaded":true}"#
        : "null"
    return #"{"id":"\#(id)","source":"card","started_at":"2026-11-27T08:12:41+00:00","duration_ms":60000,"title":"周会","device_sn_hash":null,"audio":\#(audioJSON),"version":1,"created_at":"2026-11-27T15:00:00+00:00","updated_at":"2026-11-27T15:00:00+00:00","upload":null}"#
}

private func task(_ kind: String, _ status: String, on server: String = serverA) -> String {
    #"{"id":"\#(taskId)","kind":"\#(kind)","recording_id":"\#(server)","status":"\#(status)","attempts":1,"error":null,"result":null,"created_at":"2026-11-27T15:00:00+00:00","updated_at":"2026-11-27T15:00:00+00:00","finished_at":null}"#
}

private func transcript(_ server: String, provider: String = "stand-in") -> String {
    #"{"recording_id":"\#(server)","language":"zh","segments":[{"start_ms":0,"end_ms":1500,"speaker":"S1","text":"大家好"}],"speakers":{},"asr_provider":"\#(provider)","created_at":"2026-11-27T15:00:00+00:00","updated_at":"2026-11-27T15:00:00+00:00"}"#
}

private func summaries(_ server: String) -> String {
    #"[{"id":"0c1d2e3f-0000-4000-8000-0000000000cc","recording_id":"\#(server)","scene":"meeting","title":"周会","summary":"定了上线时间","sections":[],"todos":["写发布说明"],"tags":[],"people":[],"outline":[],"quotes":[],"model":"stand-in","created_at":"2026-11-27T15:00:00+00:00"}]"#
}

private let new = NewRecording(source: .card, startedAt: Date(timeIntervalSince1970: 1_795_000_000), durationMs: 60_000,
                               title: "周会", sha256: String(repeating: "a", count: 64), size: 10, contentType: "audio/ogg")
private let details = RecordingDetails(source: .card, startedAt: Date(timeIntervalSince1970: 1_795_000_000),
                                       durationMs: 60_000, title: "周会")
private let lines = [TranscriptLine(startMs: 0, endMs: 1_500, text: "大家好"),
                     TranscriptLine(startMs: 1_500, endMs: 60_000, speaker: "S1", text: "开始吧")]

/// The library's table, in memory.
private actor Ids: ServerRecordingIds {
    var kept: [UUID: [UUID: ServerRecordingId]] = [:]
    var forgotten = 0

    init(_ start: ServerRecordingId? = nil) {
        if let start { kept[account] = [local: start] }
    }

    func serverId(local: UUID, account: UUID) -> ServerRecordingId? { kept[account]?[local] }
    func keep(_ server: ServerRecordingId, local: UUID, account: UUID) { kept[account, default: [:]][local] = server }
    func forget(local: UUID, account: UUID) {
        kept[account]?[local] = nil
        forgotten += 1
    }
    func current() -> ServerRecordingId? { kept[account]?[local] }
}

private func signedIn(_ stub: StubTransport) async throws -> AccountSession {
    let clock = TestClock()
    let session = AccountSession(client: AccountClient(baseURL: base, transport: stub), store: InMemorySessionStore(),
                                 now: { clock.now })
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    try await session.adopt(try decoder.decode(AccountTokens.self, from: Data(tokens(1).utf8)))
    return session
}

private func json(_ request: URLRequest) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]) ?? [:]
}

private func route(_ request: URLRequest) -> String { "\(request.httpMethod ?? "") \(request.url!.path)" }

struct AccountWorkTests {
    /// The audio the server already has is one request; its id is kept with the audio, replacing
    /// a text-only one, and the transcript comes back.
    @Test func transcribingKeepsTheServerIdWithAudio() async throws {
        let stub = StubTransport([
            .json(200, recording(serverA, audio: true)),
            .json(202, task("transcribe", "queued")),
            .json(200, task("transcribe", "succeeded")),
            .json(200, transcript(serverA)),
        ])
        let session = try await signedIn(stub)
        let ids = Ids(ServerRecordingId(id: UUID(uuidString: serverB)!, hasAudio: false))
        let result = try await session.transcribeRecording(local: local, new, audio: Data("0123456789".utf8),
                                                           language: "zh-CN", ids: ids, sleep: { _ in })
        #expect(result.segments.map(\.text) == ["大家好"])
        #expect(await ids.current() == ServerRecordingId(id: UUID(uuidString: serverA)!, hasAudio: true))
        #expect(stub.requests.map(route) == [
            "POST /v1/recordings", "POST /v1/recordings/\(serverA)/transcribe", "GET /v1/tasks/\(taskId)",
            "GET /v1/recordings/\(serverA)/transcript",
        ])
        #expect(json(stub.requests[1])["language"] as? String == "zh-CN")
    }

    /// No server recording yet: one without audio (the key names the local recording, so a retry
    /// after a lost answer makes no second one), then the text, then the summary.
    @Test func aSummarySendsOnlyTheText() async throws {
        let stub = StubTransport([
            .json(201, recording(serverA, audio: false)),
            .json(200, transcript(serverA, provider: "app:on-device")),
            .json(202, task("summarize", "queued")),
            .json(200, task("summarize", "succeeded")),
            .json(200, summaries(serverA)),
        ])
        let session = try await signedIn(stub)
        let ids = Ids()
        let summary = try await session.summarizeText(local: local, details, lines: lines, engine: "on-device",
                                                      language: "zh-CN", templateId: "meeting", profession: "产品经理",
                                                      ids: ids) { _ in }
        #expect(summary.title == "周会" && summary.todos == ["写发布说明"])
        #expect(await ids.current() == ServerRecordingId(id: UUID(uuidString: serverA)!, hasAudio: false))
        #expect(stub.requests.map(route) == [
            "POST /v1/recordings", "PUT /v1/recordings/\(serverA)/transcript", "POST /v1/recordings/\(serverA)/summaries",
            "GET /v1/tasks/\(taskId)", "GET /v1/recordings/\(serverA)/summaries",
        ])
        let create = json(stub.requests[0])
        #expect(create["audio"] == nil && create["title"] as? String == "周会" && create["duration_ms"] as? Int == 60_000)
        #expect(stub.requests[0].value(forHTTPHeaderField: "Idempotency-Key") == "text-\(local.uuidString.lowercased())")
        let put = json(stub.requests[1])
        #expect(put["engine"] as? String == "on-device" && put["language"] as? String == "zh-CN")
        let segments = try #require(put["segments"] as? [[String: Any]])
        #expect(segments.count == 2 && segments[0]["speaker"] == nil && segments[1]["speaker"] as? String == "S1")
        #expect(segments[1]["start_ms"] as? Int == 1_500 && segments[1]["end_ms"] as? Int == 60_000)
        #expect(stub.requests[1].value(forHTTPHeaderField: "Authorization") == "Bearer a1")
        #expect(json(stub.requests[2])["template_id"] as? String == "meeting")
    }

    /// A kept recording (here with audio) is used as it is: no new recording, no audio again.
    @Test func aKeptRecordingIsUsed() async throws {
        let stub = StubTransport([
            .json(200, transcript(serverA, provider: "app:own-service")),
            .json(202, task("summarize", "queued")),
            .json(200, task("summarize", "succeeded")),
            .json(200, summaries(serverA)),
        ])
        let session = try await signedIn(stub)
        let ids = Ids(ServerRecordingId(id: UUID(uuidString: serverA)!, hasAudio: true))
        _ = try await session.summarizeText(local: local, details, lines: lines, engine: "own-service", language: "zh-CN",
                                            templateId: nil, profession: "", ids: ids) { _ in }
        #expect(stub.requests.first.map(route) == "PUT /v1/recordings/\(serverA)/transcript")
        #expect(!stub.requests.contains { route($0) == "POST /v1/recordings" })
        #expect(await ids.current()?.hasAudio == true)
    }

    /// A transcript the account made stays the server's: no PUT replaces it (its speakers and
    /// end times would be lost); the summary is made from it.
    @Test func theAccountsOwnTranscriptIsNotReplaced() async throws {
        let stub = StubTransport([
            .json(202, task("summarize", "queued")),
            .json(200, task("summarize", "succeeded")),
            .json(200, summaries(serverA)),
        ])
        let session = try await signedIn(stub)
        let ids = Ids(ServerRecordingId(id: UUID(uuidString: serverA)!, hasAudio: true))
        _ = try await session.summarizeText(local: local, details, lines: lines, engine: "account", language: "zh-CN",
                                            templateId: nil, profession: "", ids: ids, fromServer: true) { _ in }
        #expect(!stub.requests.contains { $0.httpMethod == "PUT" })
        #expect(stub.requests.first.map(route) == "POST /v1/recordings/\(serverA)/summaries")
    }

    /// The server no longer has the kept recording (deleted there): forget it and make a new one
    /// with a fresh key, so the old answer is not replayed.
    @Test func aRecordingTheServerLostIsMadeAgain() async throws {
        let stub = StubTransport([
            .json(404, error("recording_not_found", "账号里没有这条录音")),
            .json(201, recording(serverB, audio: false)),
            .json(200, transcript(serverB)),
            .json(202, task("summarize", "queued", on: serverB)),
            .json(200, task("summarize", "succeeded", on: serverB)),
            .json(200, summaries(serverB)),
        ])
        let session = try await signedIn(stub)
        let ids = Ids(ServerRecordingId(id: UUID(uuidString: serverA)!, hasAudio: false))
        _ = try await session.summarizeText(local: local, details, lines: lines, engine: "on-device", language: "zh-CN",
                                            templateId: nil, profession: "", ids: ids) { _ in }
        #expect(await ids.forgotten == 1)
        #expect(await ids.current() == ServerRecordingId(id: UUID(uuidString: serverB)!, hasAudio: false))
        let key = stub.requests[1].value(forHTTPHeaderField: "Idempotency-Key")
        #expect(key != nil && key != "text-\(local.uuidString.lowercased())")
        #expect(route(stub.requests[2]) == "PUT /v1/recordings/\(serverB)/transcript")
    }

    /// Other errors are the caller's to show: a server transcription still running is not a
    /// lost recording.
    @Test func otherErrorsPassThrough() async throws {
        let stub = StubTransport([.json(409, error("transcription_running", "服务器正在转写这条录音，请等它完成"))])
        let session = try await signedIn(stub)
        let ids = Ids(ServerRecordingId(id: UUID(uuidString: serverA)!, hasAudio: true))
        await #expect(throws: AccountError.self) {
            _ = try await session.summarizeText(local: local, details, lines: lines, engine: "on-device",
                                                language: "zh-CN", templateId: nil, profession: "", ids: ids) { _ in }
        }
        let forgotten = await ids.forgotten
        #expect(stub.requests.count == 1 && forgotten == 0)
    }

    @Test func signedOutSendsNothing() async throws {
        let stub = StubTransport([])
        let session = AccountSession(client: AccountClient(baseURL: base, transport: stub), store: InMemorySessionStore())
        await #expect(throws: AccountError.signedOut) {
            _ = try await session.summarizeText(local: local, details, lines: lines, engine: "on-device",
                                                language: "zh-CN", templateId: nil, profession: "", ids: Ids()) { _ in }
        }
        await #expect(throws: AccountError.signedOut) {
            _ = try await session.transcribeRecording(local: local, new, audio: Data("0123456789".utf8),
                                                      language: "zh-CN", ids: Ids(), sleep: { _ in })
        }
        #expect(stub.requests.isEmpty)
    }

    /// The app's lines end where the next one starts; engine and language names the server
    /// would refuse are replaced.
    @Test func theAppsTranscriptIsShapedForTheServer() {
        let lines = TranscriptLine.lines(starts: [(0, "大家好"), (1_500, "开始吧"), (9_000, "散会")], durationMs: 8_000)
        #expect(lines.map(\.startMs) == [0, 1_500, 9_000] && lines.map(\.endMs) == [1_500, 9_000, 9_000])
        #expect(lines.map(\.text) == ["大家好", "开始吧", "散会"] && lines.allSatisfy { $0.speaker == nil })
        #expect(TranscriptLine.serverEngine("on-device") == "on-device")
        #expect(TranscriptLine.serverEngine("cloud") == "own-service")
        #expect(TranscriptLine.serverEngine("text") == "text")
        #expect(TranscriptLine.serverEngine("Whisper 1") == "app" && TranscriptLine.serverEngine("") == "app")
        #expect(TranscriptLine.serverLanguage("zh-CN") == "zh-CN" && TranscriptLine.serverLanguage("en") == "en")
        #expect(TranscriptLine.serverLanguage("und") == "auto" && TranscriptLine.serverLanguage("zh-Hans") == "auto")
        #expect(TranscriptLine.serverLanguage("zh-cn") == "auto" && TranscriptLine.serverLanguage("") == "auto")
    }
}
