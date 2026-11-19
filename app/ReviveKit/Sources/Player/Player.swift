// Playback and OGG export of stored recordings (features.md E1a).
//
// AVAudioPlayer reads the OGG Opus files directly on iOS 27 / macOS 27 (T-M1-04). Where it
// cannot (older systems, unverified), the file is decoded once to a PCM CAF under the library
// (`decoded/`, removed with the recording) and that copy is played instead (OggOpusDecoder).

import AVFoundation
import Foundation
import Library
import Observation

public enum PlayerError: Error, Equatable, Sendable {
    /// The OGG file is missing (deleted, or the library was restored without audio).
    case audioMissing
    /// The system player could not open the file.
    case cannotOpen
}

@MainActor
@Observable
public final class RecordingPlayer: NSObject {
    public enum State: Equatable, Sendable {
        case idle, playing, paused
    }

    public private(set) var state: State = .idle
    /// Recording loaded in the player, if any.
    public private(set) var recordingId: UUID?
    public private(set) var duration: TimeInterval = 0
    /// Read on demand (e.g. from a TimelineView); not observed.
    public var currentTime: TimeInterval { player?.currentTime ?? 0 }

    @ObservationIgnored private let library: RecordingLibrary
    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    /// Bumped by every load and stop, so a decode that finishes late does not take over.
    @ObservationIgnored private var loadToken = 0
    /// Turned off by tests and the debug screen to exercise the decode fallback on systems that
    /// open OGG directly. Takes effect on the next load (a different recording, or after `stop`).
    @ObservationIgnored public var opensOggDirectly = true

    public init(library: RecordingLibrary) {
        self.library = library
        super.init()
        observeSession()
    }

    /// Plays `recording` from the start, or resumes it if it is already loaded.
    /// The first play may decode the file off the main thread (see the file header). Throws
    /// `CancellationError` if `stop` or another `play` comes in while that decode is running.
    public func play(_ recording: Recording) async throws {
        if recordingId != recording.id || player == nil {
            try await load(recording)
        }
        try activateSession()
        player?.play()
        state = .playing
    }

    public func pause() {
        player?.pause()
        if state == .playing { state = .paused }
    }

    public func seek(to time: TimeInterval) {
        guard let player else { return }
        player.currentTime = min(max(0, time), player.duration)
    }

    public func stop() {
        loadToken += 1
        player?.stop()
        player = nil
        recordingId = nil
        duration = 0
        state = .idle
    }

    /// Playback speed, kept for the next recording too (design-spec.md §3 播放条).
    public private(set) var rate: Float = 1

    public func setRate(_ newRate: Float) {
        rate = newRate
        player?.rate = newRate
    }

    /// Used by tests to keep the speakers quiet.
    public var volume: Float {
        get { player?.volume ?? 1 }
        set { player?.volume = newValue }
    }

    private func load(_ recording: Recording) async throws {
        stop()
        let token = loadToken
        let url = library.store.url(forAudioPath: recording.audioPath)
        guard FileManager.default.fileExists(atPath: url.path) else { throw PlayerError.audioMissing }
        let p: AVAudioPlayer
        // Only OGG may need decoding; a phone recording's M4A always opens directly.
        if opensOggDirectly || url.pathExtension.lowercased() != "ogg",
           let direct = try? AVAudioPlayer(contentsOf: url), direct.duration > 0 {
            p = direct
        } else {
            let decoded = library.store.decodedURL(for: recording.id)
            if !FileManager.default.fileExists(atPath: decoded.path) {
                do {
                    try await Task.detached(priority: .userInitiated) {
                        try OggOpusDecoder.decode(url, to: decoded)
                    }.value
                } catch {
                    throw PlayerError.cannotOpen
                }
                // Another play or a stop came in while decoding.
                guard token == loadToken else { throw CancellationError() }
            }
            do {
                p = try AVAudioPlayer(contentsOf: decoded)
            } catch {
                // Do not keep a bad copy around; the next play decodes again.
                try? FileManager.default.removeItem(at: decoded)
                throw PlayerError.cannotOpen
            }
        }
        p.delegate = self
        p.enableRate = true
        p.rate = rate
        p.prepareToPlay()
        player = p
        recordingId = recording.id
        duration = p.duration
    }

    // MARK: Audio session (background playback; UIBackgroundModes has `audio`)

    private func activateSession() throws {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .spokenAudio)
        try session.setActive(true)
        #endif
    }

    private func observeSession() {
        #if os(iOS)
        let center = NotificationCenter.default
        // A call or another app took the audio; do not resume on our own afterwards.
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil,
                                            queue: .main) { [weak self] note in
            let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt)
                .flatMap(AVAudioSession.InterruptionType.init)
            guard type == .began else { return }
            MainActor.assumeIsolated { self?.pause() }
        })
        // Headphones unplugged: pause instead of playing out loud.
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil,
                                            queue: .main) { [weak self] note in
            let reason = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt)
                .flatMap(AVAudioSession.RouteChangeReason.init)
            guard reason == .oldDeviceUnavailable else { return }
            MainActor.assumeIsolated { self?.pause() }
        })
        #endif
    }
}

extension RecordingPlayer: AVAudioPlayerDelegate {
    nonisolated public func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        MainActor.assumeIsolated {
            self.player?.currentTime = 0
            state = .idle
        }
    }

    nonisolated public func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        MainActor.assumeIsolated { stop() }
    }
}

/// Copies a recording's OGG to a temporary file named after its title, for the share sheet.
public enum RecordingExporter {
    /// `title` names the file; nil uses the stored title.
    public static func exportFile(for recording: Recording, library: RecordingLibrary,
                                  title: String? = nil) throws -> URL {
        let source = library.store.url(forAudioPath: recording.audioPath)
        guard FileManager.default.fileExists(atPath: source.path) else { throw PlayerError.audioMissing }
        // One directory per export so two recordings with the same title do not collide.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("export", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // OGG for card recordings, M4A for phone ones (features.md X18): keep what is stored.
        let ext = source.pathExtension.isEmpty ? "ogg" : source.pathExtension
        let target = dir.appendingPathComponent(fileName(for: title ?? recording.title, fileExtension: ext))
        try FileManager.default.copyItem(at: source, to: target)
        return target
    }

    /// An AAC `.m4a` copy for the share sheet (features.md E1b): other apps and older systems do
    /// not open OGG Opus. Decodes and encodes off the main actor; a long recording takes a while.
    /// The recording as a PCM file the system frameworks can read (the decoded copy the player
    /// also uses), made if it is not there yet. For speech recognition (features.md X9).
    public static func decodedPCM(for recording: Recording, library: RecordingLibrary) async throws -> URL {
        let source = library.store.url(forAudioPath: recording.audioPath)
        guard FileManager.default.fileExists(atPath: source.path) else { throw PlayerError.audioMissing }
        // A phone recording is already AAC, which the system reads as it is.
        if source.pathExtension.lowercased() != "ogg" { return source }
        let decoded = library.store.decodedURL(for: recording.id)
        if !FileManager.default.fileExists(atPath: decoded.path) {
            do { try OggOpusDecoder.decode(source, to: decoded) } catch { throw PlayerError.cannotOpen }
        }
        return decoded
    }

    /// `base` is where the export directory is made; the default is the one `cleanUp` empties.
    public static func exportM4A(for recording: Recording, library: RecordingLibrary,
                                 title: String? = nil, in base: URL? = nil) async throws -> URL {
        let source = library.store.url(forAudioPath: recording.audioPath)
        guard FileManager.default.fileExists(atPath: source.path) else { throw PlayerError.audioMissing }
        let dir = (base ?? FileManager.default.temporaryDirectory.appendingPathComponent("export", isDirectory: true))
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // A phone recording is already M4A: copy it as it is.
        if source.pathExtension.lowercased() == "m4a" {
            let target = dir.appendingPathComponent(fileName(for: title ?? recording.title, fileExtension: "m4a"))
            try FileManager.default.copyItem(at: source, to: target)
            return target
        }
        let pcm = dir.appendingPathComponent("decoded.caf")
        defer { try? FileManager.default.removeItem(at: pcm) }
        try OggOpusDecoder.decode(source, to: pcm)
        let target = dir.appendingPathComponent(fileName(for: title ?? recording.title, fileExtension: "m4a"))
        // Scoped so both files are closed, and the m4a finished, before the URL is returned.
        do {
            let input = try AVAudioFile(forReading: pcm)
            let format = input.processingFormat
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: format.sampleRate,
                AVNumberOfChannelsKey: Int(format.channelCount),
            ]
            let output = try AVAudioFile(forWriting: target, settings: settings, commonFormat: format.commonFormat,
                                         interleaved: format.isInterleaved)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16384) else {
                throw PlayerError.cannotOpen
            }
            while input.framePosition < input.length {
                try Task.checkCancellation()
                try input.read(into: buffer)
                if buffer.frameLength == 0 { break }
                try output.write(from: buffer)
            }
        }
        return target
    }

    /// `2026-11-01 09:00` -> `2026-11-01 09.00.ogg`; characters file systems reject are replaced.
    public static func fileName(for title: String, fileExtension: String = "ogg") -> String {
        let cleaned = title
            .replacingOccurrences(of: ":", with: ".")
            .map { "/\\?%*|\"<>".contains($0) || $0.isNewline ? "_" : $0 }
        let base = String(cleaned).trimmingCharacters(in: .whitespaces)
        return (base.isEmpty ? "recording" : String(base.prefix(100))) + "." + fileExtension
    }

    /// Removes exported copies; call when the share sheet closes or at launch.
    public static func cleanUp() {
        try? FileManager.default.removeItem(
            at: FileManager.default.temporaryDirectory.appendingPathComponent("export", isDirectory: true))
    }
}
