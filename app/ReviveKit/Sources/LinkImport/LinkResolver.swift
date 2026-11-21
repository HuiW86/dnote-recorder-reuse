import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The start of a GET reply: enough to tell an audio file from a page or a feed.
public struct FetchedPage: Sendable, Equatable {
    /// After redirects.
    public let url: URL
    public let status: Int
    public let contentType: String?
    /// At most the limit asked for; empty for audio, which the downloader fetches.
    public let body: Data

    public init(url: URL, status: Int, contentType: String?, body: Data) {
        self.url = url
        self.status = status
        self.contentType = contentType
        self.body = body
    }
}

/// GETs pages, feeds and the lookup. Tests pass a stub.
public protocol LinkFetching: Sendable {
    /// Reads at most `limit` bytes of the body, and none when the reply is audio.
    func fetch(_ url: URL, limit: Int) async throws -> FetchedPage
}

/// Turns pasted text into an episode, or a show to pick an episode from (features.md X12).
public protocol LinkResolving: Sendable {
    func resolve(_ text: String) async throws -> LinkResolution
}

public struct LinkResolver: LinkResolving {
    /// Pages and feeds larger than this are cut; a feed with hundreds of episodes fits.
    public static let pageLimit = 8_000_000
    let fetcher: LinkFetching

    public init(fetcher: LinkFetching = URLSessionFetcher()) {
        self.fetcher = fetcher
    }

    public func resolve(_ text: String) async throws -> LinkResolution {
        guard let url = LinkText.firstURL(in: text) else { throw LinkImportError.noLink }
        if LinkText.isVideoSite(url) { throw LinkImportError.videoSite }
        if let apple = ApplePodcasts.parse(url) { return try await resolveApple(apple) }
        // A link that names an audio file is the episode; the download checks it really is audio.
        if LinkText.hasAudioExtension(url) {
            return .episode(PodcastEpisode(title: LinkText.title(forAudio: url), audioURL: url))
        }
        let page = try await get(url)
        if LinkText.isAudioType(page.contentType) {
            return .episode(PodcastEpisode(title: LinkText.title(forAudio: page.url), audioURL: page.url))
        }
        if FeedParser.looksLikeFeed(page.body, contentType: page.contentType) {
            return try show(from: page)
        }
        let found = PageScanner.scan(String(decoding: page.body, as: UTF8.self), base: page.url)
        if let audio = found.audio {
            return .episode(PodcastEpisode(title: found.title ?? LinkText.title(forAudio: audio), show: found.show,
                                           audioURL: audio))
        }
        if let feed = found.feed {
            return try show(from: try await get(feed))
        }
        throw LinkImportError.noAudio
    }

    private func resolveApple(_ link: ApplePodcasts.Link) async throws -> LinkResolution {
        let reply = try await get(ApplePodcasts.lookupURL(link))
        guard let lookup = ApplePodcasts.parseLookup(reply.body) else { throw LinkImportError.noAudio }
        if let id = link.episodeId, let entry = lookup.episodes.first(where: { $0.id == id }) {
            return .episode(entry.episode)
        }
        // An episode older than the newest 200, or a show link: offer the show to pick from.
        if !lookup.episodes.isEmpty, link.episodeId == nil {
            return .show(title: lookup.show ?? "", episodes: lookup.episodes.map(\.episode))
        }
        guard let feed = lookup.feed else { throw LinkImportError.noAudio }
        return try show(from: try await get(feed))
    }

    private func show(from page: FetchedPage) throws -> LinkResolution {
        guard let feed = FeedParser.parse(page.body, base: page.url), !feed.episodes.isEmpty else {
            throw LinkImportError.noAudio
        }
        return .show(title: feed.title, episodes: feed.episodes)
    }

    private func get(_ url: URL) async throws -> FetchedPage {
        let page: FetchedPage
        do {
            page = try await fetcher.fetch(LinkText.secure(url), limit: Self.pageLimit)
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            throw LinkImportError.network(error)
        }
        if let failure = LinkImportError.status(page.status) { throw failure }
        return page
    }
}

/// The real fetcher. Sends no cookies and no credentials: only what the link itself serves.
/// One session per fetch, invalidated after it, so making a fetcher costs nothing.
/// `@unchecked`: the configuration is never changed after init, and `URLSession` copies it.
public struct URLSessionFetcher: LinkFetching, @unchecked Sendable {
    let configuration: URLSessionConfiguration

    public init(configuration: URLSessionConfiguration? = nil) {
        self.configuration = configuration ?? URLSessionFetcher.makeConfiguration()
    }

    /// No cookies, no stored credentials, nothing kept on disk.
    static func makeConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCredentialStorage = nil
        return configuration
    }

    public func fetch(_ url: URL, limit: Int) async throws -> FetchedPage {
        var request = URLRequest(url: url)
        request.setValue("text/html,application/rss+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        #if canImport(FoundationNetworking)
        // swift-corelibs-foundation has no streaming bytes API; only used by Linux test runs.
        let (data, response) = try await session.data(for: request)
        let http = response as? HTTPURLResponse
        let type = http?.value(forHTTPHeaderField: "Content-Type")
        return FetchedPage(url: response.url ?? url, status: http?.statusCode ?? 200, contentType: type,
                           body: LinkText.isAudioType(type) ? Data() : data.prefix(limit))
        #else
        let (bytes, response) = try await session.bytes(for: request)
        let http = response as? HTTPURLResponse
        let type = http?.value(forHTTPHeaderField: "Content-Type")
        var body = Data()
        // Audio is left for the downloader: stop before reading any of it.
        if !LinkText.isAudioType(type) {
            for try await byte in bytes {
                body.append(byte)
                if body.count >= limit { break }
            }
        }
        bytes.task.cancel()
        return FetchedPage(url: response.url ?? url, status: http?.statusCode ?? 200, contentType: type, body: body)
        #endif
    }
}
