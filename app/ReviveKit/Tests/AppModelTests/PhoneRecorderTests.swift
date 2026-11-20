@testable import AppModel
import Foundation
import Library
import Testing

// X18: recording with the phone's microphone. The microphone itself cannot run in `swift test`;
// these cover what the page shows when iOS interrupts a recording (a call, Siri).
@MainActor
struct PhoneRecorderTests {
    private func makeRecorder() throws -> (PhoneRecorder, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("phone-\(UUID().uuidString)")
        let library = RecordingLibrary(database: try AppDatabase.inMemory(), store: try AudioStore(root: root))
        return (PhoneRecorder(library: library), root)
    }

    /// iOS pauses the recorder on an interruption and never resumes it: the state must say paused,
    /// with the reason, instead of "录音中" over a frozen timer.
    @Test func interruptionPausesAndSaysWhy() throws {
        let (recorder, root) = try makeRecorder()
        defer { try? FileManager.default.removeItem(at: root) }

        recorder.interruptionBegan()  // not recording: nothing to pause
        #expect(recorder.state == .idle && recorder.interruptionNotice == nil)

        recorder.state = .recording
        recorder.interruptionBegan()
        #expect(recorder.state == .paused)
        #expect(recorder.interruptionNotice == PhoneRecorder.interruptedText)

        recorder.interruptionBegan()  // a second one changes nothing
        #expect(recorder.state == .paused)
    }

    /// Pausing by hand shows no interruption notice.
    @Test func pausingByHandIsNotAnInterruption() throws {
        let (recorder, root) = try makeRecorder()
        defer { try? FileManager.default.removeItem(at: root) }
        recorder.state = .recording
        recorder.pause()
        #expect(recorder.state == .paused)
        #expect(recorder.interruptionNotice == nil)
    }
}
