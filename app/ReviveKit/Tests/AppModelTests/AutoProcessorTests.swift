import Assistant
import Foundation
import Library
import Testing
import Transcription
@testable import AppModel

// 录完自动整理 (features.md X22): new recordings get a transcript and a summary without a tap.
// The transcriber is a fake and the service a stub on its own URLProtocol: no network.

private final class CallCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func bump() { lock.withLock { count += 1 } }
}

private struct CountingTranscriber: SpeechTranscribing {
    let result: Result<[TranscriptSegment], TranscriptionError>
    let calls = CallCount()

    func transcribe(_ recording: Recording, language: String) async throws -> [TranscriptSegment] {
        calls.bump()
        return try result.get()
    }
}

/// Answers every request with one chat completion; counts the requests.
private final class AutoReply: URLProtocol {
    nonisolated(unsafe) static var content = ""
    nonisolated(unsafe) static var requests = 0

    static func session(_ content: String) -> URLSession {
        Self.content = content
        Self.requests = 0
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AutoReply.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requests += 1
        let body = try? JSONSerialization.data(withJSONObject: [
            "choices": [["message": ["role": "assistant", "content": Self.content]]],
        ])
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body ?? Data())
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@MainActor
private final class AutoFixture {
    let library: RecordingLibrary
    let preferences = Preferences(defaults: UserDefaults(suiteName: "auto-\(UUID().uuidString)")!)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("auto-\(UUID().uuidString)")

    init() throws {
        library = RecordingLibrary(database: try AppDatabase.inMemory(), store: try AudioStore(root: root))
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    @discardableResult
    func addRecording(createdAt: Date = Date(), audio: Bool = true) async throws -> Recording {
        let r = Recording(id: UUID(), deviceId: nil, source: .card, cardFileName: nil, cardFileSize: nil,
                          startedAt: createdAt, durationMs: 60_000, audioPath: audio ? "audio/x.ogg" : "",
                          audioSha256: "", title: Recording.defaultTitle(for: createdAt),
                          createdAt: createdAt, updatedAt: createdAt)
        try await library.database.writer.write { try r.insert($0) }
        return r
    }

    func processor(_ transcriber: (any SpeechTranscribing)?, service: Bool = true) -> AutoProcessor {
        let reply = #"{"scene":"meeting","title":"定发布日","summary":"周三发布。","sections":[],"todos":["发通知"],"tags":[],"people":[]}"#
        let config = ServiceConfig(baseURL: "https://auto.invalid/v1", model: "m", apiKey: "")
        return AutoProcessor(library: library, preferences: preferences, transcriberSource: { transcriber },
                             assistant: service ? AssistantConfigSource { config } : nil,
                             summarizer: Summarizer(client: ChatClient(session: AutoReply.session(reply))),
                             jobs: TranscriptionJobs(defaults: UserDefaults(suiteName: "auto-rate-\(UUID().uuidString)")!))
    }
}

@MainActor
@Suite(.serialized)
struct AutoProcessorTests {
    private let lines = [TranscriptSegment(startMs: 0, text: "周三发布。")]

    @Test func offByDefaultLeavesNewRecordingsAlone() async throws {
        let f = try AutoFixture()
        let transcriber = CountingTranscriber(result: .success(lines))
        let processor = f.processor(transcriber)
        processor.start()
        let r = try await f.addRecording()
        try await Task.sleep(for: .milliseconds(300))
        #expect(transcriber.calls.value == 0)
        #expect(try f.library.transcript(recordingId: r.id) == nil)
        #expect(!f.preferences.autoProcessEnabled && f.preferences.autoProcessSince == nil)
        processor.stop()
    }

    /// A recording stored after the switch went on gets a transcript, a summary and the
    /// summary's title; one stored before it is left alone.
    @Test func transcribesAndSummarizesWhatArrivesAfterTurningItOn() async throws {
        let f = try AutoFixture()
        let older = try await f.addRecording(createdAt: Date().addingTimeInterval(-60))
        f.preferences.autoProcessEnabled = true
        let transcriber = CountingTranscriber(result: .success(lines))
        let processor = f.processor(transcriber)
        processor.start()
        let r = try await f.addRecording()

        await waitUntil("summarized") { (try? f.library.summary(recordingId: r.id)) != nil }
        #expect(try f.library.transcript(recordingId: r.id)?.segments == lines)
        #expect(try f.library.recording(id: r.id)?.title == "定发布日")
        #expect(try f.library.transcript(recordingId: older.id) == nil)
        #expect(transcriber.calls.value == 1)
        await waitUntil("idle") { processor.current == nil }

        // Turning it off and on again moves the start: nothing earlier is picked up.
        f.preferences.autoProcessEnabled = false
        #expect(f.preferences.autoProcessSince == nil)
        f.preferences.autoProcessEnabled = true
        let since = try #require(f.preferences.autoProcessSince)
        #expect(since > r.createdAt)
        processor.stop()
    }

    /// Without a service the transcript is still made; the summary is left for the page.
    @Test func transcribesOnlyWithoutAService() async throws {
        let f = try AutoFixture()
        f.preferences.autoProcessEnabled = true
        let processor = f.processor(CountingTranscriber(result: .success(lines)), service: false)
        processor.start()
        let r = try await f.addRecording()
        await waitUntil("transcribed") { (try? f.library.transcript(recordingId: r.id)) != nil }
        await waitUntil("idle") { processor.current == nil }
        #expect(try f.library.summary(recordingId: r.id) == nil)
        processor.stop()
    }

    /// A text-only recording (E2) has its transcript already: only the summary is made.
    @Test func summarizesATextRecordingWithoutTranscribing() async throws {
        let f = try AutoFixture()
        f.preferences.autoProcessEnabled = true
        let transcriber = CountingTranscriber(result: .success(lines))
        let processor = f.processor(transcriber)
        processor.start()
        let r = try #require(try f.library.addTextRecording(text: "周三发布。", title: "笔记", startedAt: Date()))
        await waitUntil("summarized") { (try? f.library.summary(recordingId: r.id)) != nil }
        #expect(transcriber.calls.value == 0)
        processor.stop()
    }

    /// A failure is tried once in this run: no loop of requests against a broken service.
    @Test func failedTranscriptionIsNotRetriedInTheSameRun() async throws {
        let f = try AutoFixture()
        f.preferences.autoProcessEnabled = true
        let transcriber = CountingTranscriber(result: .failure(.noSpeech))
        let processor = f.processor(transcriber)
        processor.start()
        let r = try await f.addRecording()
        await waitUntil("tried") { transcriber.calls.value == 1 }
        await waitUntil("idle") { processor.current == nil }
        try f.library.renameRecording(id: r.id, to: "改个名")  // the library changes again
        try await Task.sleep(for: .milliseconds(300))
        #expect(transcriber.calls.value == 1)
        #expect(try f.library.transcript(recordingId: r.id) == nil)
        processor.stop()
    }

    @Test func dueKeepsNewUntriedRecordingsOldestFirst() {
        let since = Date(timeIntervalSince1970: 1_000)
        func make(_ created: TimeInterval, trashed: Bool = false) -> Recording {
            var r = Recording(id: UUID(), deviceId: nil, source: .card, cardFileName: nil, cardFileSize: nil,
                              startedAt: Date(timeIntervalSince1970: created), durationMs: 1000,
                              audioPath: "a", audioSha256: "", title: "t",
                              createdAt: Date(timeIntervalSince1970: created),
                              updatedAt: Date(timeIntervalSince1970: created))
            if trashed { r.trashedAt = Date() }
            return r
        }
        let before = make(999), later = make(1_200), first = make(1_100), trashed = make(1_300, trashed: true)
        let tried = make(1_400)
        let all = [before, later, first, trashed, tried]
        let now = Date(timeIntervalSince1970: 2_000)
        #expect(AutoProcessor.due(all, since: nil, tried: [], now: now).isEmpty)
        #expect(AutoProcessor.due(all, since: since, tried: [tried.id], now: now).map(\.id) == [first.id, later.id])
        // Past the retry window, a recording is no longer due on a later launch.
        let late = Date(timeIntervalSince1970: 1_250 + AutoProcessor.retryWindow)
        #expect(AutoProcessor.due(all, since: since, tried: [], now: late).map(\.id) == [tried.id])
    }
}
