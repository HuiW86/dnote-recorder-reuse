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
        // Patient, like `waitUntil` in AppModelTests: in a parallel run on CI the main actor,
        // where the end of playback is handled, stays busy for seconds at the start; 3 s ran
        // out there (PR #109, failed at 3.8 s). Playback that ends returns at once.
        let deadline = ContinuousClock.now + .seconds(30)
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

    /// E1b: the M4A copy opens with the system reader and is as long as the recording.
    /// Speed is kept across recordings and applied to the one playing.
    @Test func rateIsKeptAndApplied() async throws {
        let f = try Fixture()
        let player = RecordingPlayer(library: f.library)
        player.setRate(1.5)
        try await player.play(f.recording)
        player.volume = 0
        #expect(player.rate == 1.5)
        player.setRate(1)
        #expect(player.rate == 1)
        player.stop()
    }

    @Test func exportsM4A() async throws {
        let f = try Fixture()
        // Its own directory: other tests call `cleanUp`, which empties the shared one while this
        // test is suspended in the export.
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("m4a-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let url = try await RecordingExporter.exportM4A(for: f.recording, library: f.library, in: base)
        #expect(url.lastPathComponent == "2026-11-01 09.00.m4a")
        let file = try AVAudioFile(forReading: url)
        let seconds = Double(file.length) / file.fileFormat.sampleRate
        #expect(abs(seconds - 2) < 0.2, "seconds \(seconds)")
        // Only the m4a is left in the export directory.
        let siblings = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
        #expect(siblings == [url.lastPathComponent])
    }

    /// E2 文字文件: a text-only recording is never played or exported as audio; its empty path
    /// must not reach the file system (it would name the whole store).
    @Test func textRecordingHasNoAudioToPlayOrExport() async throws {
        let f = try Fixture()
        let text = try #require(try f.library.addTextRecording(text: "一句话", title: "笔记", startedAt: Date()))
        let player = RecordingPlayer(library: f.library)
        await #expect(throws: PlayerError.audioMissing) { try await player.play(text) }
        #expect(throws: PlayerError.audioMissing) { try RecordingExporter.exportFile(for: text, library: f.library) }
        await #expect(throws: PlayerError.audioMissing) {
            try await RecordingExporter.exportM4A(for: text, library: f.library)
        }
        await #expect(throws: PlayerError.audioMissing) {
            try await RecordingExporter.exportWAV(for: text, library: f.library)
        }
        await #expect(throws: PlayerError.audioMissing) {
            try await RecordingExporter.decodedPCM(for: text, library: f.library)
        }
    }

    /// E1c: the WAV copy is 16-bit PCM at the decoded rate, as long as the recording; a phone
    /// recording's M4A is decoded to WAV too.
    @Test func exportsWAV() async throws {
        let f = try Fixture()
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("wav-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let url = try await RecordingExporter.exportWAV(for: f.recording, library: f.library, title: "周会", in: base)
        #expect(url.lastPathComponent == "周会.wav")
        let header = try Data(contentsOf: url).prefix(12)
        #expect(header.prefix(4) == Data("RIFF".utf8) && header.suffix(4) == Data("WAVE".utf8))
        let file = try AVAudioFile(forReading: url)
        let settings = file.fileFormat.settings
        #expect(settings[AVFormatIDKey] as? UInt32 == kAudioFormatLinearPCM)
        #expect(settings[AVLinearPCMBitDepthKey] as? Int == 16)
        let seconds = Double(file.length) / file.fileFormat.sampleRate
        #expect(abs(seconds - 2) < 0.2, "seconds \(seconds)")
        let siblings = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
        #expect(siblings == [url.lastPathComponent])

        let m4a = try await RecordingExporter.exportM4A(for: f.recording, library: f.library,
                                                        in: base.appendingPathComponent("phone-src"))
        let phone = try f.library.addPhoneRecording(file: m4a, startedAt: Date(), durationMs: 2_000)
        let phoneWAV = try await RecordingExporter.exportWAV(for: phone, library: f.library, in: base)
        let phoneFile = try AVAudioFile(forReading: phoneWAV)
        #expect(phoneFile.fileFormat.settings[AVFormatIDKey] as? UInt32 == kAudioFormatLinearPCM)
        #expect(abs(Double(phoneFile.length) / phoneFile.fileFormat.sampleRate - 2) < 0.2)
    }

    /// X18: a phone recording is shared and transcribed from its own M4A, without decoding.
    @Test func phoneRecordingExportsAsIs() async throws {
        let f = try Fixture()
        let m4a = try await RecordingExporter.exportM4A(for: f.recording, library: f.library,
                                                        in: FileManager.default.temporaryDirectory
                                                            .appendingPathComponent("phone-src-\(UUID().uuidString)"))
        let phone = try f.library.addPhoneRecording(file: m4a, startedAt: Date(), durationMs: 2_000)
        let copy = try RecordingExporter.exportFile(for: phone, library: f.library)
        #expect(copy.pathExtension == "m4a")
        let again = try await RecordingExporter.exportM4A(for: phone, library: f.library,
                                                          in: FileManager.default.temporaryDirectory
                                                              .appendingPathComponent("phone-out-\(UUID().uuidString)"))
        #expect(try Data(contentsOf: again) == (try Data(contentsOf: f.library.store.url(forAudioPath: phone.audioPath))))
        let pcm = try await RecordingExporter.decodedPCM(for: phone, library: f.library)
        #expect(pcm == f.library.store.url(forAudioPath: phone.audioPath))
        let player = RecordingPlayer(library: f.library)
        player.opensOggDirectly = false  // an M4A never goes through the OGG decoder
        try await player.play(phone)
        player.volume = 0
        #expect(player.state == .playing)
        player.stop()
    }

    /// E2: WAV is converted to M4A with its length, OGG Opus is kept, anything else is refused.
    /// Runs the conversion off the main actor: this suite is main-actor isolated, and blocking it
    /// for the AAC encode stalls the card service tests' 2 s request timeouts in parallel suites.
    @Test func importerNormalisesFormats() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("import-src-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let wav = dir.appendingPathComponent("会议.wav")
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1,
                                                interleaved: false))
        do {
            let file = try AVAudioFile(forWriting: wav, settings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16000, AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
            ], commonFormat: .pcmFormatFloat32, interleaved: false)
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 32000))
            buffer.frameLength = 32000
            for i in 0..<32000 { buffer.floatChannelData![0][i] = sinf(Float(i) * 0.17) * 0.3 }
            try file.write(from: buffer)
        }
        let fromWav = try await AudioImporter.prepare(wav)
        defer { try? FileManager.default.removeItem(at: fromWav.file.deletingLastPathComponent()) }
        #expect(fromWav.file.pathExtension == "m4a")
        #expect(abs(fromWav.durationMs - 2000) <= 20)
        #expect(try AVAudioFile(forReading: fromWav.file).length > 0)

        let ogg = dir.appendingPathComponent("card.ogg")
        try OggOpus.wrap(try SyntheticOpus.sine(seconds: 1)).write(to: ogg)
        let fromOgg = try await AudioImporter.prepare(ogg)
        defer { try? FileManager.default.removeItem(at: fromOgg.file.deletingLastPathComponent()) }
        #expect(fromOgg.file.pathExtension == "ogg")
        #expect(fromOgg.durationMs >= 980 && fromOgg.durationMs <= 1020)

        let junk = dir.appendingPathComponent("junk.mp3")
        try Data("not audio".utf8).write(to: junk)
        await #expect(throws: AudioImporter.ImportError.unsupported) { try await AudioImporter.prepare(junk) }
    }

    @Test func failedOggImportRemovesItsTemporaryDirectory() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bad-import-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let badOgg = dir.appendingPathComponent("bad.ogg")
        try Data("OggS".utf8).write(to: badOgg)
        let conversions = dir.appendingPathComponent("conversions")
        #expect(throws: AudioImporter.ImportError.unsupported) {
            try AudioImporter.prepareNow(badOgg, temporaryRoot: conversions)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: conversions.path).isEmpty)
    }

    @Test func exportM4AReportsMissingAudio() async throws {
        let f = try Fixture()
        try FileManager.default.removeItem(at: f.library.store.url(forAudioPath: f.recording.audioPath))
        await #expect(throws: PlayerError.audioMissing) {
            _ = try await RecordingExporter.exportM4A(for: f.recording, library: f.library)
        }
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
