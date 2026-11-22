import Foundation
@testable import LinkImport
import Testing
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Serves one canned reply per host, optionally in slow chunks; never the network.
private final class Served: URLProtocol {
    struct Reply {
        var status = 200
        var headers: [String: String] = ["Content-Type": "audio/mpeg"]
        var body = Data("ID3 fake mp3".utf8)
        /// Sends the body in this many pieces, 50 ms apart.
        var chunks = 1
    }

    nonisolated(unsafe) static var replies: [String: Reply] = [:]
    private var stopped = false

    static func configuration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [Served.self]
        return configuration
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let reply = Self.replies[url.host ?? ""] else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }
        let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1",
                                       headerFields: reply.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let size = max(1, reply.body.count / reply.chunks)
        let pieces = stride(from: 0, to: reply.body.count, by: size)
            .map { Data(reply.body[$0..<min($0 + size, reply.body.count)]) }
        send(pieces, 0, slow: reply.chunks > 1)
    }

    private func send(_ pieces: [Data], _ index: Int, slow: Bool) {
        guard !stopped else { return }
        guard index < pieces.count else {
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        client?.urlProtocol(self, didLoad: pieces[index])
        if slow {
            // URLProtocol is not Sendable on every platform; the loading system serialises calls anyway.
            let me = Unchecked(value: self)
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { me.value.send(pieces, index + 1, slow: slow) }
        } else {
            send(pieces, index + 1, slow: slow)
        }
    }

    override func stopLoading() { stopped = true }
}

private final class Seen: @unchecked Sendable {
    private let lock = NSLock()
    private var _values: [(Int64, Int64?)] = []
    var values: [(Int64, Int64?)] { lock.withLock { _values } }
    func add(_ received: Int64, _ total: Int64?) { lock.withLock { _values.append((received, total)) } }
}

private struct Unchecked<T>: @unchecked Sendable { let value: T }

@Suite(.serialized)
struct EpisodeDownloaderTests {
    @Test func savesAudioUnderItsFormat() async throws {
        Served.replies["ok.example"] = .init()
        let file = try await EpisodeDownloader(configuration: Served.configuration())
            .download(URL(string: "https://ok.example/redirect/abc")!) { _, _ in }
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        #expect(file.lastPathComponent == "episode.mp3")
        #expect(try Data(contentsOf: file) == Data("ID3 fake mp3".utf8))
    }

    @Test func reportsProgressAgainstTheLength() async throws {
        Served.replies["sized.example"] = .init(headers: ["Content-Type": "audio/mp4", "Content-Length": "400"],
                                                body: Data(repeating: 1, count: 400), chunks: 4)
        let seen = Seen()
        let file = try await EpisodeDownloader(configuration: Served.configuration())
            .download(URL(string: "https://sized.example/ep")!) { received, total in seen.add(received, total) }
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        #expect(file.pathExtension == "m4a")
        #expect(seen.values.last?.0 == 400)
        #expect(seen.values.allSatisfy { $0.1 == 400 })
        #expect(seen.values.map(\.0) == seen.values.map(\.0).sorted())
    }

    @Test func refusesPagesAndLogins() async throws {
        Served.replies["page.example"] = .init(headers: ["Content-Type": "text/html"], body: Data("<html>".utf8))
        Served.replies["paid.example"] = .init(status: 403)
        let downloader = EpisodeDownloader(configuration: Served.configuration())
        await #expect(throws: LinkImportError.notAudio) {
            try await downloader.download(URL(string: "https://page.example/a.mp3")!) { _, _ in }
        }
        await #expect(throws: LinkImportError.needsLogin) {
            try await downloader.download(URL(string: "https://paid.example/a.mp3")!) { _, _ in }
        }
    }

    @Test func stopsAtTheSizeLimit() async throws {
        Served.replies["big.example"] = .init(body: Data(repeating: 7, count: 4000), chunks: 40)
        await #expect(throws: LinkImportError.tooLarge) {
            try await EpisodeDownloader(configuration: Served.configuration(), limit: 1000)
                .download(URL(string: "https://big.example/a.mp3")!) { _, _ in }
        }
    }

    @Test func stopsWhenThePhoneIsFull() async throws {
        Served.replies["full.example"] = .init(headers: ["Content-Type": "audio/mpeg", "Content-Length": "4000"],
                                               body: Data(repeating: 7, count: 4000), chunks: 40)
        await #expect(throws: LinkImportError.noSpace) {
            try await EpisodeDownloader(configuration: Served.configuration(), freeSpace: { 1_000 })
                .download(URL(string: "https://full.example/a.mp3")!) { _, _ in }
        }
    }

    @Test func cancellingStopsTheDownload() async throws {
        Served.replies["slow.example"] = .init(body: Data(repeating: 7, count: 4000), chunks: 80)
        let task = Task {
            try await EpisodeDownloader(configuration: Served.configuration())
                .download(URL(string: "https://slow.example/a.mp3")!) { _, _ in }
        }
        try await Task.sleep(nanoseconds: 300_000_000)
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}
