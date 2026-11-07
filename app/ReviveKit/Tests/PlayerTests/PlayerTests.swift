import CardProtocol
import CardTestSupport
import Foundation
import Library
import Player
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
    @Test func playsPausesSeeks() throws {
        let f = try Fixture()
        let player = RecordingPlayer(library: f.library)
        try player.play(f.recording)
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

        try player.play(f.recording)  // same recording: resume, not reload
        player.volume = 0
        #expect(player.state == .playing)
        player.stop()
        #expect(player.state == .idle && player.recordingId == nil)
    }

    @Test func reachesEndAndResets() async throws {
        let f = try Fixture(seconds: 1)
        let player = RecordingPlayer(library: f.library)
        try player.play(f.recording)
        player.volume = 0
        player.seek(to: player.duration - 0.1)
        let deadline = ContinuousClock.now + .seconds(3)
        while player.state == .playing, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(player.state == .idle)
        #expect(player.currentTime < 0.05)
    }

    @Test func missingAudioIsReported() throws {
        let f = try Fixture()
        f.library.store.removeAudio(f.recording.audioPath)
        let player = RecordingPlayer(library: f.library)
        #expect(throws: PlayerError.audioMissing) { try player.play(f.recording) }
        #expect(throws: PlayerError.audioMissing) {
            _ = try RecordingExporter.exportFile(for: f.recording, library: f.library)
        }
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
