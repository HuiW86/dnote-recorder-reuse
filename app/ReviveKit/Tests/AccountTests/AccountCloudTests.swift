import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import Account

// 用闻笺账号转写 (test-spec.md T-M2-49): uploading a recording's audio in parts, resuming,
// starting a transcription, waiting on the task and reading the transcript, against a stub server.

private let recordingId = "0c1d2e3f-0000-4000-8000-0000000000aa"
private let taskId = "0c1d2e3f-0000-4000-8000-0000000000bb"

/// `RecordingOut`; `parts` are (number, offset, size, done, etag).
private func recordingJSON(uploaded: Bool, size: Int, parts: [(Int, Int, Int, Bool, String?)]?) -> String {
    let audio = #"{"sha256":"\#(String(repeating: "a", count: 64))","size":\#(size),"content_type":"audio/ogg","uploaded":\#(uploaded)}"#
    var upload = "null"
    if let parts {
        let items = parts.map { number, offset, partSize, done, etag in
            let tag = etag.map { "\"\($0)\"" } ?? "null"
            return #"{"part_number":\#(number),"offset":\#(offset),"size":\#(partSize),"url":"https://store.example.com/p\#(number)?sig=x","done":\#(done),"etag":\#(tag)}"#
        }
        upload = #"{"part_size":4,"expires_at":"2026-11-27T16:00:00+00:00","parts":[\#(items.joined(separator: ","))]}"#
    }
    return #"{"id":"\#(recordingId)","source":"card","started_at":"2026-11-27T08:12:41+00:00","duration_ms":60000,"title":"","device_sn_hash":null,"audio":\#(audio),"version":1,"created_at":"2026-11-27T15:00:00+00:00","updated_at":"2026-11-27T15:00:00+00:00","upload":\#(upload)}"#
}

private func taskJSON(_ status: String, error: String? = nil) -> String {
    let failure = error.map { #"{"code":"asr_failed","message":"\#($0)"}"# } ?? "null"
    return #"{"id":"\#(taskId)","kind":"transcribe","recording_id":"\#(recordingId)","status":"\#(status)","attempts":1,"error":\#(failure),"result":null,"created_at":"2026-11-27T15:00:00+00:00","updated_at":"2026-11-27T15:00:00+00:00","finished_at":null}"#
}

private let audio = Data("0123456789".utf8)  // 10 bytes: parts of 4, 4 and 2

private let new = NewRecording(source: .card, startedAt: Date(timeIntervalSince1970: 1_795_000_000),
                               durationMs: 60_000, title: "周会", sha256: String(repeating: "a", count: 64),
                               size: 10, contentType: "audio/ogg")

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

/// Collects progress reports across threads.
private final class Reports: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Int] = []
    func add(_ value: Int) { lock.withLock { values.append(value) } }
    var all: [Int] { lock.withLock { values } }
}

struct AccountCloudTests {
    /// Parts the server already has are skipped; the rest go to their signed URLs without the
    /// token, and completing names every part with its ETag in order.
    @Test func uploadSendsOnlyMissingPartsAndCompletes() async throws {
        let stub = StubTransport([
            .json(201, recordingJSON(uploaded: false, size: 10, parts: [(1, 0, 4, true, "e1"), (2, 4, 4, false, nil),
                                                                        (3, 8, 2, false, nil)])),
            .headers(200, ["ETag": "\"e2\""]),
            .headers(200, ["etag": "\"e3\""]),
            .json(200, recordingJSON(uploaded: true, size: 10, parts: nil)),
        ])
        let session = try await signedIn(stub)
        let reports = Reports()
        let id = try await session.upload(new, audio: audio, idempotencyKey: "rec-1") { held, total in
            #expect(total == 10)
            reports.add(held)
        }

        #expect(id == UUID(uuidString: recordingId))
        #expect(reports.all == [4, 8, 10])
        let requests = stub.requests
        #expect(requests.map { "\($0.httpMethod!) \($0.url!.host!)\($0.url!.path)" } == [
            "POST api.example.com/v1/recordings", "PUT store.example.com/p2", "PUT store.example.com/p3",
            "POST api.example.com/v1/recordings/\(recordingId)/upload-complete",
        ])
        let created = json(requests[0])
        #expect(created["source"] as? String == "card" && created["duration_ms"] as? Int == 60_000)
        #expect(created["title"] as? String == "周会")
        #expect((created["started_at"] as? String)?.hasPrefix("2026-11-18T11:06:40") == true)
        let audioField = try #require(created["audio"] as? [String: Any])
        #expect(audioField["size"] as? Int == 10 && audioField["content_type"] as? String == "audio/ogg")
        #expect(requests[0].value(forHTTPHeaderField: "Idempotency-Key") == "rec-1")
        #expect(requests[0].value(forHTTPHeaderField: "Authorization") == "Bearer a1")
        #expect(requests[1].httpBody == Data("4567".utf8) && requests[2].httpBody == Data("89".utf8))
        #expect(requests[1].value(forHTTPHeaderField: "Authorization") == nil)
        let completed = try #require(json(requests[3])["parts"] as? [[String: Any]])
        #expect(completed.map { $0["part_number"] as? Int } == [1, 2, 3])
        #expect(completed.map { $0["etag"] as? String } == ["e1", "\"e2\"", "\"e3\""])
    }

    /// The same audio again: the server already has it, nothing more is sent.
    @Test func audioTheServerHasIsNotSentAgain() async throws {
        let stub = StubTransport([.json(200, recordingJSON(uploaded: true, size: 10, parts: nil))])
        let session = try await signedIn(stub)
        let id = try await session.upload(new, audio: audio, idempotencyKey: "rec-1")
        #expect(id == UUID(uuidString: recordingId) && stub.requests.count == 1)
    }

    /// The store forgot the upload: fresh URLs once, the missing part again, then done.
    @Test func aLapsedUploadStartsOverOnce() async throws {
        let stub = StubTransport([
            .json(201, recordingJSON(uploaded: false, size: 10, parts: [(1, 0, 10, false, nil)])),
            .headers(200, ["ETag": "x1"]),
            .json(409, error("upload_expired", "这次上传已失效，请重新获取上传地址")),
            .json(200, recordingJSON(uploaded: false, size: 10, parts: [(1, 0, 10, false, nil)])),
            .headers(200, ["ETag": "x2"]),
            .json(200, recordingJSON(uploaded: true, size: 10, parts: nil)),
        ])
        let session = try await signedIn(stub)
        _ = try await session.upload(new, audio: audio, idempotencyKey: "rec-1")
        #expect(stub.requests.map(\.url!.path) == [
            "/v1/recordings", "/p1", "/v1/recordings/\(recordingId)/upload-complete",
            "/v1/recordings/\(recordingId)/upload", "/p1", "/v1/recordings/\(recordingId)/upload-complete",
        ])
        #expect(try #require(json(stub.requests[5])["parts"] as? [[String: Any]]).first?["etag"] as? String == "x2")
    }

    @Test func audioOfTheWrongSizeIsNotSent() async throws {
        let stub = StubTransport([])
        let session = try await signedIn(stub)
        await #expect(throws: AccountError.self) {
            _ = try await session.upload(new, audio: Data("short".utf8), idempotencyKey: "rec-1")
        }
        #expect(stub.requests.isEmpty)
    }

    /// prd.md §7.4: every 2 s at first, then less often, capped at 30 s.
    @Test func waitingOnATaskBacksOff() async throws {
        let stub = StubTransport([
            .json(202, taskJSON("queued")),
            .json(200, taskJSON("queued")), .json(200, taskJSON("running")), .json(200, taskJSON("running")),
            .json(200, taskJSON("succeeded")),
        ])
        let session = try await signedIn(stub)
        let id = UUID(uuidString: recordingId)!
        let started = try await session.transcribe(recordingId: id, language: "zh", idempotencyKey: "tr-1")
        #expect(started.status == .queued && started.id == UUID(uuidString: taskId))
        #expect(json(stub.requests[0])["language"] as? String == "zh")
        #expect(json(stub.requests[0])["speakers"] as? Bool == true)

        let slept = Waits()
        let done = try await session.waitForTask(started.id) { slept.add($0) }
        #expect(done.status == .succeeded)
        #expect(slept.all == [.seconds(2), .seconds(3), .milliseconds(4500)])
        #expect(stub.requests.dropFirst().allSatisfy { $0.url!.path == "/v1/tasks/\(taskId)" && $0.httpMethod == "GET" })
        #expect(AccountSession.lastPoll == .seconds(30))
    }

    @Test func aFailedTaskSaysWhy() async throws {
        let stub = StubTransport([.json(200, taskJSON("failed", error: "音频无法识别"))])
        let session = try await signedIn(stub)
        await #expect(throws: AccountError.taskFailed(code: "asr_failed", message: "音频无法识别")) {
            _ = try await session.waitForTask(UUID(uuidString: taskId)!) { _ in }
        }
        #expect(AccountError.taskFailed(code: "asr_failed", message: "音频无法识别").userText == "音频无法识别")
        #expect(AccountError.taskFailed(code: "x", message: "").userText == "服务器没能处理这条录音，请稍后再试")
    }

    @Test func quotaRefusalReadsAsTheServerSays() async throws {
        let stub = StubTransport([.json(429, error("quota_exceeded", "本月转写时长已用完"))])
        let session = try await signedIn(stub)
        await #expect(throws: AccountError.server(status: 429, code: "quota_exceeded", message: "本月转写时长已用完",
                                                  retryable: false)) {
            _ = try await session.transcribe(recordingId: UUID(), language: "zh", idempotencyKey: "tr-1")
        }
    }

    @Test func theTranscriptKeepsTimesAndSpeakers() async throws {
        let body = #"{"recording_id":"\#(recordingId)","language":"zh","segments":[{"start_ms":0,"end_ms":1500,"speaker":"S1","text":"大家好"},{"start_ms":1500,"end_ms":3000,"speaker":null,"text":"开始吧"}],"speakers":{"S1":"王老师"},"asr_provider":"stand-in","created_at":"2026-11-27T15:00:00+00:00","updated_at":"2026-11-27T15:00:00+00:00"}"#
        let stub = StubTransport([.json(200, body)])
        let session = try await signedIn(stub)
        let transcript = try await session.transcript(recordingId: UUID(uuidString: recordingId)!)
        #expect(transcript.segments.count == 2 && transcript.segments[0].speaker == "S1")
        #expect(transcript.segments[1].startMs == 1500 && transcript.segments[1].speaker == nil)
        #expect(transcript.speakers == ["S1": "王老师"] && transcript.asrProvider == "stand-in")
        #expect(stub.requests[0].url!.path == "/v1/recordings/\(recordingId)/transcript")
    }
}

/// Collects requested waits across threads.
private final class Waits: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Duration] = []
    func add(_ value: Duration) { lock.withLock { values.append(value) } }
    var all: [Duration] { lock.withLock { values } }
}
