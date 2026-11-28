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
public final class PhoneRecorder: NSObject {
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
    /// Points marked in the running recording, in ms (features.md X7). Also kept next to the CAF
    /// (`marksURL`), so a recording recovered after the app was killed keeps its marks.
    public private(set) var marksMs: [Int] = []

    /// The page's text while `interruptionNotice` is set.
    public static let interruptedText = "录音被来电或其他 App 打断，已经暂停。前面录的都在，点「继续」接着录。"
    /// Stopping could not store the recording; its CAF stays for the next launch.
    public static let saveFailedText = "这次没能保存。录音还在这部手机上，下次打开闻笺时会再保存一次"

    /// Free space needed to start: the CAF grows by about 115 MB an hour, and stopping needs room
    /// for the M4A next to it.
    public static let minimumFreeBytesToStart: Int64 = 100_000_000
    /// Below this while recording, the recording is stopped and stored before the phone is full:
    /// a full phone makes the recorder stop writing without a word while the page says 录音中.
    public static let minimumFreeBytesWhileRecording: Int64 = 30_000_000
    public static let noSpaceText = "手机存储空间不足 100 MB，先清理一些空间再录"
    public static let spaceRanOutText = "手机存储空间快满了，录音已自动停止并保存"
    /// The recorder stopped on its own (an encoding or write error, or iOS reset its media services).
    public static let failedText = "录音意外中断，已保存中断前录到的部分"

    @ObservationIgnored private let library: RecordingLibrary
    @ObservationIgnored private var recorder: AVAudioRecorder?
    @ObservationIgnored private var startedAt: Date?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    /// CAF files being converted and stored, so a stop and a recovery never store one twice.
    @ObservationIgnored private var storing: Set<URL> = []
    /// Bytes free for the library; tests pass a fixed number.
    @ObservationIgnored private let freeSpace: () -> Int64
    @ObservationIgnored private var spaceWatch: Task<Void, Never>?

    public init(library: RecordingLibrary, freeSpace: (() -> Int64)? = nil) {
        self.library = library
        self.freeSpace = freeSpace ?? { library.store.availableCapacity() }
        super.init()
        observeSession()
    }

    /// Seconds recorded so far, for the timer. While saving, the length that was recorded: the
    /// recorder is gone by then, and the page would otherwise drop to 00:00:00 under 正在保存.
    public var elapsed: TimeInterval { recorder?.currentTime ?? (isSaving ? heldElapsed : 0) }
    /// The length at 停止, shown while saving.
    @ObservationIgnored private var heldElapsed: TimeInterval = 0

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
        guard freeSpace() >= Self.minimumFreeBytesToStart else {
            toast = Toast(Self.noSpaceText)
            return false
        }
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
            recorder.delegate = self
            guard recorder.record() else { throw CocoaError(.fileWriteUnknown) }
            self.recorder = recorder
            startedAt = now
            marksMs = []
            state = .recording
            watchSpace()
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

    /// "标重点": the current position of the running recording, as on the card's recording page
    /// (features.md X7). Only while recording; a second mark within 2 s of one is dropped (a
    /// double tap). Returns whether a mark was added.
    @discardableResult
    public func markNow() -> Bool {
        guard state == .recording, let recorder else {
            toast = Toast("现在还不能标重点")
            return false
        }
        return addMark(atMs: Int((recorder.currentTime * 1000).rounded()), file: recorder.url)
    }

    func addMark(atMs offset: Int, file: URL) -> Bool {
        guard !marksMs.contains(where: { abs($0 - offset) < 2000 }) else { return false }
        marksMs.append(max(0, offset))
        Self.writeMarks(marksMs, for: file)
        return true
    }

    /// `phone-….caf.marks`: the marks of that CAF as a JSON array of ms.
    static func marksURL(for caf: URL) -> URL { caf.appendingPathExtension("marks") }

    static func readMarks(for caf: URL) -> [Int] {
        (try? Data(contentsOf: marksURL(for: caf))).flatMap { try? JSONDecoder().decode([Int].self, from: $0) } ?? []
    }

    static func writeMarks(_ marks: [Int], for caf: URL) {
        guard let data = try? JSONEncoder().encode(marks) else { return }
        try? data.write(to: marksURL(for: caf), options: .atomic)
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
        await finish(savedText: "已保存到录音列表")
    }

    /// The recorder stopped on its own while recording: what reached the CAF is stored like a
    /// 停止, and the toast says it was cut short. Without this the page kept saying 录音中 while
    /// nothing was written. Nothing happens once a stop is under way.
    func recordingFailed() {
        guard state != .idle, !isSaving else { return }
        Task { await finish(savedText: Self.failedText) }
    }

    /// Recording or paused with less than `minimumFreeBytesWhileRecording` free.
    func spaceIsLow() -> Bool {
        state != .idle && freeSpace() < Self.minimumFreeBytesWhileRecording
    }

    /// Every 10 s while recording: stops and stores before the phone is full.
    private func watchSpace() {
        spaceWatch?.cancel()
        spaceWatch = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                guard let self, !Task.isCancelled, self.state != .idle else { return }
                if self.spaceIsLow() {
                    // Not cancelled by `finish`: the store that follows runs in this task.
                    self.spaceWatch = nil
                    await self.finish(savedText: Self.spaceRanOutText)
                    return
                }
            }
        }
    }

    /// `savedText` is the toast once stored; the toast is set before `isSaving` goes back to
    /// false, which is when the recording page closes.
    @discardableResult
    private func finish(savedText: String) async -> Recording? {
        guard state != .idle, let recorder, let startedAt else { return nil }
        spaceWatch?.cancel()
        spaceWatch = nil
        let url = recorder.url
        heldElapsed = recorder.currentTime
        recorder.stop()
        self.recorder = nil
        self.startedAt = nil
        isSaving = true
        state = .idle
        interruptionNotice = nil
        marksMs = []
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
        defer { isSaving = false }
        let stored = await store(url, startedAt: startedAt)
        toast = Toast(stored != nil ? savedText : Self.saveFailedText)
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
                try? FileManager.default.removeItem(at: Self.marksURL(for: caf))
                return nil
            }
            let stored = try library.addPhoneRecording(file: prepared.file, startedAt: startedAt,
                                                       durationMs: prepared.durationMs,
                                                       marksMs: Self.readMarks(for: caf))
            try? FileManager.default.removeItem(at: caf)
            try? FileManager.default.removeItem(at: Self.marksURL(for: caf))
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
        // iOS restarted its audio services: the recorder object is dead and records nothing more.
        observers.append(NotificationCenter.default.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.recordingFailed() }
        })
        #endif
    }
}

extension PhoneRecorder: AVAudioRecorderDelegate {
    /// Also called after our own `stop()`, successfully; only a failure while recording matters.
    nonisolated public func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        guard !flag else { return }
        // The thread these arrive on is not documented: hop to the main actor.
        Task { @MainActor [weak self] in self?.recordingFailed() }
    }

    nonisolated public func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        Task { @MainActor [weak self] in self?.recordingFailed() }
    }
}
