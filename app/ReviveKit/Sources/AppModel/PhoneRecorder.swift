import AVFoundation
import Foundation
import Library
import Observation
import Player

/// Records with the phone's microphone when no card is at hand (features.md X18), kept in the
/// library like a card recording as AAC in an `.m4a`; nothing is sent anywhere.
///
/// While recording, the sound goes to 16-bit PCM in a CAF under `AudioStore.phoneDir`, not to
/// the `.m4a` directly: an `.m4a` is only readable once it is closed, so a recording cut off by
/// the app being killed (memory pressure in the background, a crash) was lost entirely. A CAF
/// whose data chunk was never closed is still readable to its last sample. Stopping converts it
/// to `.m4a` and stores it; a CAF left behind is stored the next time the tabs open
/// (`recoverUnfinished`). The CAF is only removed once the recording is in the library.
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
    /// Converting and storing after "停止"; a long recording takes a few seconds.
    public private(set) var isSaving = false

    /// The page's text while `interruptionNotice` is set.
    public static let interruptedText = "录音被来电或其他 App 打断，已经暂停。前面录的都在，点「继续」接着录。"
    /// Stopping could not store the recording; its CAF stays for the next launch.
    public static let saveFailedText = "这次没能保存。录音还在这部手机上，下次打开闻笺时会再保存一次"

    @ObservationIgnored private let library: RecordingLibrary
    @ObservationIgnored private var recorder: AVAudioRecorder?
    @ObservationIgnored private var startedAt: Date?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    /// CAF files being converted and stored, so a stop and a recovery never store one twice.
    @ObservationIgnored private var storing: Set<URL> = []

    public init(library: RecordingLibrary) {
        self.library = library
        observeSession()
    }

    /// Seconds recorded so far, for the timer.
    public var elapsed: TimeInterval { recorder?.currentTime ?? 0 }

    /// 16 kHz mono 16-bit PCM: about 115 MB an hour while recording, AAC once stored.
    static var recordingSettings: [String: Any] {
        [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16000, AVNumberOfChannelsKey: 1,
         AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
    }

    /// `phone-<start in ms since 1970>.caf`, so a recovered recording keeps its start time.
    static func fileName(startedAt: Date) -> String {
        "phone-\(Int64((startedAt.timeIntervalSince1970 * 1000).rounded())).caf"
    }

    static func startedAt(fileName: String) -> Date? {
        guard fileName.hasPrefix("phone-"), fileName.hasSuffix(".caf"),
              let ms = Int64(fileName.dropFirst("phone-".count).dropLast(".caf".count)) else { return nil }
        return Date(timeIntervalSince1970: Double(ms) / 1000)
    }

    /// Asks for the microphone the first time, then starts. False when it could not start.
    @discardableResult
    public func start() async -> Bool {
        guard state == .idle, !isSaving else { return false }
        guard await AVAudioApplication.requestRecordPermission() else {
            toast = Toast("没有麦克风权限，请到系统「设置」里为闻笺打开")
            return false
        }
        let now = Date()
        let url = library.store.phoneDir.appendingPathComponent(Self.fileName(startedAt: now))
        do {
            #if os(iOS)
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .spokenAudio, options: [.defaultToSpeaker])
            try session.setActive(true)
            #endif
            let recorder = try AVAudioRecorder(url: url, settings: Self.recordingSettings)
            guard recorder.record() else { throw CocoaError(.fileWriteUnknown) }
            self.recorder = recorder
            startedAt = now
            state = .recording
            return true
        } catch {
            try? FileManager.default.removeItem(at: url)
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

    /// Stops, converts and keeps the recording in the library. Returns it, or nil when it could
    /// not be stored; its CAF then stays and is stored on the next launch.
    @discardableResult
    public func stop() async -> Recording? {
        guard state != .idle, let recorder, let startedAt else { return nil }
        let url = recorder.url
        recorder.stop()
        self.recorder = nil
        self.startedAt = nil
        state = .idle
        interruptionNotice = nil
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
        isSaving = true
        defer { isSaving = false }
        let stored = await store(url, startedAt: startedAt)
        toast = Toast(stored != nil ? "已保存到录音列表" : Self.saveFailedText)
        return stored
    }

    /// Stores phone recordings that were cut off before they were stored (the app was closed or
    /// killed while recording, or storing failed). Returns how many; the toast says so. A file
    /// that cannot be read is renamed `.unreadable` so it is not retried, and kept.
    @discardableResult
    public func recoverUnfinished() async -> Int {
        let files = ((try? FileManager.default.contentsOfDirectory(at: library.store.phoneDir,
                                                                    includingPropertiesForKeys: [.creationDateKey])) ?? [])
            .filter { $0.pathExtension == "caf" && $0.standardizedFileURL != recorder?.url.standardizedFileURL }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        var recovered = 0
        for file in files where !storing.contains(file) {
            let started = Self.startedAt(fileName: file.lastPathComponent)
                ?? (try? file.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
            if await store(file, startedAt: started, skipEmpty: true) != nil {
                recovered += 1
            } else if FileManager.default.fileExists(atPath: file.path) {
                try? FileManager.default.moveItem(at: file, to: file.appendingPathExtension("unreadable"))
            }
        }
        if recovered > 0 {
            toast = Toast(recovered == 1 ? "找回了 1 条上次没保存完的手机录音" : "找回了 \(recovered) 条上次没保存完的手机录音")
        }
        return recovered
    }

    /// Converts `caf` to `.m4a` and stores it; removes the CAF only once the recording is in the
    /// library. With `skipEmpty`, a file with no sound in it is removed instead.
    private func store(_ caf: URL, startedAt: Date, skipEmpty: Bool = false) async -> Recording? {
        guard storing.insert(caf).inserted else { return nil }
        defer { storing.remove(caf) }
        do {
            let prepared = try await AudioImporter.prepare(caf)
            defer { try? FileManager.default.removeItem(at: prepared.file.deletingLastPathComponent()) }
            if skipEmpty, prepared.durationMs == 0 {
                try? FileManager.default.removeItem(at: caf)
                return nil
            }
            let stored = try library.addPhoneRecording(file: prepared.file, startedAt: startedAt,
                                                       durationMs: prepared.durationMs)
            try? FileManager.default.removeItem(at: caf)
            return stored
        } catch {
            return nil
        }
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
}
