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

    /// Internal set for tests, which cannot start the microphone.
    public internal(set) var state: State = .idle
    public var toast: Toast?
    /// Why recording paused on its own: a call, Siri or another app took the microphone. iOS
    /// pauses the recorder then and never resumes it, so without this the page kept saying
    /// "录音中" over a frozen timer while nothing was recorded. Cleared by resuming or stopping.
    public private(set) var interruptionNotice: String?

    /// The page's text while `interruptionNotice` is set.
    public static let interruptedText = "录音被来电或其他 App 打断，已经暂停。前面录的都在，点「继续」接着录。"

    @ObservationIgnored private let library: RecordingLibrary
    @ObservationIgnored private var recorder: AVAudioRecorder?
    @ObservationIgnored private var startedAt: Date?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    public init(library: RecordingLibrary) {
        self.library = library
        observeSession()
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
        interruptionNotice = nil
    }

    /// The audio session was taken while recording. What was recorded stays in the file; the
    /// state becomes paused so the page and its timer tell the truth, and the user decides when
    /// to go on (as the player does, nothing resumes on its own).
    func interruptionBegan() {
        guard state == .recording else { return }
        recorder?.pause()
        state = .paused
        interruptionNotice = Self.interruptedText
    }

    private func observeSession() {
        #if os(iOS)
        observers.append(NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt)
                .flatMap(AVAudioSession.InterruptionType.init)
            guard type == .began else { return }
            MainActor.assumeIsolated { self?.interruptionBegan() }
        })
        #endif
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
        interruptionNotice = nil
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
