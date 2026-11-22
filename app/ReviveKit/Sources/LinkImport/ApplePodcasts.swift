import Foundation

/// Apple Podcasts links (`podcasts.apple.com/cn/podcast/…/id1200361736?i=1000803280175`) hold no
/// audio themselves. Apple's public lookup service gives the show's episodes with their audio
/// links and the show's feed; that is the one request here that goes to a host the user did not
/// paste (`itunes.apple.com`), and it carries only the two numbers from the link.
public enum ApplePodcasts {
    public struct Link: Sendable, Equatable {
        public let showId: String
        public let episodeId: String?
        /// The store front in the link ("cn", "us"), so the lookup sees the same catalogue.
        public let country: String?
    }

    public static func parse(_ url: URL) -> Link? {
        guard let host = url.host?.lowercased(),
              host == "podcasts.apple.com" || host == "itunes.apple.com" || host.hasSuffix(".podcasts.apple.com")
        else { return nil }
        guard let idPart = url.pathComponents.last(where: { $0.hasPrefix("id") && $0.dropFirst(2).allSatisfy(\.isNumber) }),
              idPart.count > 2
        else { return nil }
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let episode = query.first { $0.name == "i" }?.value.flatMap { $0.allSatisfy(\.isNumber) && !$0.isEmpty ? $0 : nil }
        let first = url.pathComponents.dropFirst().first?.lowercased()
        let country = first.flatMap { $0.count == 2 && $0.allSatisfy(\.isLetter) ? $0 : nil }
        return Link(showId: String(idPart.dropFirst(2)), episodeId: episode, country: country)
    }

    static func lookupURL(_ link: Link) -> URL {
        var components = URLComponents(string: "https://itunes.apple.com/lookup")!
        components.queryItems = [URLQueryItem(name: "id", value: link.showId),
                                 URLQueryItem(name: "entity", value: "podcastEpisode"),
                                 URLQueryItem(name: "limit", value: "200")]
            + (link.country.map { [URLQueryItem(name: "country", value: $0)] } ?? [])
        return components.url!
    }

    public struct Lookup: Sendable, Equatable {
        public let show: String?
        public let feed: URL?
        /// Newest first, as the service returns them.
        public let episodes: [Entry]
    }

    /// An episode and its Apple id (the `i=` of an episode link).
    public struct Entry: Sendable, Equatable {
        public let id: String
        public let episode: PodcastEpisode
    }

    /// nil when `data` is not a lookup reply.
    static func parseLookup(_ data: Data) -> Lookup? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = object["results"] as? [[String: Any]]
        else { return nil }
        let showRecord = results.first { ($0["kind"] as? String) == "podcast" }
        let show = showRecord?["collectionName"] as? String
        let feed = (showRecord?["feedUrl"] as? String).flatMap(URL.init(string:))
        let iso = ISO8601DateFormatter()
        let episodes: [Entry] = results.compactMap { record in
            guard (record["wrapperType"] as? String) == "podcastEpisode",
                  let link = (record["episodeUrl"] as? String).flatMap(URL.init(string:)),
                  link.scheme?.hasPrefix("http") == true
            else { return nil }
            let id = (record["trackId"] as? NSNumber)?.stringValue ?? (record["trackId"] as? String) ?? ""
            let millis = (record["trackTimeMillis"] as? NSNumber)?.intValue
            let episode = PodcastEpisode(
                title: (record["trackName"] as? String) ?? LinkText.title(forAudio: link),
                show: (record["collectionName"] as? String) ?? show, audioURL: link,
                published: (record["releaseDate"] as? String).flatMap { iso.date(from: $0) },
                durationSeconds: millis.map { $0 / 1000 })
            return Entry(id: id, episode: episode)
        }
        return Lookup(show: show, feed: feed, episodes: episodes)
    }
}
