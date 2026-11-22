import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Downloads an episode's audio into a temporary file. Tests pass a stub.
public protocol EpisodeDownloading: Sendable {
    /// `progress` gets bytes received and the total when the server says it. The file's extension
    /// names its format; the caller removes its folder once imported.
    func download(_ url: URL, progress: @escaping @Sendable (Int64, Int64?) -> Void) async throws -> URL
}

/// Streams the reply into a file as it arrives, so the size cap, the space check and progress
/// all see every chunk, and a page served instead of audio is refused before anything is written.
/// `@unchecked`: every property is a constant; `URLSession` copies the configuration.
public final class EpisodeDownloader: EpisodeDownloading, @unchecked Sendable {
    /// About 18 hours of 128 kbit/s MP3; anything larger is not a podcast episode.
    public static let maximumBytes: Int64 = 1_000_000_000
    /// Free bytes kept after a download: the library still has to copy or convert it.
    public static let spareBytes: Int64 = 200_000_000

    private let configuration: URLSessionConfiguration
    private let limit: Int64
    private let freeSpace: @Sendable () -> Int64?

    /// `freeSpace`: bytes free where the download lands; nil skips the check. Tests pass a
    /// configuration with a stub `URLProtocol` and a lower `limit`.
    public init(configuration: URLSessionConfiguration? = nil, limit: Int64 = EpisodeDownloader.maximumBytes,
                freeSpace: @escaping @Sendable () -> Int64? = { nil }) {
        self.configuration = configuration ?? URLSessionFetcher.makeConfiguration()
        self.limit = limit
        self.freeSpace = freeSpace
    }

    public func download(_ url: URL, progress: @escaping @Sendable (Int64, Int64?) -> Void) async throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("link-\(UUID().uuidString)",
                                                                                 isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let job = Job(url: url, dir: dir, limit: limit, freeSpace: freeSpace, progress: progress)
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        // The session keeps its delegate until invalidated; `finish` does that.
        let session = URLSession(configuration: configuration, delegate: job, delegateQueue: queue)
        do {
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    job.start(session: session, continuation: continuation)
                }
            } onCancel: {
                job.stop(because: nil)
            }
        } catch {
            try? FileManager.default.removeItem(at: dir)
            throw error
        }
    }

    /// One download: its file, its counts, and why it stopped. Delegate calls arrive on one serial
    /// queue; `stop` can come from any thread, so shared state is behind a lock.
    private final class Job: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        let url: URL
        let dir: URL
        let limit: Int64
        let freeSpace: @Sendable () -> Int64?
        let progress: @Sendable (Int64, Int64?) -> Void

        private let lock = NSLock()
        private var continuation: CheckedContinuation<URL, Error>?
        private var task: URLSessionDataTask?
        private var session: URLSession?
        private var reason: LinkImportError?
        private var stopped = false
        // Delegate queue only.
        private var file: FileHandle?
        private var target: URL?
        private var received: Int64 = 0
        private var expected: Int64?

        init(url: URL, dir: URL, limit: Int64, freeSpace: @escaping @Sendable () -> Int64?,
             progress: @escaping @Sendable (Int64, Int64?) -> Void) {
            self.url = url
            self.dir = dir
            self.limit = limit
            self.freeSpace = freeSpace
            self.progress = progress
        }

        func start(session: URLSession, continuation: CheckedContinuation<URL, Error>) {
            var request = URLRequest(url: LinkText.secure(url))
            request.setValue("audio/*,*/*;q=0.8", forHTTPHeaderField: "Accept")
            let task = session.dataTask(with: request)
            let cancelled = lock.withLock { () -> Bool in
                self.continuation = continuation
                self.task = task
                self.session = session
                return stopped
            }
            if cancelled {
                finish(.failure(CancellationError()))
            } else {
                task.resume()
            }
        }

        /// `reason` nil: the caller cancelled. Otherwise this code refused the download.
        func stop(because reason: LinkImportError?) {
            let task = lock.withLock { () -> URLSessionDataTask? in
                if !stopped { self.reason = reason }
                stopped = true
                return self.task
            }
            task?.cancel()
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            if lock.withLock({ stopped }) { return }
            if file == nil {
                if let refusal = check(dataTask.response) {
                    stop(because: refusal)
                    return
                }
                do { try open(dataTask.response) } catch {
                    stop(because: .noSpace)
                    return
                }
            }
            received += Int64(data.count)
            if received > limit {
                stop(because: .tooLarge)
                return
            }
            do { try file?.write(contentsOf: data) } catch {
                stop(because: .noSpace)
                return
            }
            progress(received, expected)
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            try? file?.close()
            file = nil
            let refused = lock.withLock { stopped ? (reason.map { $0 as Error } ?? CancellationError()) : nil }
            if let refused {
                finish(.failure(refused))
            } else if let error {
                finish(.failure(LinkImportError.network(error)))
            } else if let refusal = check(task.response) {
                finish(.failure(refusal))
            } else if let target {
                finish(.success(target))
            } else {
                // A 200 with no body.
                finish(.failure(LinkImportError.notAudio))
            }
        }

        /// Why this reply cannot be the episode's audio; nil when it can.
        private func check(_ response: URLResponse?) -> LinkImportError? {
            guard let http = response as? HTTPURLResponse else { return nil }
            if let failure = LinkImportError.status(http.statusCode) { return failure }
            // A page instead of audio: the link expired, or wants a login.
            if let type = http.value(forHTTPHeaderField: "Content-Type"), LinkText.mimeType(type).hasPrefix("text/") {
                return .notAudio
            }
            let length = http.expectedContentLength
            if length > limit { return .tooLarge }
            if length > 0, let free = freeSpace(), free - length < EpisodeDownloader.spareBytes { return .noSpace }
            return nil
        }

        private func open(_ response: URLResponse?) throws {
            let http = response as? HTTPURLResponse
            let length = response?.expectedContentLength ?? -1
            expected = length > 0 ? length : nil
            let ext = LinkText.fileExtension(contentType: http?.value(forHTTPHeaderField: "Content-Type"),
                                             url: response?.url ?? url)
            let target = dir.appendingPathComponent("episode.\(ext)")
            guard FileManager.default.createFile(atPath: target.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown)
            }
            file = try FileHandle(forWritingTo: target)
            self.target = target
        }

        private func finish(_ result: Result<URL, Error>) {
            let (continuation, session) = lock.withLock { () -> (CheckedContinuation<URL, Error>?, URLSession?) in
                defer {
                    self.continuation = nil
                    self.session = nil
                }
                return (self.continuation, self.session)
            }
            session?.finishTasksAndInvalidate()
            continuation?.resume(with: result)
        }
    }
}
