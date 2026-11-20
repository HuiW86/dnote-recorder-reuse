import CardProtocol
import CardTestSupport
import Foundation
import Library
import Testing
import Transcription
@testable import Assistant

// X11: transcription by the user's own service.
struct CloudTranscriberTests {
    @Test func endpointSitsNextToChat() {
        #expect(CloudTranscriber.endpoint("https://api.example.com/v1/")?.absoluteString
                == "https://api.example.com/v1/audio/transcriptions")
        #expect(CloudTranscriber.endpoint("ftp://x") == nil)
    }

    @Test func multipartCarriesFieldsAndFile() {
        let body = CloudTranscriber.multipartBody(boundary: "B", fields: [("model", "whisper-1")],
                                                  fileName: "audio.m4a", mimeType: "audio/mp4", file: Data("abc".utf8))
        let text = String(decoding: body, as: UTF8.self)
        #expect(text.contains("--B\r\nContent-Disposition: form-data; name=\"model\"\r\n\r\nwhisper-1\r\n"))
        #expect(text.contains("name=\"file\"; filename=\"audio.m4a\"\r\nContent-Type: audio/mp4\r\n\r\nabc\r\n"))
        #expect(text.hasSuffix("--B--\r\n"))
    }

    @Test func usesSegmentTimesWhenGiven() throws {
        let reply = #"{"text":"x","segments":[{"start":0.0,"text":" 第一句。"},{"start":2.5,"text":"第二句"},{"start":4,"text":"  "}]}"#
        let segments = try CloudTranscriber.segments(from: Data(reply.utf8), durationMs: 10_000)
        #expect(segments == [TranscriptSegment(startMs: 0, text: "第一句。"), TranscriptSegment(startMs: 2500, text: "第二句")])
    }

    @Test func estimatesTimesFromPlainText() throws {
        let segments = try CloudTranscriber.segments(from: Data(#"{"text":"一二三。四五六七八九"}"#.utf8), durationMs: 10_000)
        #expect(segments.map(\.text) == ["一二三。", "四五六七八九"])
        #expect(segments.map(\.startMs) == [0, 4000])  // 4 of 10 characters before the second
        #expect(try CloudTranscriber.segments(from: Data(#"{"text":"  "}"#.utf8), durationMs: 1).isEmpty)
        #expect(throws: TranscriptionError.self) { try CloudTranscriber.segments(from: Data("nope".utf8), durationMs: 1) }
    }

    /// No connection reads as the same advice as for summaries, not as a failed transcription.
    @Test func noConnectionIsOffline() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cloud-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let library = RecordingLibrary(database: try AppDatabase.inMemory(), store: try AudioStore(root: root))
        let frames = try SyntheticOpus.sine(seconds: 1)
        let ogg = OggOpus.wrap(frames)
        let id = UUID()
        let path = try library.store.storeAudio(ogg, id: id)
        let recording = Recording(id: id, deviceId: nil, source: .card, cardFileName: "a.opus", cardFileSize: ogg.count,
                                  startedAt: Date(), durationMs: frames.count * 20, audioPath: path, audioSha256: "",
                                  title: "t", createdAt: Date(), updatedAt: Date())
        let transcriber = CloudTranscriber(
            library: library, config: ServiceConfig(baseURL: StubURLProtocol.offlineBase, model: "whisper-1", apiKey: ""),
            session: StubURLProtocol.session())
        await #expect(throws: AssistantError.offline) {
            try await transcriber.transcribe(recording, language: "zh-CN")
        }
    }

    /// The upload goes to the user's service with its key, model and language; a service that
    /// rejects verbose_json gets a plain request.
    @Test func uploadsAndFallsBackToPlainText() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cloud-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let library = RecordingLibrary(database: try AppDatabase.inMemory(), store: try AudioStore(root: root))
        let frames = try SyntheticOpus.sine(seconds: 2)
        let ogg = OggOpus.wrap(frames)
        let id = UUID()
        let path = try library.store.storeAudio(ogg, id: id)
        let recording = Recording(id: id, deviceId: nil, source: .card, cardFileName: "a.opus", cardFileSize: ogg.count,
                                  startedAt: Date(), durationMs: frames.count * 20, audioPath: path, audioSha256: "",
                                  title: "t", createdAt: Date(), updatedAt: Date())

        let log = RequestLog()
        let base = StubURLProtocol.register { request, body in
            log.append(request, body)
            let detailed = String(decoding: body, as: UTF8.self).contains("verbose_json")
            return detailed ? (400, Data("unsupported".utf8)) : (200, Data(#"{"text":"你好。"}"#.utf8))
        }
        let transcriber = CloudTranscriber(
            library: library, config: ServiceConfig(baseURL: base, model: "whisper-1", apiKey: "test-key-not-real"),
            session: StubURLProtocol.session())
        let segments = try await transcriber.transcribe(recording, language: "zh-CN")
        #expect(segments == [TranscriptSegment(startMs: 0, text: "你好。")])

        #expect(log.entries.count == 2)
        let last = try #require(log.entries.last)
        #expect(last.request.url?.path == "/v1/audio/transcriptions")
        #expect(last.request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key-not-real")
        let text = String(decoding: last.body, as: UTF8.self)
        #expect(text.contains("whisper-1") && text.contains("name=\"language\"\r\n\r\nzh\r\n"))
        #expect(!text.contains("verbose_json"))
    }
}
