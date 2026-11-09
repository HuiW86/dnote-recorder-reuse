import AppModel
import CardProtocol
import CardTestSupport
import Foundation
import Library
import Player
import SyncEngine
import Testing

// Recording detail (product-spec.md P06) on a synthetic recording.

@MainActor
private final class DetailFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("detail-\(UUID().uuidString)")
    let library: RecordingLibrary
    let player: RecordingPlayer
    let recording: Recording

    init(audio: Data? = nil) async throws {
        library = RecordingLibrary(database: try AppDatabase.inMemory(), store: try AudioStore(root: root))
        player = RecordingPlayer(library: library)
        let frames = try SyntheticOpus.sine(seconds: 2)
        let data = audio ?? OggOpus.wrap(frames)
        let id = UUID()
        let path = try library.store.storeAudio(data, id: id)
        let start = try #require(SyncEngine.startDate(fileName: "20261107140211.opus"))
        let r = Recording(id: id, deviceId: nil, source: .card, cardFileName: "20261107140211.opus",
                          cardFileSize: data.count, startedAt: start, durationMs: frames.count * 20,
                          audioPath: path, audioSha256: "", title: "2026-11-07 14:02", createdAt: start, updatedAt: start)
        try await library.database.writer.write { try r.insert($0) }
        recording = r
    }

    deinit { try? FileManager.default.removeItem(at: root) }
}

@MainActor
struct RecordingDetailModelTests {
    @Test func playSkipPauseThenDelete() async throws {
        let f = try await DetailFixture()
        let model = RecordingDetailModel(recordingId: f.recording.id, library: f.library, player: f.player)
        #expect(model.title == "11月7日 14:02")
        #expect(model.startedAtText == "2026-11-07 14:02:11")
        #expect(model.durationText == "2 秒")
        #expect(!model.audioMissing)

        model.togglePlay()
        await waitUntil("playing") { model.isPlaying }
        f.player.volume = 0
        #expect(abs(model.duration - 2) < 0.05)
        model.skip(by: 15)
        #expect(model.currentTime <= model.duration)
        model.skip(by: -15)
        #expect(model.currentTime < 0.1)
        model.togglePlay()
        #expect(!model.isPlaying && f.player.state == .paused)

        model.delete()
        #expect(model.isDeleted)
        #expect(f.player.state == .idle)
        #expect(try f.library.recording(id: f.recording.id) == nil)
        #expect(!FileManager.default.fileExists(atPath: f.library.store.url(forAudioPath: f.recording.audioPath).path))
    }

    @Test func missingAudioIsShownNotPlayed() async throws {
        let f = try await DetailFixture()
        try FileManager.default.removeItem(at: f.library.store.url(forAudioPath: f.recording.audioPath))
        let model = RecordingDetailModel(recordingId: f.recording.id, library: f.library, player: f.player)
        #expect(model.audioMissing)
        #expect(model.exportFile() == nil)
    }

    @Test func unplayableFileToasts() async throws {
        let f = try await DetailFixture(audio: Data(repeating: 0x5A, count: 4000))
        let model = RecordingDetailModel(recordingId: f.recording.id, library: f.library, player: f.player)
        model.togglePlay()
        await waitUntil("toast") { model.toast != nil }
        #expect(model.toast?.text == "无法播放这条录音")
        #expect(!model.isPlaying && !model.isPreparing)
    }

    @Test func exportsUnderTitle() async throws {
        let f = try await DetailFixture()
        let model = RecordingDetailModel(recordingId: f.recording.id, library: f.library, player: f.player)
        let url = try #require(model.exportFile())
        #expect(url.lastPathComponent == "2026-11-07 14.02.ogg")
        RecordingExporter.cleanUp()
    }
}
