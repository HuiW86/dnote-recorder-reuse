import Foundation

/// Episode pages: podcast sites put the audio in Open Graph tags (小宇宙 writes `og:audio`), in an
/// `<audio>` or `<source>` element, or point to the show's feed with `<link rel="alternate">`.
/// Only what the page itself publishes is read: no scripts run, no logins, no hidden APIs.
public enum PageScanner {
    public struct Found: Sendable, Equatable {
        public var audio: URL?
        public var title: String?
        public var show: String?
        public var feed: URL?
    }

    public static func scan(_ html: String, base: URL) -> Found {
        var found = Found()
        var meta: [String: String] = [:]
        for tag in tags(named: "meta", in: html) {
            let key = (tag["property"] ?? tag["name"] ?? tag["itemprop"])?.lowercased()
            if let key, let content = tag["content"], !content.isEmpty, meta[key] == nil { meta[key] = content }
        }
        for key in ["og:audio:secure_url", "og:audio:url", "og:audio", "twitter:player:stream"] {
            if let url = meta[key].flatMap({ absolute($0, base: base) }) {
                found.audio = url
                break
            }
        }
        if found.audio == nil {
            for tag in tags(named: "audio", in: html) + tags(named: "source", in: html) {
                guard let src = tag["src"], let url = absolute(src, base: base) else { continue }
                // A <source> inside <video> is a video; take it only when typed or named as audio.
                if let type = tag["type"], !LinkText.isAudioType(type) { continue }
                if tag["type"] == nil, !LinkText.hasAudioExtension(url), html.range(of: "<audio", options: .caseInsensitive) == nil {
                    continue
                }
                found.audio = url
                break
            }
        }
        found.title = (meta["og:title"] ?? meta["twitter:title"] ?? titleElement(html)).map(clean)
        found.show = meta["og:site_name"].map(clean)
        for tag in tags(named: "link", in: html) {
            guard tag["rel"]?.lowercased().split(separator: " ").contains("alternate") == true,
                  let type = tag["type"]?.lowercased(), type.contains("rss") || type.contains("atom"),
                  let href = tag["href"], let url = absolute(href, base: base)
            else { continue }
            found.feed = url
            break
        }
        return found
    }

    // MARK: Markup

    /// Attributes of every `<name …>` tag, keys lowercased, values with entities decoded.
    static func tags(named name: String, in html: String) -> [[String: String]] {
        guard let tagPattern = try? NSRegularExpression(pattern: "<\(name)\\b([^>]*)>", options: [.caseInsensitive]),
              let attributePattern = try? NSRegularExpression(
                pattern: #"([A-Za-z_:][-A-Za-z0-9_:.]*)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'>]+))"#)
        else { return [] }
        let ns = html as NSString
        return tagPattern.matches(in: html, range: NSRange(location: 0, length: ns.length)).map { match in
            let body = ns.substring(with: match.range(at: 1))
            let bodyNS = body as NSString
            var attributes: [String: String] = [:]
            for attribute in attributePattern.matches(in: body, range: NSRange(location: 0, length: bodyNS.length)) {
                let key = bodyNS.substring(with: attribute.range(at: 1)).lowercased()
                let value = (2...4).lazy.map { attribute.range(at: $0) }.first { $0.location != NSNotFound }
                    .map { bodyNS.substring(with: $0) } ?? ""
                if attributes[key] == nil { attributes[key] = decodeEntities(value) }
            }
            return attributes
        }
    }

    static func titleElement(_ html: String) -> String? {
        guard let range = html.range(of: #"<title[^>]*>([^<]*)</title>"#, options: [.regularExpression, .caseInsensitive])
        else { return nil }
        let element = String(html[range])
        guard let start = element.firstIndex(of: ">"), let end = element.range(of: "</", options: .backwards)?.lowerBound,
              start < end else { return nil }
        let text = decodeEntities(String(element[element.index(after: start)..<end]))
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
    }

    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var out = text
        for (entity, value) in [("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"), ("&lt;", "<"), ("&gt;", ">"),
                                ("&nbsp;", " "), ("&#x2F;", "/"), ("&#47;", "/")] {
            out = out.replacingOccurrences(of: entity, with: value)
        }
        // Last, so "&amp;lt;" becomes "&lt;" and not "<".
        return out.replacingOccurrences(of: "&amp;", with: "&")
    }

    private static func clean(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func absolute(_ text: String, base: URL) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = URL(string: trimmed, relativeTo: base)?.absoluteURL,
              let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http"
        else { return nil }
        return url
    }
}
