import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// Podcast feeds: RSS 2.0 with `<enclosure>` (what nearly every podcast host publishes), and Atom
/// with `<link rel="enclosure">`. Items without audio are left out.
public enum FeedParser {
    public struct Feed: Sendable, Equatable {
        public let title: String
        /// In feed order, which is newest first for almost every host; sorted by date when all have one.
        public let episodes: [PodcastEpisode]
    }

    /// Whether `data` starts like an RSS or Atom document.
    static func looksLikeFeed(_ data: Data, contentType: String?) -> Bool {
        let head = String(decoding: data.prefix(2048), as: UTF8.self).lowercased()
        return head.contains("<rss") || (head.contains("<feed") && head.contains("xmlns"))
            || (contentType.map(LinkText.mimeType).map { $0.contains("rss") || $0.contains("atom") } ?? false)
    }

    /// nil when `data` is not a well-formed feed.
    public static func parse(_ data: Data, base: URL? = nil) -> Feed? {
        let delegate = Delegate(base: base)
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = false
        parser.delegate = delegate
        guard parser.parse() || !delegate.episodes.isEmpty, delegate.sawFeed else { return nil }
        let show = delegate.channelTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        var episodes = delegate.episodes.map {
            PodcastEpisode(title: $0.title, show: show.isEmpty ? nil : show, audioURL: $0.audioURL,
                           published: $0.published, durationSeconds: $0.durationSeconds, sizeBytes: $0.sizeBytes)
        }
        if episodes.allSatisfy({ $0.published != nil }) {
            episodes.sort { $0.published! > $1.published! }
        }
        return Feed(title: show, episodes: episodes)
    }

    // MARK: Values

    /// "01:02:03", "62:03", "3723" or "3723.5" → seconds.
    static func duration(_ text: String) -> Int? {
        let parts = text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ":")
        guard !parts.isEmpty, parts.count <= 3 else { return nil }
        var seconds = 0.0
        for part in parts {
            guard let value = Double(part), value >= 0 else { return nil }
            seconds = seconds * 60 + value
        }
        return Int(seconds.rounded())
    }

    /// RFC 822 dates as feeds write them, with or without the weekday, and ISO 8601 for Atom.
    static func date(_ text: String) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for format in ["EEE, dd MMM yyyy HH:mm:ss Z", "EEE, dd MMM yyyy HH:mm:ss zzz", "dd MMM yyyy HH:mm:ss Z",
                       "EEE, dd MMM yyyy HH:mm Z", "EEE, d MMM yyyy HH:mm:ss Z"] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = format
            if let date = formatter.date(from: trimmed) { return date }
        }
        let iso = ISO8601DateFormatter()
        if let date = iso.date(from: trimmed) { return date }
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return iso.date(from: trimmed)
    }

    // MARK: Parsing

    private struct Item {
        var title = ""
        var audioURL: URL?
        var published: Date?
        var durationSeconds: Int?
        var sizeBytes: Int64?
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        let base: URL?
        var sawFeed = false
        var channelTitle = ""
        var episodes: [(title: String, audioURL: URL, published: Date?, durationSeconds: Int?, sizeBytes: Int64?)] = []
        private var item: Item?
        private var path: [String] = []
        private var text = ""

        init(base: URL?) { self.base = base }

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String] = [:]) {
            let element = name.lowercased()
            path.append(element)
            text = ""
            switch element {
            case "rss", "feed": sawFeed = true
            case "item", "entry": item = Item()
            case "enclosure" where item != nil:
                take(url: attributes["url"], type: attributes["type"], length: attributes["length"])
            case "link" where item != nil && attributes["rel"]?.lowercased() == "enclosure":
                take(url: attributes["href"], type: attributes["type"], length: attributes["length"])
            default: break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            text += String(decoding: CDATABlock, as: UTF8.self)
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            let element = name.lowercased()
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let parent = path.dropLast().last
            if item != nil {
                switch element {
                case "title" where parent == "item" || parent == "entry": item?.title = value
                // RSS `pubDate`, Atom `published` or `updated`: the first date seen is kept.
                case "pubdate", "published", "updated":
                    if item?.published == nil, let date = FeedParser.date(value) { item?.published = date }
                case "itunes:duration": item?.durationSeconds = FeedParser.duration(value)
                case "item", "entry":
                    if let current = item, let url = current.audioURL {
                        let title = current.title.isEmpty ? LinkText.title(forAudio: url) : current.title
                        episodes.append((title, url, current.published, current.durationSeconds, current.sizeBytes))
                    }
                    item = nil
                default: break
                }
            } else if element == "title", parent == "channel" || parent == "feed", channelTitle.isEmpty {
                channelTitle = value
            }
            path.removeLast()
            text = ""
        }

        private func take(url: String?, type: String?, length: String?) {
            guard item?.audioURL == nil, let url, let resolved = URL(string: url.trimmingCharacters(in: .whitespaces),
                                                                      relativeTo: base)?.absoluteURL,
                  resolved.scheme?.hasPrefix("http") == true
            else { return }
            // Feeds also enclose images and transcripts. With a type, it must be audio; without
            // one, the link must look like audio (or have no extension, as redirect links do).
            let typed = !(type?.trimmingCharacters(in: .whitespaces).isEmpty ?? true)
            let isAudio = typed ? LinkText.isAudioType(type)
                : LinkText.hasAudioExtension(resolved) || resolved.pathExtension.isEmpty
            guard isAudio else { return }
            item?.audioURL = resolved
            item?.sizeBytes = length.flatMap { Int64($0) }.flatMap { $0 > 0 ? $0 : nil }
        }
    }
}
