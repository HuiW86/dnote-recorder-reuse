import Foundation
import Library
import LinkImport
import Observation
import Player

/// 从链接导入 (features.md X12, iPhone part; product-spec.md P05 导入): a podcast episode link, a
/// show's feed or an audio link becomes a recording with source `.import`. Only the link the user
/// pasted is contacted (plus Apple's lookup for Apple Podcasts links); nothing about the library
/// is sent. Has nothing to do with the card.
@MainActor
@Observable
public final class LinkImportModel {
    public enum Phase: Equatable {
        case idle
        /// Reading the link.
        case resolving
        /// A show: the user picks one episode.
        case choosing(show: String, episodes: [PodcastEpisode])
        case downloading(PodcastEpisode, received: Int64, total: Int64?)
        /// Converting and storing the download.
        case saving(PodcastEpisode)
        /// Stored as this recording, under this title.
        case done(id: UUID, title: String)
        case failed(String)
    }

    /// Shown under the field: the feature is for content the user may use (#72 约束).
    public static let rightsNotice = "只导入你有权使用的公开内容。闻笺只下载链接里公开的音频，不能导入要登录或付费的节目。"
    /// Shown under the field: what is contacted.
    public static let privacyNotice = "闻笺会直接访问这个链接；Apple 播客的链接会向 Apple 查询单集地址。录音库里的内容不会发出去。"

    public var text = ""
    public private(set) var phase: Phase = .idle

    @ObservationIgnored private let library: RecordingLibrary
    @ObservationIgnored private let resolver: LinkResolving
    @ObservationIgnored private let downloader: EpisodeDownloading
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var work: Task<Void, Never>?
    /// The run allowed to change `phase`: a cancelled run that finishes late changes nothing.
    @ObservationIgnored private var run = UUID()

    /// Tests pass stubs for the network; the download is stored with the same `AudioImporter` as
    /// a pick from Files (features.md E2).
    public init(library: RecordingLibrary, resolver: LinkResolving? = nil, downloader: EpisodeDownloading? = nil,
                now: @escaping () -> Date = { Date() }) {
        self.library = library
        self.resolver = resolver ?? LinkResolver()
        let store = library.store
        self.downloader = downloader ?? EpisodeDownloader(freeSpace: { store.availableCapacity() })
        self.now = now
    }

    /// The field holds something that could be a link.
    public var canSubmit: Bool {
        !isBusy && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public var isBusy: Bool {
        switch phase {
        case .resolving, .downloading, .saving: true
        default: false
        }
    }

    /// Reads the pasted link: one episode is imported right away, a show is offered to pick from.
    public func submit() {
        guard canSubmit else { return }
        let text = text
        let run = startRun()
        phase = .resolving
        work = Task { [weak self] in
            guard let self else { return }
            do {
                let resolution = try await resolver.resolve(text)
                guard run == self.run else { return }
                switch resolution {
                case .episode(let episode):
                    await self.download(episode, run: run)
                case .show(let title, let episodes):
                    phase = .choosing(show: title, episodes: Array(episodes.prefix(Self.listedEpisodes)))
                }
            } catch {
                finish(error, run: run)
            }
        }
    }

    /// At most this many episodes of a show are listed; older ones are imported by their own link.
    public static let listedEpisodes = 100

    public func choose(_ episode: PodcastEpisode) {
        guard case .choosing = phase else { return }
        let run = startRun()
        // Set now, so a second tap on the list does nothing.
        phase = .downloading(episode, received: 0, total: episode.sizeBytes)
        work = Task { [weak self] in await self?.download(episode, run: run) }
    }

    /// Stops a running import; nothing is stored.
    public func cancel() {
        work?.cancel()
        work = nil
        run = UUID()
        if isBusy { phase = .idle }
    }

    private func startRun() -> UUID {
        work?.cancel()
        run = UUID()
        return run
    }

    /// Back to an empty field after a failure or an import, for another link.
    public func reset() {
        cancel()
        phase = .idle
    }

    /// Waits for the work `submit` or `choose` started (tests).
    public func waitForWork() async {
        await work?.value
    }

    /// "12.3 MB / 45.6 MB", "12.3 MB".
    public var progressText: String? {
        guard case .downloading(_, let received, let total) = phase else { return nil }
        let format = ByteCountFormatter()
        format.countStyle = .file
        let got = format.string(fromByteCount: received)
        return total.map { "\(got) / \(format.string(fromByteCount: $0))" } ?? got
    }

    public var progressFraction: Double? {
        guard case .downloading(_, let received, let total?) = phase, total > 0 else { return nil }
        return min(1, Double(received) / Double(total))
    }

    private func download(_ episode: PodcastEpisode, run: UUID) async {
        phase = .downloading(episode, received: 0, total: episode.sizeBytes)
        var downloaded: URL?
        defer { if let downloaded { try? FileManager.default.removeItem(at: downloaded.deletingLastPathComponent()) } }
        do {
            let file = try await downloader.download(episode.audioURL) { [weak self] received, total in
                Task { @MainActor in
                    guard let self, self.run == run, case .downloading(let current, _, let known) = self.phase,
                          current == episode else { return }
                    self.phase = .downloading(episode, received: received, total: total ?? known)
                }
            }
            downloaded = file
            try Task.checkCancellation()
            guard run == self.run else { return }
            phase = .saving(episode)
            let prepared: AudioImporter.Prepared
            do {
                prepared = try await AudioImporter.prepare(file)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw LinkImportError.notAudio
            }
            defer { try? FileManager.default.removeItem(at: prepared.file.deletingLastPathComponent()) }
            try Task.checkCancellation()
            guard run == self.run else { return }
            // Import time, not the episode's date: the recording appears at the top of 录音.
            let recording = try library.addLocalRecording(file: prepared.file, source: .import, startedAt: now(),
                                                          durationMs: prepared.durationMs, title: episode.title)
            phase = .done(id: recording.id, title: recording.title)
        } catch {
            finish(error, run: run)
        }
    }

    private func finish(_ error: Error, run: UUID) {
        guard run == self.run else { return }
        if error is CancellationError || Task.isCancelled {
            phase = .idle
            return
        }
        phase = .failed((error as? LinkImportError)?.userText ?? "导入失败，请重试")
    }
}
