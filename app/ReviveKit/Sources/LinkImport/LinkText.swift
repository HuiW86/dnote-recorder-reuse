import Foundation

/// Reading links out of what the user pasted. Podcast apps share text such as
/// "【505 茶海轶闻】… https://www.xiaoyuzhoufm.com/episode/…?s=…", not a bare URL.
public enum LinkText {
    /// The first http(s) link in `text`, without trailing punctuation.
    public static func firstURL(in text: String) -> URL? {
        guard let range = text.range(of: #"https?://[^\s<>"'，。、；！？「」『』【】（）《》]+"#,
                                     options: [.regularExpression, .caseInsensitive])
        else { return nil }
        var candidate = String(text[range])
        while let last = candidate.last, ".,;:!?)]}'".contains(last) { candidate.removeLast() }
        guard let url = URL(string: candidate), let host = url.host, !host.isEmpty else { return nil }
        return url
    }

    /// iOS allows only HTTPS without an App Transport Security exception, and the app asks for
    /// none; podcast hosts that still publish `http://` links almost all serve HTTPS too.
    public static func secure(_ url: URL) -> URL {
        guard url.scheme?.lowercased() == "http", var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return url }
        components.scheme = "https"
        if components.port == 80 { components.port = nil }
        return components.url ?? url
    }

    /// Hosts whose links are videos (#72): they need a downloader the phone cannot run.
    static let videoHosts = [
        "youtube.com", "youtu.be", "bilibili.com", "b23.tv", "douyin.com", "iesdouyin.com", "ixigua.com",
        "kuaishou.com", "xiaohongshu.com", "xhslink.com", "vimeo.com", "tiktok.com", "weibo.com",
    ]

    static func isVideoSite(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return videoHosts.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    /// File extensions read as audio. `AudioImporter` takes OGG Opus as is and converts the rest.
    static let audioExtensions: Set<String> = ["mp3", "m4a", "aac", "mp4", "m4b", "wav", "aif", "aiff", "caf",
                                               "ogg", "opus", "flac"]

    static func hasAudioExtension(_ url: URL) -> Bool {
        audioExtensions.contains(url.pathExtension.lowercased())
    }

    /// `audio/*`, plus the MIME types podcast hosts use for audio in an MP4 or Ogg container.
    static func isAudioType(_ contentType: String?) -> Bool {
        guard let type = contentType.map(mimeType) else { return false }
        return type.hasPrefix("audio/") || ["video/mp4", "application/ogg", "video/x-m4v"].contains(type)
    }

    /// "audio/mpeg; charset=…" → "audio/mpeg".
    static func mimeType(_ contentType: String) -> String {
        contentType.split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
    }

    /// The extension to save a download under, so the system reader picks the right format.
    static func fileExtension(contentType: String?, url: URL) -> String {
        let fromURL = url.pathExtension.lowercased()
        if audioExtensions.contains(fromURL) { return fromURL }
        switch contentType.map(mimeType) {
        case "audio/mpeg"?, "audio/mp3"?, "audio/mpeg3"?: return "mp3"
        case "audio/mp4"?, "audio/x-m4a"?, "audio/m4a"?, "video/mp4"?, "audio/aac"?, "audio/aacp"?: return "m4a"
        case "audio/ogg"?, "application/ogg"?, "audio/opus"?: return "ogg"
        case "audio/wav"?, "audio/x-wav"?, "audio/wave"?: return "wav"
        case "audio/flac"?, "audio/x-flac"?: return "flac"
        case "audio/x-aiff"?, "audio/aiff"?: return "aiff"
        default: return "mp3"
        }
    }

    /// A title for a bare audio link: its file name without the extension, or the host.
    static func title(forAudio url: URL) -> String {
        let name = url.deletingPathExtension().lastPathComponent.removingPercentEncoding
            ?? url.deletingPathExtension().lastPathComponent
        let useless: Set<String> = ["", "/", "default", "audio", "media", "download", "file", "stream"]
        return useless.contains(name.lowercased()) ? (url.host ?? "链接导入") : name
    }
}
