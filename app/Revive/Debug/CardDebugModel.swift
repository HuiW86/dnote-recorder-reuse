#if DEBUG
import AppModel
import AVFoundation
import CardLink
import CardProtocol
import CardService
import CryptoKit
import Foundation
import Library
import Observation
import Player

/// Drives CardService against a real card for the #38 checks: connect, pending reconnect,
/// background restoration, pairing, and the replies listed in test-spec.md §2; and plays the
/// downloaded files through `RecordingPlayer` for the #40 device checks.
@MainActor
@Observable
final class CardDebugModel {
    let log: DebugLog
    private(set) var cards: [DiscoveredCard] = []
    private(set) var state: LinkState = .idle
    private(set) var files: [CardFile] = []
    private(set) var busy = false
    private(set) var progress: Double = 0
    /// Set while `pair` waits for the user to confirm re-binding a card bonded elsewhere.
    var rebindPending = false

    @ObservationIgnored private let service: CardService
    @ObservationIgnored private var rebindAnswer: CheckedContinuation<Bool, Never>?
    private static let lastPeripheralKey = "debug.lastPeripheral"

    /// Shares the app's Bluetooth stack: a second CBCentralManager with the same restore
    /// identifier would fight over the card.
    init(session: CardSession, log: DebugLog) {
        self.log = log
        service = session.service
        state = session.linkState
        session.addListener { [weak self] event in self?.handle(event) }
        setUpPlayback()
    }

    var lastPeripheral: UUID? {
        UserDefaults.standard.string(forKey: Self.lastPeripheralKey).flatMap(UUID.init)
    }

    // MARK: Connection

    func startScan() {
        cards = []
        service.startScan()
        log.add("scan start")
    }

    func stopScan() { service.stopScan() }

    func connect(_ id: UUID) {
        run("connect") { [self] in
            let info = try await service.connect(id)
            log.add("connected: " + describe(info))
        }
    }

    /// Pending connect to the last card; it completes when the card advertises again.
    func connectWhenSeen() {
        guard let id = lastPeripheral else { return log.add("no saved card") }
        do {
            try service.connectWhenSeen(id)
            log.add("pending connect registered")
        } catch {
            log.add("pending connect failed: \(error)")
        }
    }

    func disconnect() { service.disconnect() }

    /// Registers a pending connect, then kills the process. Unlike a swipe-up quit, iOS treats
    /// this as a system termination and relaunches the app via state restoration when the card
    /// connects; the relaunch is logged by `AppDelegate`.
    func killForRestoration() {
        connectWhenSeen()
        log.add("SIGKILL for restoration test")
        kill(getpid(), SIGKILL)
    }

    // MARK: Queries and control

    func info() { run("info") { [self] in log.add(describe(try await service.info())) } }
    func switches() { run("switches") { [self] in log.add("\(try await service.switches())") } }
    func recordingStatus() { run("status") { [self] in log.add("\(try await service.recordingStatus())") } }
    func syncTime() { run("syncTime") { [self] in try await service.syncTime() } }
    /// Checks the unit of `autoff` (#41 batch 3): `set` reads 0x81 back and fails on a mismatch.
    func setAutoOff(_ seconds: UInt32) {
        run("autoOff \(seconds)") { [self] in
            try await service.set(.autoOff(seconds: seconds))
            log.add("\(try await service.switches())")
        }
    }
    func startRecording() { run("start") { [self] in log.add("recording " + (try await service.startRecording())) } }
    func stopRecording() { run("stop") { [self] in try await service.stopRecording() } }
    func pause() { run("pause") { [self] in try await service.pause() } }
    func resume() { run("resume") { [self] in try await service.resume() } }

    func pair() {
        run("pair") { [self] in
            _ = try await service.pair { [self] in
                await withCheckedContinuation { c in
                    rebindAnswer = c
                    rebindPending = true
                }
            }
            log.add("paired; bondId stored in Keychain")
        }
    }

    func answerRebind(_ yes: Bool) {
        log.add("rebind confirmed: \(yes)")
        rebindPending = false
        rebindAnswer?.resume(returning: yes)
        rebindAnswer = nil
    }

    func unpair() { run("unpair") { [self] in try await service.unpair() } }

    func listFiles() {
        run("list") { [self] in
            files = try await service.listFiles()
            log.add("\(files.count) files: " + files.map { "\($0.name) \($0.size) B" }.joined(separator: ", "))
        }
    }

    // MARK: Downloads (checksums only in the log; audio never goes into evidence)

    /// Files downloaded, checked and saved on the phone in this session, per card; only these may
    /// be deleted, and only on the card they came from (another card may hold the same names).
    private var storedByCard: [UUID: Set<CardFile>] = [:]
    var storedLocally: Set<CardFile> { service.peripheralId.flatMap { storedByCard[$0] } ?? [] }
    private static let downloads = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("downloads", isDirectory: true)

    func download(_ file: CardFile) {
        run("download \(file.name)") { [self] in
            guard let card = service.peripheralId else { throw CardServiceError.disconnected }
            let start = Date()
            let data = try await fetch(file, from: 0)
            let seconds = Date().timeIntervalSince(start)
            log.add("downloaded \(data.count) B in \(String(format: "%.1f", seconds)) s, "
                + String(format: "%.1f KB/s", Double(data.count) / 1000 / max(seconds, 0.001))
                + ", sha256 \(sha(data)), " + decodeCheck(data))
            if data.count == file.size {
                try FileManager.default.createDirectory(at: Self.downloads, withIntermediateDirectories: true)
                try data.write(to: Self.downloads.appendingPathComponent(file.name), options: .atomic)
                if service.peripheralId == card { storedByCard[card, default: []].insert(file) }
                // A library failure must not turn the #38 download check into a failure.
                do {
                    try await addToLibrary(file, data)
                } catch {
                    log.add("library: \(file.name) not added: \(error)")
                }
            }
        }
    }

    /// Download, drop the link halfway, reconnect, resume from the received offset; the joined
    /// bytes must equal a full download (prd.md §2.3 resumable download, #34).
    func resumeTest(_ file: CardFile) {
        run("resume test \(file.name)") { [self] in
            guard let id = service.peripheralId else { throw CardServiceError.disconnected }
            let full = try await fetch(file, from: 0)
            var partial = Data()
            var dropped = false
            do {
                try await service.download(file) { [self] chunk in
                    partial.append(chunk)
                    if partial.count >= file.size / 2, !dropped {
                        dropped = true
                        log.add("dropping link at \(partial.count) B")
                        service.disconnect()
                    }
                }
                log.add("download finished before the drop took effect")
            } catch {
                log.add("interrupted at \(partial.count) B: \(error)")
            }
            try await service.connect(id)
            let rest = try await fetch(file, from: partial.count)
            let joined = partial + rest
            let pass = joined == full
            log.add("resume \(pass ? "PASS" : "FAIL"): full sha256 \(sha(full)), joined sha256 \(sha(joined)), "
                + "split at \(partial.count) of \(file.size)")
        }
    }

    /// `0x91` only for a file already saved on the phone (CLAUDE.md rule 2). The card does not
    /// reply; list again to see whether it is gone.
    func delete(_ file: CardFile) {
        guard storedLocally.contains(file),
              FileManager.default.fileExists(atPath: Self.downloads.appendingPathComponent(file.name).path) else {
            return log.add("refused: delete \(file.name) before it is downloaded and saved")
        }
        let card = service.peripheralId
        run("delete \(file.name)") { [self] in
            guard service.peripheralId == card else { throw CardServiceError.disconnected }
            try await service.delete(file.name)
        }
    }

    private func fetch(_ file: CardFile, from offset: Int) async throws -> Data {
        var data = Data()
        progress = 0
        try await service.download(file, from: offset) { [self] chunk in
            data.append(chunk)
            progress = Double(offset + data.count) / Double(max(file.size, 1))
        }
        return data
    }

    private func decodeCheck(_ data: Data) -> String {
        guard AudioCrypto.isEncrypted(data) else {
            return "plain, \(OggOpus.splitFrames(data).count) opus frames"
        }
        do {
            return "decrypt OK, \(OggOpus.splitFrames(try AudioCrypto.decrypt(data)).count) opus frames"
        } catch {
            return "decrypt FAILED: \(error)"
        }
    }

    private func sha(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Playback (#40 device checks: background, interruption, headphones unplugged)

    /// Separate from the future app library so debug runs never mix with real data.
    @ObservationIgnored private var library: RecordingLibrary?
    private(set) var player: RecordingPlayer?
    private(set) var recordings: [Recording] = []
    @ObservationIgnored private var sessionObservers: [NSObjectProtocol] = []

    private func setUpPlayback() {
        do {
            let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("debug-library", isDirectory: true)
            let library = RecordingLibrary(database: try AppDatabase.onDisk(directory: root),
                                           store: try AudioStore(root: root))
            try library.recoverAfterLaunch()
            self.library = library
            player = RecordingPlayer(library: library)
            recordings = try library.recordings()
            observePlayerState()
            observeSession()
        } catch {
            log.add("debug library unavailable: \(error)")
        }
    }

    /// Same conversion as SyncEngine (decrypt, split, wrap as OGG), committed through the
    /// library's sync item path so the Recording row looks like a synced one.
    private func addToLibrary(_ file: CardFile, _ raw: Data) async throws {
        guard let library else { return }
        let device = try library.upsertDevice(sn: "debug") { $0.name = "debug" }
        let item = try library.syncItem(deviceId: device.id, name: file.name, size: file.size)
        guard item.recordingId == nil else { return log.add("already in library: \(file.name)") }
        let (ogg, frames) = try await Task.detached(priority: .userInitiated) {
            let opus = AudioCrypto.isEncrypted(raw) ? try AudioCrypto.decrypt(raw) : raw
            let frames = OggOpus.splitFrames(opus)
            return (OggOpus.wrap(frames), frames.count)
        }.value
        let id = UUID()
        let path = try library.store.storeAudio(ogg, id: id)
        let now = Date()
        let recording = Recording(id: id, deviceId: device.id, source: .card, cardFileName: file.name,
                                  cardFileSize: file.size, startedAt: now, durationMs: frames * 20,
                                  audioPath: path, audioSha256: sha(ogg), title: file.name,
                                  createdAt: now, updatedAt: now)
        _ = try library.commitStored(recording, item: item, deleteAfterSync: false)
        recordings = try library.recordings()
        log.add("library: \(file.name) -> ogg \(ogg.count) B, \(frames) frames")
    }

    func play(_ recording: Recording) {
        guard let player else { return }
        log.add("▶ play \(recording.title)")
        Task { [self] in
            let start = Date()
            do {
                try await player.play(recording)
                let decoded = library.map { FileManager.default.fileExists(atPath: $0.store.decodedURL(for: recording.id).path) } ?? false
                log.add("✔ play \(String(format: "%.2f", Date().timeIntervalSince(start))) s to start, "
                    + "duration \(String(format: "%.2f", player.duration)) s, "
                    + (decoded ? "via decoded PCM copy" : "OGG opened directly"))
            } catch {
                log.add("✘ play: \(error)")
            }
        }
    }

    /// Plays through the PCM copy even where AVAudioPlayer opens OGG directly, so the fallback
    /// for iOS 17-26 can be checked on a newer phone. Removes cached copies so the decode runs again.
    var forceDecode = false {
        didSet {
            guard let player, let library else { return }
            player.stop()
            player.opensOggDirectly = !forceDecode
            for r in recordings { library.store.removeDecoded(r.id) }
            log.add("force decode \(forceDecode ? "on" : "off"), decoded copies cleared")
        }
    }

    func pausePlayback() { player?.pause() }
    func stopPlayback() { player?.stop() }

    func deleteRecording(_ recording: Recording) {
        guard let library else { return }
        if player?.recordingId == recording.id { player?.stop() }
        do {
            try library.deleteRecording(id: recording.id)
            recordings = try library.recordings()
            log.add("library: deleted \(recording.title)")
        } catch {
            log.add("library: delete failed: \(error)")
        }
    }

    /// Logs every player state change, including pauses the player makes on its own.
    private func observePlayerState() {
        guard let player else { return }
        withObservationTracking { _ = player.state } onChange: {
            Task { @MainActor [weak self] in
                guard let self, let player = self.player else { return }
                self.log.add("player \(player.state) at \(String(format: "%.2f", player.currentTime)) s")
                self.observePlayerState()
            }
        }
    }

    /// Records the system events the player reacts to, so the log shows cause and effect.
    private func observeSession() {
        let center = NotificationCenter.default
        sessionObservers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil,
                                                   queue: .main) { [weak self] note in
            let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt)
                .flatMap(AVAudioSession.InterruptionType.init)
            let text = type == .began ? "began" : type == .ended ? "ended" : "unknown"
            MainActor.assumeIsolated { self?.log.add("session interruption \(text)") }
        })
        sessionObservers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil,
                                                   queue: .main) { [weak self] note in
            let reason = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt) ?? 0
            let outputs = AVAudioSession.sharedInstance().currentRoute.outputs.map(\.portType.rawValue)
            MainActor.assumeIsolated {
                self?.log.add("session route change reason \(reason), outputs \(outputs)")
            }
        })
    }

    // MARK: Events

    private func handle(_ event: CardEvent) {
        switch event {
        case .discovered(let card):
            if let i = cards.firstIndex(where: { $0.id == card.id }) { cards[i] = card } else { cards.append(card) }
            return
        case .stateChanged(let s):
            state = s
            if s == .connected, let id = service.peripheralId {
                UserDefaults.standard.set(id.uuidString, forKey: Self.lastPeripheralKey)
            }
        case .disconnected(let reason):
            state = .disconnected(reason)
        case .deviceInfo(let info):
            log.add("event deviceInfo " + describe(info))
            return
        default:
            break
        }
        log.add("event \(event)")
    }

    /// DeviceInfo without the serial (CLAUDE.md rule 4).
    private func describe(_ info: DeviceInfo) -> String {
        "sn sha256:\(Redactor.serialTag(info.serial)) fw \(info.firmware) rec \(info.recordingState) "
            + "bat \(info.battery.map(String.init) ?? "?")% free \(info.freeSpace.map(String.init) ?? "?")"
            + "/\(info.totalSpace.map(String.init) ?? "?") time \(info.time ?? "?")"
    }

    private func run(_ name: String, _ op: @escaping () async throws -> Void) {
        busy = true
        log.add("▶ \(name)")
        Task { [self] in
            let start = Date()
            do {
                try await op()
                log.add("✔ \(name) \(String(format: "%.2f", Date().timeIntervalSince(start))) s")
            } catch {
                log.add("✘ \(name): \(error)")
            }
            busy = false
        }
    }
}
#endif
