import AVFoundation
import CardProtocol
import CardTestSupport
import Foundation
import Library
@testable import Player
import Testing

// Playback and export (features.md E1a, #40).

@MainActor
private final class Fixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("player-\(UUID().uuidString)")
    let library: RecordingLibrary
    let recording: Recording
    let ogg: Data
    let packets: Int

    init(seconds: Int = 2, title: String = "2026-11-01 09:00") throws {
        library = RecordingLibrary(database: try AppDatabase.inMemory(), store: try AudioStore(root: root))
        let frames = try SyntheticOpus.sine(seconds: seconds)
        packets = frames.count
        ogg = OggOpus.wrap(frames)
        let id = UUID()
        let path = try library.store.storeAudio(ogg, id: id)
        recording = Recording(id: id, deviceId: nil, source: .card, cardFileName: "20261101090000.opus",
                              cardFileSize: ogg.count, startedAt: Date(), durationMs: frames.count * 20,
                              audioPath: path, audioSha256: "", title: title, createdAt: Date(), updatedAt: Date())
    }

    deinit { try? FileManager.default.removeItem(at: root) }
}

@MainActor
struct PlayerTests {
    @Test func playsPausesSeeks() async throws {
        let f = try Fixture()
        let player = RecordingPlayer(library: f.library)
        try await player.play(f.recording)
        player.volume = 0
        #expect(player.state == .playing)
        #expect(player.recordingId == f.recording.id)
        // 20 ms per packet, minus the 312-sample pre-skip at 48 kHz (T-M1-04).
        #expect(abs(player.duration - (Double(f.packets) * 0.02 - 312.0 / 48000)) < 0.002)

        player.pause()
        #expect(player.state == .paused)
        player.seek(to: 1.0)
        #expect(abs(player.currentTime - 1.0) < 0.05)
        player.seek(to: 99)
        #expect(player.currentTime <= player.duration)

        try await player.play(f.recording)  // same recording: resume, not reload
        player.volume = 0
        #expect(player.state == .playing)
        player.stop()
        #expect(player.state == .idle && player.recordingId == nil)
    }

    @Test func reachesEndAndResets() async throws {
        let f = try Fixture(seconds: 1)
        let player = RecordingPlayer(library: f.library)
        try await player.play(f.recording)
        player.volume = 0
        player.seek(to: player.duration - 0.1)
        let deadline = ContinuousClock.now + .seconds(3)
        while player.state == .playing, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(player.state == .idle)
        #expect(player.currentTime < 0.05)
    }

    @Test func missingAudioIsReported() async throws {
        let f = try Fixture()
        f.library.store.removeAudio(f.recording.audioPath)
        let player = RecordingPlayer(library: f.library)
        await #expect(throws: PlayerError.audioMissing) { try await player.play(f.recording) }
        #expect(throws: PlayerError.audioMissing) {
            _ = try RecordingExporter.exportFile(for: f.recording, library: f.library)
        }
    }

    // Systems that cannot open OGG directly: decode to CAF, same duration, decoded once.
    @Test func decodesWhenDirectOpenIsUnavailable() async throws {
        let f = try Fixture()
        let player = RecordingPlayer(library: f.library)
        player.opensOggDirectly = false
        try await player.play(f.recording)
        player.volume = 0
        #expect(player.state == .playing)
        #expect(abs(player.duration - (Double(f.packets) * 0.02 - 312.0 / 48000)) < 0.002)

        let decoded = f.library.store.decodedURL(for: f.recording.id)
        let pcm = try AVAudioFile(forReading: decoded)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: pcm.processingFormat,
                                                   frameCapacity: AVAudioFrameCount(pcm.length)))
        try pcm.read(into: buffer)
        let samples = UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength))
        // The 0.3-amplitude sine survives decoding (not silence, not clipped).
        let peak = samples.map(abs).max() ?? 0
        #expect(peak > 0.2 && peak < 0.5)

        let modified = try FileManager.default.attributesOfItem(atPath: decoded.path)[.modificationDate] as? Date
        player.stop()
        try await player.play(f.recording)
        player.volume = 0
        #expect(try FileManager.default.attributesOfItem(atPath: decoded.path)[.modificationDate] as? Date == modified)
        player.stop()
    }

    // A second play while the first is still decoding: the first gives way, the cache is whole.
    @Test func overlappingPlaysWhileDecoding() async throws {
        let f = try Fixture()
        let player = RecordingPlayer(library: f.library)
        player.opensOggDirectly = false
        async let first: Void = player.play(f.recording)
        async let second: Void = player.play(f.recording)
        var succeeded = 0
        do { try await first; succeeded += 1 } catch { #expect(error is CancellationError, "first: \(error)") }
        do { try await second; succeeded += 1 } catch { #expect(error is CancellationError, "second: \(error)") }
        player.volume = 0
        #expect(succeeded == 1)
        #expect(player.state == .playing)
        #expect(abs(player.duration - (Double(f.packets) * 0.02 - 312.0 / 48000)) < 0.002)
        let leftovers = try FileManager.default.contentsOfDirectory(
            atPath: f.library.store.decodedURL(for: f.recording.id).deletingLastPathComponent().path)
        #expect(leftovers == ["\(f.recording.id.uuidString).caf"])
        player.stop()
    }

    @Test func undecodableAudioIsReported() async throws {
        let f = try Fixture()
        try Data("not an ogg file".utf8).write(to: f.library.store.url(forAudioPath: f.recording.audioPath))
        let player = RecordingPlayer(library: f.library)
        await #expect(throws: PlayerError.cannotOpen) { try await player.play(f.recording) }
        #expect(player.state == .idle)
    }

    @Test func demuxReadsHeadAndPackets() throws {
        let frames = (0..<120).map { Data(repeating: UInt8($0), count: $0 % 3 == 0 ? 300 : 40) }
        let (head, packets) = try OggOpusDecoder.demux(OggOpus.wrap(frames))
        #expect(head == .init(channels: 1, preSkip: 312, inputRate: 16000))
        #expect(packets == frames)  // includes packets over 255 bytes, which span lacing values
        let (_, withGap) = try OggOpusDecoder.demux(OggOpus.wrap([frames[1], Data(), frames[2]]))
        #expect(withGap == [frames[1], frames[2]])  // empty packets are dropped
        #expect(throws: OggOpusDecoder.DecodeError.self) { try OggOpusDecoder.demux(Data("OggS".utf8)) }
    }

    @Test func exportCopiesUnderTitle() throws {
        let f = try Fixture()
        let a = try RecordingExporter.exportFile(for: f.recording, library: f.library)
        let b = try RecordingExporter.exportFile(for: f.recording, library: f.library)
        #expect(a.lastPathComponent == "2026-11-01 09.00.ogg")
        #expect(a != b)  // same title twice does not collide
        #expect(try Data(contentsOf: a) == f.ogg)
        // Evidence for #40: keep a copy for ffprobe when asked (evidence/v40-player/README.md).
        if let dir = ProcessInfo.processInfo.environment["REVIVE_EXPORT_DIR"] {
            let target = URL(fileURLWithPath: dir).appendingPathComponent(a.lastPathComponent)
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.copyItem(at: a, to: target)
        }
        RecordingExporter.cleanUp()
        #expect(!FileManager.default.fileExists(atPath: a.path))
    }

    @Test(arguments: [
        ("2026-11-01 09:00", "2026-11-01 09.00.ogg"),
        ("a/b\\c?d", "a_b_c_d.ogg"),
        ("   ", "recording.ogg"),
        ("会议 记录", "会议 记录.ogg"),
    ])
    func fileNames(title: String, expected: String) {
        #expect(RecordingExporter.fileName(for: title) == expected)
    }
}
