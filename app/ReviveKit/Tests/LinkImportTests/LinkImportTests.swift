import Foundation
@testable import LinkImport
import Testing
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// X12 链接导入 (features.md; test-spec.md T-M5-10…13). Every page, feed and lookup reply here is
// written for the test: no network, no third-party content.

struct LinkTextTests {
    @Test func findsTheLinkInSharedText() {
        let shared = "【505 茶海轶闻】听《某节目》上小宇宙。https://www.xiaoyuzhoufm.com/episode/6abf70bee742e36efcbdbcba?s=eyJ1Ijo，快来听"
        #expect(LinkText.firstURL(in: shared)?.absoluteString
            == "https://www.xiaoyuzhoufm.com/episode/6abf70bee742e36efcbdbcba?s=eyJ1Ijo")
        #expect(LinkText.firstURL(in: "see (https://example.com/feed.xml).")?.absoluteString == "https://example.com/feed.xml")
        #expect(LinkText.firstURL(in: "  HTTPS://Example.com/a.mp3\n")?.host == "Example.com")
        #expect(LinkText.firstURL(in: "没有链接") == nil)
        #expect(LinkText.firstURL(in: "ftp://example.com/a.mp3") == nil)
    }

    @Test func plainHTTPIsAskedOverHTTPS() throws {
        #expect(LinkText.secure(try #require(URL(string: "http://feeds.example.com:80/a.xml?x=1"))).absoluteString
            == "https://feeds.example.com/a.xml?x=1")
        #expect(LinkText.secure(try #require(URL(string: "http://example.com:8080/a"))).absoluteString
            == "https://example.com:8080/a")
        let already = try #require(URL(string: "https://example.com/a"))
        #expect(LinkText.secure(already) == already)
    }

    @Test func videoSitesAreNamed() throws {
        #expect(LinkText.isVideoSite(try #require(URL(string: "https://www.bilibili.com/video/BV1"))))
        #expect(LinkText.isVideoSite(try #require(URL(string: "https://youtu.be/abc"))))
        #expect(LinkText.isVideoSite(try #require(URL(string: "https://v.douyin.com/abc"))))
        #expect(!LinkText.isVideoSite(try #require(URL(string: "https://notyoutube.com/a"))))
        #expect(!LinkText.isVideoSite(try #require(URL(string: "https://www.xiaoyuzhoufm.com/episode/1"))))
    }

    @Test func savedExtensionFollowsTheLinkThenTheType() throws {
        let plain = try #require(URL(string: "https://cdn.example.com/redirect/abc"))
        #expect(LinkText.fileExtension(contentType: "audio/mpeg", url: plain) == "mp3")
        #expect(LinkText.fileExtension(contentType: "audio/x-m4a; charset=binary", url: plain) == "m4a")
        #expect(LinkText.fileExtension(contentType: "audio/ogg", url: plain) == "ogg")
        #expect(LinkText.fileExtension(contentType: nil, url: plain) == "mp3")
        let named = try #require(URL(string: "https://cdn.example.com/ep.M4A?x=1"))
        #expect(LinkText.fileExtension(contentType: "audio/mpeg", url: named) == "m4a")
    }

    @Test func audioTypes() {
        #expect(LinkText.isAudioType("audio/mpeg"))
        #expect(LinkText.isAudioType("Audio/MP4; codecs=mp4a"))
        #expect(LinkText.isAudioType("application/ogg"))
        #expect(!LinkText.isAudioType("text/html; charset=utf-8"))
        #expect(!LinkText.isAudioType(nil))
    }

    @Test func titleOfABareAudioLink() throws {
        #expect(LinkText.title(forAudio: try #require(URL(string: "https://a.example/ep%2012.mp3"))) == "ep 12")
        #expect(LinkText.title(forAudio: try #require(URL(string: "https://media.example/x/audio/128/default.mp3")))
            == "media.example")
    }
}

struct FeedParserTests {
    static let rss = """
    <?xml version="1.0" encoding="UTF-8"?>
    <rss version="2.0" xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd">
      <channel>
        <title><![CDATA[试听节目]]></title>
        <image><title>not the show</title><url>https://example.com/a.jpg</url></image>
        <item>
          <title>第 1 期</title>
          <pubDate>Mon, 02 Nov 2026 08:00:00 +0800</pubDate>
          <itunes:duration>01:02:03</itunes:duration>
          <enclosure url="https://cdn.example.com/1.mp3" type="audio/mpeg" length="123456"/>
        </item>
        <item>
          <title><![CDATA[第 2 期：A & B]]></title>
          <pubDate>Tue, 10 Nov 2026 08:00:00 GMT</pubDate>
          <itunes:duration>754</itunes:duration>
          <enclosure url="/media/2.m4a" type="audio/x-m4a" length="0"/>
        </item>
        <item>
          <title>只有图片</title>
          <enclosure url="https://cdn.example.com/cover.jpg" type="image/jpeg" length="10"/>
        </item>
        <item>
          <title>没有音频</title>
        </item>
      </channel>
    </rss>
    """

    @Test func readsEpisodesWithAudioNewestFirst() throws {
        let feed = try #require(FeedParser.parse(Data(Self.rss.utf8), base: URL(string: "https://example.com/feed")))
        #expect(feed.title == "试听节目")
        #expect(feed.episodes.map(\.title) == ["第 2 期：A & B", "第 1 期"])
        let newest = feed.episodes[0]
        #expect(newest.audioURL.absoluteString == "https://example.com/media/2.m4a")
        #expect(newest.durationSeconds == 754)
        #expect(newest.sizeBytes == nil)
        #expect(newest.show == "试听节目")
        let older = feed.episodes[1]
        #expect(older.durationSeconds == 3723)
        #expect(older.sizeBytes == 123_456)
        #expect(older.published == Date(timeIntervalSince1970: 1_793_577_600))
    }

    @Test func readsAtom() throws {
        let atom = """
        <feed xmlns="http://www.w3.org/2005/Atom">
          <title>Atom 节目</title>
          <entry>
            <title>单集</title>
            <updated>2026-11-01T00:00:00Z</updated>
            <link rel="alternate" href="https://example.com/ep"/>
            <link rel="enclosure" type="audio/mpeg" href="https://example.com/ep.mp3" length="99"/>
          </entry>
        </feed>
        """
        let feed = try #require(FeedParser.parse(Data(atom.utf8)))
        #expect(feed.title == "Atom 节目")
        #expect(feed.episodes.map(\.audioURL.absoluteString) == ["https://example.com/ep.mp3"])
        #expect(feed.episodes.first?.sizeBytes == 99)
    }

    @Test func notAFeed() {
        #expect(FeedParser.parse(Data("<html><body>hi</body></html>".utf8)) == nil)
        #expect(FeedParser.parse(Data("not xml".utf8)) == nil)
        #expect(FeedParser.looksLikeFeed(Data(Self.rss.utf8), contentType: "text/xml"))
        #expect(!FeedParser.looksLikeFeed(Data("<!doctype html><html>".utf8), contentType: "text/html"))
    }

    @Test func durations() {
        #expect(FeedParser.duration("1:00:00") == 3600)
        #expect(FeedParser.duration("62:03") == 3723)
        #expect(FeedParser.duration("3723.4") == 3723)
        #expect(FeedParser.duration("") == nil)
        #expect(FeedParser.duration("abc") == nil)
        #expect(FeedParser.duration("1:2:3:4") == nil)
    }
}

struct PageScannerTests {
    let base = URL(string: "https://podcast.example.com/episode/42")!

    @Test func openGraphAudioWins() {
        let html = """
        <html><head><title>页面标题</title>
        <meta property="og:title" content="505 茶&amp;海"/>
        <meta property="og:site_name" content="某播客站">
        <meta property="og:audio" content="https://media.example.com/a.m4a?sig=1&amp;t=2"/>
        </head><body><audio src="" preload="none"></audio></body></html>
        """
        let found = PageScanner.scan(html, base: base)
        #expect(found.audio?.absoluteString == "https://media.example.com/a.m4a?sig=1&t=2")
        #expect(found.title == "505 茶&海")
        #expect(found.show == "某播客站")
    }

    @Test func audioElementWhenNoMetaTag() {
        let html = """
        <title> 单集 &amp; 嘉宾 </title>
        <audio controls><source src='/files/ep42.mp3' type='audio/mpeg'></audio>
        """
        let found = PageScanner.scan(html, base: base)
        #expect(found.audio?.absoluteString == "https://podcast.example.com/files/ep42.mp3")
        #expect(found.title == "单集 & 嘉宾")
    }

    @Test func videoSourcesAreNotAudio() {
        let html = #"<video><source src="/clip.mp4" type="video/webm"></video>"#
        #expect(PageScanner.scan(html, base: base).audio == nil)
    }

    @Test func feedLinkWhenNoAudio() {
        let html = #"<link rel="stylesheet" href="/a.css"><link rel="alternate" type="application/rss+xml" title="RSS" href="/feed.xml">"#
        let found = PageScanner.scan(html, base: base)
        #expect(found.audio == nil)
        #expect(found.feed?.absoluteString == "https://podcast.example.com/feed.xml")
    }

    @Test func nothingFound() {
        let found = PageScanner.scan("<html><body>文章</body></html>", base: base)
        #expect(found.audio == nil && found.feed == nil && found.title == nil)
    }
}

struct ApplePodcastsTests {
    @Test func parsesShowAndEpisodeLinks() throws {
        let episode = try #require(URL(string: "https://podcasts.apple.com/cn/podcast/%E8%8A%82%E7%9B%AE/id1200361736?i=1000803280175"))
        #expect(ApplePodcasts.parse(episode) == .init(showId: "1200361736", episodeId: "1000803280175", country: "cn"))
        let show = try #require(URL(string: "https://podcasts.apple.com/podcast/id42"))
        #expect(ApplePodcasts.parse(show) == .init(showId: "42", episodeId: nil, country: nil))
        #expect(ApplePodcasts.parse(try #require(URL(string: "https://example.com/podcast/id42"))) == nil)
        #expect(ApplePodcasts.parse(try #require(URL(string: "https://podcasts.apple.com/cn/browse"))) == nil)
    }

    @Test func lookupCarriesOnlyTheIds() {
        let url = ApplePodcasts.lookupURL(.init(showId: "42", episodeId: "7", country: "cn"))
        #expect(url.host == "itunes.apple.com")
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(Set(items.map(\.name)) == ["id", "entity", "limit", "country"])
        #expect(items.first { $0.name == "id" }?.value == "42")
    }

    static let lookup = """
    {"resultCount":3,"results":[
      {"wrapperType":"track","kind":"podcast","collectionId":42,"collectionName":"测试节目","feedUrl":"https://feeds.example.com/42"},
      {"wrapperType":"podcastEpisode","kind":"podcast-episode","trackId":1000000000002,"trackName":"新一期",
       "episodeUrl":"https://cdn.example.com/2.mp3","releaseDate":"2026-11-20T10:45:00Z","trackTimeMillis":1692000,
       "collectionName":"测试节目"},
      {"wrapperType":"podcastEpisode","kind":"podcast-episode","trackId":1000000000001,"trackName":"旧一期",
       "episodeUrl":"https://cdn.example.com/1.mp3","releaseDate":"2026-11-19T10:45:00Z"}
    ]}
    """

    @Test func readsTheLookup() throws {
        let lookup = try #require(ApplePodcasts.parseLookup(Data(Self.lookup.utf8)))
        #expect(lookup.show == "测试节目")
        #expect(lookup.feed?.absoluteString == "https://feeds.example.com/42")
        #expect(lookup.episodes.map(\.id) == ["1000000000002", "1000000000001"])
        #expect(lookup.episodes[0].episode.durationSeconds == 1692)
        #expect(lookup.episodes[0].episode.published == Date(timeIntervalSince1970: 1_795_171_500))
        #expect(ApplePodcasts.parseLookup(Data("[]".utf8)) == nil)
    }
}

/// Serves canned replies by URL and records what was asked.
private final class StubFetcher: LinkFetching, @unchecked Sendable {
    private let lock = NSLock()
    private var replies: [String: Result<FetchedPage, Error>] = [:]
    private var _asked: [String] = []
    var asked: [String] { lock.withLock { _asked } }

    func page(_ url: String, status: Int = 200, type: String? = "text/html; charset=utf-8", body: String = "",
              finalURL: String? = nil) {
        replies[url] = .success(FetchedPage(url: URL(string: finalURL ?? url)!, status: status, contentType: type,
                                            body: Data(body.utf8)))
    }

    func fail(_ url: String, _ error: Error) { replies[url] = .failure(error) }

    func fetch(_ url: URL, limit: Int) async throws -> FetchedPage {
        lock.withLock { _asked.append(url.absoluteString) }
        guard let reply = lock.withLock({ replies[url.absoluteString] }) else { throw URLError(.cannotFindHost) }
        return try reply.get()
    }
}

struct LinkResolverTests {
    @Test func episodePageBecomesOneEpisode() async throws {
        let stub = StubFetcher()
        stub.page("https://podcast.example.com/episode/42", body: #"<meta property="og:title" content="第 42 期"><meta property="og:audio" content="https://media.example.com/42.m4a">"#)
        let result = try await LinkResolver(fetcher: stub).resolve("分享 https://podcast.example.com/episode/42 快听")
        #expect(result == .episode(PodcastEpisode(title: "第 42 期", audioURL: URL(string: "https://media.example.com/42.m4a")!)))
    }

    @Test func feedBecomesAShow() async throws {
        let stub = StubFetcher()
        stub.page("https://example.com/feed", type: "application/rss+xml", body: FeedParserTests.rss)
        guard case .show(let title, let episodes) = try await LinkResolver(fetcher: stub).resolve("https://example.com/feed")
        else { Issue.record("not a show"); return }
        #expect(title == "试听节目")
        #expect(episodes.count == 2)
    }

    @Test func plainHTTPLinksAreFetchedOverHTTPS() async throws {
        let stub = StubFetcher()
        stub.page("https://example.com/feed", type: "application/rss+xml", body: FeedParserTests.rss)
        guard case .show = try await LinkResolver(fetcher: stub).resolve("http://example.com/feed") else {
            Issue.record("not a show"); return
        }
        #expect(stub.asked == ["https://example.com/feed"])
    }

    @Test func showPageFollowsItsFeedLink() async throws {
        let stub = StubFetcher()
        stub.page("https://example.com/show", body: #"<link rel="alternate" type="application/rss+xml" href="/feed">"#)
        stub.page("https://example.com/feed", type: "text/xml", body: FeedParserTests.rss)
        guard case .show = try await LinkResolver(fetcher: stub).resolve("https://example.com/show") else {
            Issue.record("not a show"); return
        }
        #expect(stub.asked == ["https://example.com/show", "https://example.com/feed"])
    }

    @Test func audioLinkIsNotFetchedHere() async throws {
        let stub = StubFetcher()
        let result = try await LinkResolver(fetcher: stub).resolve("https://cdn.example.com/shows/ep%201.mp3")
        #expect(result == .episode(PodcastEpisode(title: "ep 1", audioURL: URL(string: "https://cdn.example.com/shows/ep%201.mp3")!)))
        #expect(stub.asked.isEmpty)
    }

    @Test func redirectToAudioIsTheEpisode() async throws {
        let stub = StubFetcher()
        stub.page("https://example.com/r/abc", type: "audio/mpeg", finalURL: "https://cdn.example.com/abc.mp3")
        let result = try await LinkResolver(fetcher: stub).resolve("https://example.com/r/abc")
        #expect(result == .episode(PodcastEpisode(title: "abc", audioURL: URL(string: "https://cdn.example.com/abc.mp3")!)))
    }

    @Test func appleEpisodeLinkUsesTheLookup() async throws {
        let stub = StubFetcher()
        let lookup = ApplePodcasts.lookupURL(.init(showId: "42", episodeId: nil, country: "cn")).absoluteString
        stub.page(lookup, type: "text/javascript", body: ApplePodcastsTests.lookup)
        let result = try await LinkResolver(fetcher: stub)
            .resolve("https://podcasts.apple.com/cn/podcast/x/id42?i=1000000000001")
        guard case .episode(let episode) = result else { Issue.record("not an episode"); return }
        #expect(episode.title == "旧一期")
        #expect(stub.asked == [lookup])
    }

    @Test func appleEpisodeOutsideTheLookupFallsBackToTheFeed() async throws {
        let stub = StubFetcher()
        let lookup = ApplePodcasts.lookupURL(.init(showId: "42", episodeId: nil, country: nil)).absoluteString
        stub.page(lookup, type: "text/javascript", body: ApplePodcastsTests.lookup)
        stub.page("https://feeds.example.com/42", type: "application/rss+xml", body: FeedParserTests.rss)
        guard case .show(_, let episodes) = try await LinkResolver(fetcher: stub)
            .resolve("https://podcasts.apple.com/podcast/id42?i=999") else { Issue.record("not a show"); return }
        #expect(episodes.count == 2)
    }

    @Test func appleShowLinkListsTheLookup() async throws {
        let stub = StubFetcher()
        let lookup = ApplePodcasts.lookupURL(.init(showId: "42", episodeId: nil, country: nil)).absoluteString
        stub.page(lookup, type: "text/javascript", body: ApplePodcastsTests.lookup)
        let result = try await LinkResolver(fetcher: stub).resolve("https://podcasts.apple.com/podcast/id42")
        guard case .show(let title, let episodes) = result else { Issue.record("not a show"); return }
        #expect(title == "测试节目")
        #expect(episodes.map(\.title) == ["新一期", "旧一期"])
    }

    @Test func failuresReadAsAdvice() async throws {
        let stub = StubFetcher()
        stub.page("https://example.com/paid", status: 403)
        stub.page("https://example.com/gone", status: 404)
        stub.page("https://example.com/broken", status: 500)
        stub.page("https://example.com/article", body: "<p>只是文章</p>")
        stub.fail("https://example.com/offline", URLError(.notConnectedToInternet))
        stub.fail("https://example.com/cellular", URLError(.dataNotAllowed))
        let resolver = LinkResolver(fetcher: stub)
        func failure(_ text: String) async -> LinkImportError? {
            do { _ = try await resolver.resolve(text); return nil } catch { return error as? LinkImportError }
        }
        #expect(await failure("https://example.com/paid") == .needsLogin)
        #expect(await failure("https://example.com/gone") == .notFound)
        #expect(await failure("https://example.com/broken") == .http(500))
        #expect(await failure("https://example.com/article") == .noAudio)
        #expect(await failure("https://example.com/offline") == .offline)
        #expect(await failure("https://example.com/cellular") == .offline)
        #expect(await failure("随便写的字") == .noLink)
        #expect(await failure("https://www.bilibili.com/video/BV1xx") == .videoSite)
        if case .unreachable = await failure("https://unknown.example.com/") {} else { Issue.record("not unreachable") }
        #expect(!stub.asked.contains { $0.contains("bilibili") })
    }

    @Test func everyErrorHasText() {
        let all: [LinkImportError] = [.noLink, .videoSite, .offline, .unreachable("x"), .needsLogin, .notFound, .http(502),
                                      .noAudio, .tooLarge, .noSpace, .notAudio]
        #expect(all.allSatisfy { !$0.userText.isEmpty })
        #expect(LinkImportError.http(502).userText.contains("502"))
    }
}
