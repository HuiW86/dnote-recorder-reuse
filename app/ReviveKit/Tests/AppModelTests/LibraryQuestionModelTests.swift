import AppModel
import Assistant
import Foundation
import Library
import Testing

// G3 全局对话 on 知识库: the page state around one question.
@MainActor
struct LibraryQuestionModelTests {
    @Test func asksAcrossSummariesAndListsTheCitedRecordings() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ask-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let library = RecordingLibrary(database: try AppDatabase.inMemory(), store: try AudioStore(root: root))
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        func add(_ title: String, summary: String, minutes: Double) throws -> UUID {
            let id = UUID()
            let path = try library.store.storeAudio(Data("OggS".utf8), id: id)
            let r = Recording(id: id, deviceId: nil, source: .phone, cardFileName: nil, cardFileSize: nil,
                              startedAt: start.addingTimeInterval(minutes * 60), durationMs: 1_000, audioPath: path,
                              audioSha256: "", title: title, createdAt: start, updatedAt: start)
            try library.database.writer.write { try r.insert($0) }
            try library.saveSummary(Summary(recordingId: id, scene: "meeting", title: title, summary: summary,
                                            sections: [], todos: [], tags: [], people: [], model: "m",
                                            createdAt: start.addingTimeInterval(minutes * 60)))
            return id
        }
        let older = try add("周会", summary: "周三上线", minutes: 0)
        _ = try add("灵感", summary: "选题", minutes: 10)

        let unset = LibraryQuestionModel(library: library, assistant: AssistantConfigSource { nil })
        #expect(!unset.isConfigured)
        unset.ask("什么时候上线？")
        #expect(unset.answer == nil && !unset.isAsking)

        // The newest summary is [1]; the reply cites [2], the older one.
        let base = HostStub.register("周三上线 [2]。")
        let config = ServiceConfig(baseURL: base, model: "m", apiKey: "k")
        let model = LibraryQuestionModel(library: library, assistant: AssistantConfigSource { config },
                                         asker: LibraryAsker(client: ChatClient(session: HostStub.session())))
        #expect(model.isConfigured && model.privacyNote.contains("录音音频和文字稿不会发送"))
        model.ask("   ")
        #expect(!model.isAsking)
        model.ask("什么时候上线？")
        // G3 "SSE 流式": the answer is there at once, empty and still arriving.
        #expect(model.answer?.isStreaming == true && model.answer?.text == "" && model.isAsking)
        await waitUntil("answered") { model.answer?.isStreaming == false && !model.isAsking }
        #expect(model.answer?.question == "什么时候上线？")
        #expect(model.answer?.text == "周三上线 [2]。")
        #expect(model.answer?.sources.map(\.recording.id) == [older])
        #expect(model.answer?.isCutOff == false)
        model.clear()
        #expect(model.answer == nil)
    }
}

/// Answers each test's requests with its own chat reply, keyed by a fresh host; no network.
private final class HostStub: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var replies: [String: String] = [:]

    static func register(_ content: String) -> String {
        let host = "\(UUID().uuidString.lowercased()).stub.test"
        lock.lock()
        replies[host] = content
        lock.unlock()
        return "https://\(host)/v1"
    }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HostStub.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        let content = request.url?.host.flatMap { Self.replies[$0] }
        Self.lock.unlock()
        guard let url = request.url, let content else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        let object: [String: Any] = ["choices": [["index": 0, "message": ["role": "assistant", "content": content]]]]
        let body = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
