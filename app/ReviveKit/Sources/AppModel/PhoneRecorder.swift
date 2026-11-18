import AVFoundation
import Foundation
import Library
import Observation

/// Records with the phone's microphone when no card is at hand (features.md X18). The file is
/// AAC in an `.m4a`, kept in the library like a card recording; nothing is sent anywhere.
@MainActor
@Observable
public final class PhoneRecorder {
    public enum State: Equatable, Sendable {
        case idle, recording, paused
    }

    public private(set) var state: State = .idle
    public var toast: Toast?

    @ObservationIgnored private let library: RecordingLibrary
    @ObservationIgnored private var recorder: AVAudioRecorder?
    @ObservationIgnored private var startedAt: Date?

    public init(library: RecordingLibrary) {
        self.library = library
    }

    /// Seconds recorded so far, for the timer.
    public var elapsed: TimeInterval { recorder?.currentTime ?? 0 }

    /// Asks for the microphone the first time, then starts. False when it could not start.
    @discardableResult
    public func start() async -> Bool {
        guard state == .idle else { return false }
        guard await AVAudioApplication.requestRecordPermission() else {
            toast = Toast("没有麦克风权限，请到系统「设置」里为闻笺打开")
            return false
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("phone-\(UUID().uuidString).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 16000, AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 32000,
        ]
        do {
            #if os(iOS)
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .spokenAudio, options: [.defaultToSpeaker])
            try session.setActive(true)
            #endif
            let recorder = try AVAudioRecorder(url: url, settings: settings)
            guard recorder.record() else { throw CocoaError(.fileWriteUnknown) }
            self.recorder = recorder
            startedAt = Date()
            state = .recording
            return true
        } catch {
            toast = Toast("无法开始录音，请重试")
            return false
        }
    }

    public func pause() {
        guard state == .recording else { return }
        recorder?.pause()
        state = .paused
    }

    public func resume() {
        guard state == .paused, recorder?.record() == true else { return }
        state = .recording
    }

    /// Stops and keeps the recording in the library. Returns it, or nil when it could not be kept.
    @discardableResult
    public func stop() -> Recording? {
        guard state != .idle, let recorder, let startedAt else { return nil }
        let durationMs = Int((recorder.currentTime * 1000).rounded())
        let url = recorder.url
        recorder.stop()
        self.recorder = nil
        self.startedAt = nil
        state = .idle
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
        do {
            let stored = try library.addPhoneRecording(file: url, startedAt: startedAt, durationMs: durationMs)
            toast = Toast("已保存到录音列表")
            return stored
        } catch {
            try? FileManager.default.removeItem(at: url)
            toast = Toast("保存失败，这条录音没有留下")
            return nil
        }
    }
}
