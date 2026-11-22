import AppModel
import CardProtocol
import CardTestSupport
import Foundation
import Library
import LinkImport
import Testing

// X12 从链接导入 (features.md; product-spec.md P05; test-spec.md T-M5-14): the sheet's states,
// what is stored, and that a failed or cancelled import stores nothing. The resolver and the
// downloader are stubs; the download goes through the real `AudioImporter`.

private struct StubResolver: LinkResolving {
    let result: Result<LinkResolution, LinkImportError>
    func resolve(_ text: String) async throws -> LinkResolution { try result.get() }
}

/// Writes `body` (or waits until cancelled) and records which links were downloaded.
private final class StubDownloader: EpisodeDownloading, @unchecked Sendable {
    enum Body { case ogg, junk, hang }
    private let lock = NSLock()
    private var _asked: [URL] = []
    private var _folders: [URL] = []
    let body: Body
    var asked: [URL] { lock.withLock { _asked } }
    var folders: [URL] { lock.withLock { _folders } }

    init(_ body: Body) { self.body = body }

    func download(_ url: URL, progress: @escaping @Sendable (Int64, Int64?) -> Void) async throws -> URL {
        lock.withLock { _asked.append(url) }
        if body == .hang {
            try await Task.sleep(nanoseconds: 30_000_000_000)
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("link-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        lock.withLock { _folders.append(dir) }
        let data = body == .ogg ? OggOpus.wrap(try SyntheticOpus.sine(seconds: 1)) : Data("<html>expired</html>".utf8)
        let file = dir.appendingPathComponent(body == .ogg ? "episode.ogg" : "episode.mp3")
        try data.write(to: file)
        progress(Int64(data.count), Int64(data.count))
        return file
    }
}

@MainActor
struct LinkImportModelTests {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("linkimport-\(UUID().uuidString)")

    private func library() throws -> RecordingLibrary {
        RecordingLibrary(database: try AppDatabase.inMemory(), store: try AudioStore(root: root))
    }

    private func episode(_ n: Int) -> PodcastEpisode {
        PodcastEpisode(title: "第 \(n) 期", show: "测试节目", audioURL: URL(string: "https://cdn.example.com/\(n).ogg")!)
    }

    @Test func oneEpisodeIsStoredAsAnImport() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let library = try library()
        let downloader = StubDownloader(.ogg)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let model = LinkImportModel(library: library, resolver: StubResolver(result: .success(.episode(episode(7)))),
                                    downloader: downloader, now: { now })
        #expect(!model.canSubmit)
        model.text = "听这期 https://podcast.example.com/episode/7"
        #expect(model.canSubmit)
        model.submit()
        #expect(model.phase == .resolving)
        await model.waitForWork()

        let stored = try #require(try library.recordings().first)
        #expect(model.phase == .done(id: stored.id, title: "第 7 期"))
        #expect(stored.source == .import)
        #expect(stored.title == "第 7 期")
        #expect(stored.startedAt == now)
        #expect(stored.durationMs >= 980 && stored.durationMs <= 1020)
        #expect(downloader.asked == [URL(string: "https://cdn.example.com/7.ogg")!])
        // The download's temporary folder is gone once stored.
        #expect(downloader.folders.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })

        model.reset()
        #expect(model.phase == .idle)
    }

    @Test func aShowIsOfferedToPickFrom() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let library = try library()
        let downloader = StubDownloader(.ogg)
        let episodes = (1...150).map(episode)
        let model = LinkImportModel(library: library,
                                    resolver: StubResolver(result: .success(.show(title: "测试节目", episodes: episodes))),
                                    downloader: downloader)
        model.text = "https://example.com/feed.xml"
        model.submit()
        await model.waitForWork()
        guard case .choosing(let show, let listed) = model.phase else {
            Issue.record("not choosing: \(model.phase)")
            return
        }
        #expect(show == "测试节目")
        #expect(listed.count == LinkImportModel.listedEpisodes)
        #expect(try library.recordings().isEmpty)

        model.choose(listed[1])
        await model.waitForWork()
        #expect(downloader.asked == [episodes[1].audioURL])
        #expect(try library.recordings().map(\.title) == ["第 2 期"])
    }

    @Test func failuresAreShownAndStoreNothing() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let library = try library()

        let paid = LinkImportModel(library: library, resolver: StubResolver(result: .failure(.needsLogin)),
                                   downloader: StubDownloader(.ogg))
        paid.text = "https://example.com/paid"
        paid.submit()
        await paid.waitForWork()
        #expect(paid.phase == .failed(LinkImportError.needsLogin.userText))

        let downloader = StubDownloader(.junk)
        let expired = LinkImportModel(library: library, resolver: StubResolver(result: .success(.episode(episode(1)))),
                                      downloader: downloader)
        expired.text = "https://example.com/1"
        expired.submit()
        await expired.waitForWork()
        #expect(expired.phase == .failed(LinkImportError.notAudio.userText))
        #expect(downloader.folders.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        #expect(try library.recordings().isEmpty)
    }

    @Test func cancellingStoresNothing() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let library = try library()
        let model = LinkImportModel(library: library, resolver: StubResolver(result: .success(.episode(episode(3)))),
                                    downloader: StubDownloader(.hang))
        model.text = "https://example.com/3"
        model.submit()
        for _ in 0..<100 {
            if case .downloading = model.phase { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        guard case .downloading(let current, _, _) = model.phase else {
            Issue.record("not downloading: \(model.phase)")
            return
        }
        #expect(current == episode(3))
        #expect(model.isBusy && !model.canSubmit)
        model.cancel()
        #expect(model.phase == .idle)
        // A new link right away: the cancelled run finishing late must not reset it.
        model.text = "https://example.com/4"
        model.submit()
        #expect(model.phase == .resolving)
        // Wait for the new run to reach its download (a busy CI runner can take longer than a fixed
        // 200 ms; app-ci saw it still resolving), then give the cancelled run time to interfere.
        for _ in 0..<300 {
            if model.phase != .resolving { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        try await Task.sleep(nanoseconds: 200_000_000)
        guard case .downloading = model.phase else {
            Issue.record("the cancelled run changed the new one: \(model.phase)")
            return
        }
        model.cancel()
        #expect(try library.recordings().isEmpty)
    }

    @Test func aSecondTapOnTheListDoesNothing() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let library = try library()
        let downloader = StubDownloader(.ogg)
        let model = LinkImportModel(library: library,
                                    resolver: StubResolver(result: .success(.show(title: "", episodes: [episode(1), episode(2)]))),
                                    downloader: downloader)
        model.text = "https://example.com/feed"
        model.submit()
        await model.waitForWork()
        model.choose(episode(1))
        model.choose(episode(2))
        await model.waitForWork()
        #expect(downloader.asked == [episode(1).audioURL])
        #expect(try library.recordings().count == 1)
    }

    @Test func idleShowsNoProgress() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let model = LinkImportModel(library: try library(), resolver: StubResolver(result: .failure(.noLink)),
                                    downloader: StubDownloader(.ogg))
        #expect(model.progressText == nil && model.progressFraction == nil)
        #expect(!LinkImportModel.rightsNotice.isEmpty && !LinkImportModel.privacyNotice.isEmpty)
    }
}
