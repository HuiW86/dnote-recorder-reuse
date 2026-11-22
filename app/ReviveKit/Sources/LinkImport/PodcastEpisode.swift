// Link import (features.md X12, iPhone part): a podcast link becomes a recording in the library.
// This module talks to the network: the page, feed or audio file the user pasted, and Apple's
// podcast lookup for Apple Podcasts links. No device module may depend on it (CLAUDE.md rule 3,
// scripts/check-m1-rules.sh). Video sites are out of scope here: they need a command-line
// downloader, which belongs to the Mac app or the backend (#72).

import Foundation

/// One podcast episode with a direct link to its audio.
public struct PodcastEpisode: Sendable, Equatable, Hashable, Identifiable {
    public var id: URL { audioURL }
    public let title: String
    /// The show's name, when the link or feed says it.
    public let show: String?
    public let audioURL: URL
    public let published: Date?
    public let durationSeconds: Int?
    /// From the feed's `<enclosure length>`; the download learns the real size anyway.
    public let sizeBytes: Int64?

    public init(title: String, show: String? = nil, audioURL: URL, published: Date? = nil,
                durationSeconds: Int? = nil, sizeBytes: Int64? = nil) {
        self.title = title
        self.show = show
        self.audioURL = audioURL
        self.published = published
        self.durationSeconds = durationSeconds
        self.sizeBytes = sizeBytes
    }
}

/// What a pasted link turned out to be.
public enum LinkResolution: Sendable, Equatable {
    /// An episode page, an Apple Podcasts episode link or a direct audio link.
    case episode(PodcastEpisode)
    /// A show (a feed, or a show page): the user picks an episode. Newest first.
    case show(title: String, episodes: [PodcastEpisode])
}

/// Why a link could not be imported. `userText` is what the import sheet shows.
public enum LinkImportError: Error, Equatable, Sendable {
    /// The pasted text holds no http(s) link.
    case noLink
    /// A video site: needs a downloader that only the Mac app or the backend can run (#72).
    case videoSite
    /// This phone has no usable connection (no network, or 无线数据 turned off for the app).
    case offline
    /// The host did not answer: DNS, TLS, timeout.
    case unreachable(String)
    /// 401 or 403: the content is behind a login or a paywall. Never worked around.
    case needsLogin
    /// 404 or 410.
    case notFound
    case http(Int)
    /// The page, feed or lookup holds no audio we can download.
    case noAudio
    /// The audio is larger than `EpisodeDownloader.maximumBytes`.
    case tooLarge
    /// Not enough free space on this phone for the download.
    case noSpace
    /// The download is not audio the phone can read.
    case notAudio
}

extension LinkImportError {
    public var userText: String {
        switch self {
        case .noLink: "没有找到链接。请粘贴以 http 开头的播客单集链接、节目的 RSS 地址或音频文件地址"
        case .videoSite: "暂时不能导入视频网站的链接，目前只支持播客"
        case .offline: "这部手机连不上网，请检查网络或「设置 › 闻笺 › 无线数据」"
        case .unreachable: "打不开这个链接，请检查链接或稍后再试"
        case .needsLogin: "这个链接要登录或付费才能收听，闻笺不能导入"
        case .notFound: "链接指向的页面不存在了"
        case .http(let code): "打开链接失败（错误 \(code)）"
        case .noAudio: "这个页面里没有找到能下载的音频。请换成播客单集的链接、节目的 RSS 地址或音频文件地址"
        case .tooLarge: "音频超过 1 GB，不能导入"
        case .noSpace: "手机存储空间不足，清理后再试"
        case .notAudio: "下载的文件不是能识别的音频"
        }
    }

    /// Maps a URLSession failure the way `AssistantError.network` does: no connection reads as
    /// advice, anything else as a host that does not answer.
    public static func network(_ error: Error) -> LinkImportError {
        if let own = error as? LinkImportError { return own }
        switch (error as? URLError)?.code {
        case .notConnectedToInternet?, .dataNotAllowed?, .internationalRoamingOff?: return .offline
        default: return .unreachable(error.localizedDescription)
        }
    }

    /// An HTTP status that is not a success.
    static func status(_ code: Int) -> LinkImportError? {
        switch code {
        case 200..<300: nil
        case 401, 402, 403: .needsLogin
        case 404, 410: .notFound
        default: .http(code)
        }
    }
}
