@testable import AppModel
import AVFoundation
import Foundation
import Library
import Testing

// X18: recording with the phone's microphone. The microphone itself cannot run in `swift test`;
// these cover an interrupted recording (a call, Siri) and one cut off by the app being killed.
@MainActor
struct PhoneRecorderTests {
    private struct Fixture {
        let recorder: PhoneRecorder
        let library: RecordingLibrary
        let root: URL
    }

    /// Free space the recorder sees, changed by a test.
    private final class Space: @unchecked Sendable {
        var bytes: Int64 = 10_000_000_000
    }

    private func fixture(space: Space = Space()) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("phone-\(UUID().uuidString)")
        let library = RecordingLibrary(database: try AppDatabase.inMemory(), store: try AudioStore(root: root))
        return Fixture(recorder: PhoneRecorder(library: library, freeSpace: { space.bytes }), library: library, root: root)
    }

    /// A nearly full phone: recording does not start (and the microphone is not asked for), and
    /// no file is left behind.
    @Test func startNeedsRoom() async throws {
        let space = Space()
        space.bytes = PhoneRecorder.minimumFreeBytesToStart - 1
        let f = try fixture(space: space)
        defer { try? FileManager.default.removeItem(at: f.root) }
        #expect(await f.recorder.start() == false)
        #expect(f.recorder.state == .idle)
        #expect(f.recorder.toast?.text == PhoneRecorder.noSpaceText)
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.library.store.phoneDir.path).isEmpty)
    }

    /// Running out of space while recording or paused stops the recording before the phone is
    /// full; with room, or when not recording, nothing happens.
    @Test func lowSpaceOnlyMattersWhileRecording() throws {
        let space = Space()
        let f = try fixture(space: space)
        defer { try? FileManager.default.removeItem(at: f.root) }
        space.bytes = 1_000_000
        #expect(!f.recorder.spaceIsLow())  // not recording
        f.recorder.state = .recording
        space.bytes = PhoneRecorder.minimumFreeBytesWhileRecording
        #expect(!f.recorder.spaceIsLow())
        space.bytes = PhoneRecorder.minimumFreeBytesWhileRecording - 1
        #expect(f.recorder.spaceIsLow())
        f.recorder.state = .paused
        #expect(f.recorder.spaceIsLow())
    }

    /// iOS pauses the recorder on an interruption and never resumes it: the state must say paused,
    /// with the reason, instead of "录音中" over a frozen timer.
    @Test func interruptionPausesAndSaysWhy() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }

        f.recorder.interruptionBegan()  // not recording: nothing to pause
        #expect(f.recorder.state == .idle && f.recorder.interruptionNotice == nil)

        f.recorder.state = .recording
        f.recorder.interruptionBegan()
        #expect(f.recorder.state == .paused)
        #expect(f.recorder.interruptionNotice == PhoneRecorder.interruptedText)

        f.recorder.interruptionBegan()  // a second one changes nothing
        #expect(f.recorder.state == .paused)
    }

    /// Pausing by hand shows no interruption notice.
    @Test func pausingByHandIsNotAnInterruption() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        f.recorder.state = .recording
        f.recorder.pause()
        #expect(f.recorder.state == .paused)
        #expect(f.recorder.interruptionNotice == nil)
    }

    @Test func fileNameCarriesTheStartTime() {
        let started = Date(timeIntervalSince1970: 1_800_000_000.125)
        let name = PhoneRecorder.fileName(startedAt: started)
        #expect(name == "phone-1800000000125.caf")
        #expect(PhoneRecorder.startedAt(fileName: name) == started)
        #expect(PhoneRecorder.startedAt(fileName: "phone-x.caf") == nil)
        #expect(PhoneRecorder.startedAt(fileName: "other.caf") == nil)
    }

    /// The app was killed while recording: the CAF's data chunk was never closed and its last
    /// sample is cut in half. The next launch stores it with its start time, then removes it.
    @Test func cutOffRecordingIsStoredNextTime() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let started = Date(timeIntervalSince1970: 1_800_000_000)
        let caf = f.library.store.phoneDir.appendingPathComponent(PhoneRecorder.fileName(startedAt: started))
        try Self.writeCutOffCAF(to: caf, seconds: 1)

        #expect(await f.recorder.recoverUnfinished() == 1)
        let stored = try #require(try f.library.recordings().first)
        #expect(stored.source == .phone)
        #expect(stored.startedAt == started)
        #expect(abs(stored.durationMs - 1000) < 50)
        #expect(stored.audioPath.hasSuffix(".m4a"))
        #expect(!FileManager.default.fileExists(atPath: caf.path))
        #expect(f.recorder.toast?.text == "找回了 1 条上次没保存完的手机录音")

        #expect(await f.recorder.recoverUnfinished() == 0)  // nothing left to store
        #expect(try f.library.recordings().count == 1)
    }

    /// A leftover that cannot be read is kept for a bug report and not retried on every launch.
    @Test func unreadableLeftoverIsKeptAndNotRetried() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let caf = f.library.store.phoneDir.appendingPathComponent("phone-1800000000000.caf")
        try Data("not audio".utf8).write(to: caf)

        #expect(await f.recorder.recoverUnfinished() == 0)
        #expect(!FileManager.default.fileExists(atPath: caf.path))
        #expect(FileManager.default.fileExists(atPath: caf.appendingPathExtension("unreadable").path))
        #expect(try f.library.recordings().isEmpty)
        #expect(f.recorder.toast == nil)
    }

    /// A recording that was started and killed before any sound arrived leaves nothing behind.
    @Test func emptyLeftoverIsRemoved() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let caf = f.library.store.phoneDir.appendingPathComponent("phone-1800000000000.caf")
        try Self.writeCutOffCAF(to: caf, seconds: 0)

        #expect(await f.recorder.recoverUnfinished() == 0)
        #expect(!FileManager.default.fileExists(atPath: caf.path))
        #expect(try f.library.recordings().isEmpty)
    }

    /// 标重点 while recording with the phone (X7): not while idle; a double tap within 2 s is one
    /// mark; the marks are written next to the CAF, so a recovered recording keeps them.
    @Test func marksAreKeptThroughRecovery() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        #expect(!f.recorder.markNow())
        #expect(f.recorder.toast?.text == "现在还不能标重点")

        let started = Date(timeIntervalSince1970: 1_800_000_000)
        let caf = f.library.store.phoneDir.appendingPathComponent(PhoneRecorder.fileName(startedAt: started))
        try Self.writeCutOffCAF(to: caf, seconds: 5)
        f.recorder.state = .recording
        #expect(f.recorder.addMark(atMs: 1_000, file: caf))
        #expect(!f.recorder.addMark(atMs: 2_500, file: caf))  // a double tap
        #expect(f.recorder.addMark(atMs: 4_000, file: caf))
        #expect(f.recorder.marksMs == [1_000, 4_000])
        #expect(PhoneRecorder.readMarks(for: caf) == [1_000, 4_000])

        // Killed here; the next launch finds the CAF and its marks.
        f.recorder.state = .idle
        #expect(await f.recorder.recoverUnfinished() == 1)
        let stored = try #require(try f.library.recordings().first)
        #expect(try f.library.playbackMarks(for: stored).map(\.offsetMs) == [1_000, 4_000])
        #expect(!FileManager.default.fileExists(atPath: PhoneRecorder.marksURL(for: caf).path))
    }

    /// 16 kHz mono 16-bit PCM like the recorder's, then made to look as if the writer was killed:
    /// the data chunk's size is "unknown" (-1, which CAF allows for the last chunk) and the file
    /// ends in the middle of a sample.
    static func writeCutOffCAF(to url: URL, seconds: Int) throws {
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1,
                                                interleaved: true))
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatInt16,
                                       interleaved: true)
            let frames = AVAudioFrameCount(16000 * seconds)
            if frames > 0 {
                let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
                buffer.frameLength = frames
                let samples = try #require(buffer.int16ChannelData)[0]
                for i in 0..<Int(frames) {
                    samples[i] = Int16(sin(Double(i) * 2 * .pi * 440 / 16000) * 8000)
                }
                try file.write(from: buffer)
            }
        }
        var data = try Data(contentsOf: url)
        var offset = 8  // after the file header
        var patched = false
        while offset + 12 <= data.count {
            let type = String(decoding: data[offset..<offset + 4], as: UTF8.self)
            var size: UInt64 = 0
            for byte in data[offset + 4..<offset + 12] { size = size << 8 | UInt64(byte) }
            if type == "data" {
                data.replaceSubrange(offset + 4..<offset + 12, with: Data(repeating: 0xFF, count: 8))
                patched = true
                break
            }
            offset += 12 + Int(size)
        }
        #expect(patched, "the CAF has a data chunk")
        if seconds > 0 { data.removeLast(3) }
        try data.write(to: url)
    }
}
