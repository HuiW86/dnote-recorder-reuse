#if DEBUG
import CardLink
import CardProtocol
import CardService
import CryptoKit
import Foundation
import Observation

/// Drives CardService against a real card for the #38 checks: connect, pending reconnect,
/// background restoration, pairing, and the replies listed in test-spec.md §2.
@MainActor
@Observable
final class CardDebugModel {
    let log = DebugLog()
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

    init() {
        let link = TappedLink(BluetoothCardLink(), log: log)
        service = CardService(link: link, bondStore: KeychainBondStore())
        let events = service.events
        Task { [weak self] in
            for await event in events { self?.handle(event) }
        }
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

    /// Files downloaded, checked and saved on the phone in this session; only these may be deleted.
    private(set) var storedLocally: Set<CardFile> = []
    private static let downloads = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("downloads", isDirectory: true)

    func download(_ file: CardFile) {
        run("download \(file.name)") { [self] in
            let start = Date()
            let data = try await fetch(file, from: 0)
            let seconds = Date().timeIntervalSince(start)
            if data.count == file.size {
                try FileManager.default.createDirectory(at: Self.downloads, withIntermediateDirectories: true)
                try data.write(to: Self.downloads.appendingPathComponent(file.name), options: .atomic)
                storedLocally.insert(file)
            }
            log.add("downloaded \(data.count) B in \(String(format: "%.1f", seconds)) s, "
                + String(format: "%.1f KB/s", Double(data.count) / 1000 / max(seconds, 0.001))
                + ", sha256 \(sha(data)), " + decodeCheck(data))
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
        guard storedLocally.contains(file) else {
            return log.add("refused: delete \(file.name) before it is downloaded and saved")
        }
        run("delete \(file.name)") { [self] in try await service.delete(file.name) }
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
