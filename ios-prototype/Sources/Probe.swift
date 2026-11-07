import CoreBluetooth
import CryptoKit
import Foundation
import UIKit
import UserNotifications

private final class DownloadState {
    var data = Data()
    var finished = false
    var lastChunk = Date()
}

struct CardFile: Identifiable, Hashable {
    let name: String
    let size: Int
    var id: String { name }
}

struct FoundCard: Identifiable {
    let peripheral: CBPeripheral
    let adv: AdvInfo
    let rssi: Int
    var id: UUID { peripheral.identifier }
}

enum ProbeError: LocalizedError {
    case notConnected, timeout(String), transfer(UInt8)
    var errorDescription: String? {
        switch self {
        case .notConnected: return "not connected"
        case .timeout(let what): return "timeout: \(what)"
        case .transfer(let s): return String(format: "transfer aborted status=0x%02x", s)
        }
    }
}

/// Single-screen probe: CoreBluetooth central + D·NOTE session. Mirrors client/dnote.py Session.
@MainActor
final class Probe: NSObject, ObservableObject {
    @Published var state = "init"
    @Published var cards: [FoundCard] = []
    @Published var connected: CBPeripheral?
    @Published var files: [CardFile] = []
    @Published var progress: Double = 0
    @Published var busy = false
    @Published var scanFE98Only = false

    let log = ProbeLog.shared
    private var central: CBCentralManager!
    private var writeChar: CBCharacteristic?
    private var ready: CheckedContinuation<Void, Error>?
    private var waiters: [UInt8: CheckedContinuation<Frame, Error>] = [:]
    private var waiterSeq: [UInt8: Int] = [:]
    private var requestSeq = 0
    private var listItems: [CardFile] = []
    private var listDone: CheckedContinuation<Void, Never>?
    private var chunkHandler: ((FileChunk) -> Void)?
    private var deviceSN: String?
    private var lastPeripheralId: UUID? {
        get { UserDefaults.standard.string(forKey: "lastPeripheral").flatMap(UUID.init) }
        set { UserDefaults.standard.set(newValue?.uuidString, forKey: "lastPeripheral") }
    }

    /// Persistent app-generated bondId (16 bytes).
    var bondId: Data {
        if let d = UserDefaults.standard.data(forKey: "bondId"), d.count == 16 { return d }
        let d = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
        UserDefaults.standard.set(d, forKey: "bondId")
        return d
    }

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main,
                                   options: [CBCentralManagerOptionRestoreIdentifierKey: "dnoteprobe.central"])
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
            ProbeLog.shared.add("app: background")
        }
        NotificationCenter.default.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { _ in
            ProbeLog.shared.add("app: foreground")
        }
        NotificationCenter.default.addObserver(forName: UIApplication.protectedDataWillBecomeUnavailableNotification, object: nil, queue: .main) { _ in
            ProbeLog.shared.add("app: device locked")
        }
        NotificationCenter.default.addObserver(forName: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil, queue: .main) { _ in
            ProbeLog.shared.add("app: device unlocked")
        }
    }

    // MARK: scan / connect

    func startScan() {
        guard central.state == .poweredOn else { log.add("scan: bluetooth \(central.state.rawValue)"); return }
        cards = []
        // Background scanning only works with a service filter; V7 found the card is not matched by FE98.
        central.scanForPeripherals(withServices: scanFE98Only ? [DNote.advService] : nil,
                                   options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        log.add("scan: start filter=\(scanFE98Only ? "FE98" : "none")")
    }

    func stopScan() {
        central.stopScan()
        log.add("scan: stop")
    }

    func connect(_ p: CBPeripheral) async throws {
        stopScan()
        lastPeripheralId = p.identifier
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            ready = c
            p.delegate = self
            central.connect(p, options: [CBConnectPeripheralOptionNotifyOnDisconnectionKey: true])
            log.add("connect: \(p.identifier.uuidString)")
        }
    }

    /// Pending connect: iOS completes it whenever the card advertises again, including in background.
    func connectWhenSeen() {
        guard let id = lastPeripheralId, let p = central.retrievePeripherals(withIdentifiers: [id]).first else {
            log.add("reconnect: no known peripheral"); return
        }
        p.delegate = self
        central.connect(p, options: [CBConnectPeripheralOptionNotifyOnDisconnectionKey: true])
        log.add("reconnect: pending connect to \(id.uuidString)")
    }

    func disconnect() {
        if let p = connected { central.cancelPeripheralConnection(p) }
    }

    // MARK: session

    /// Fire-and-forget write for commands without a known response.
    func sendRaw(_ frame: Data) throws { try write(frame) }

    private func write(_ frame: Data) throws {
        guard let p = connected, let ch = writeChar else { throw ProbeError.notConnected }
        p.writeValue(frame, for: ch, type: .withResponse)
    }

    func request(_ frame: Data, expect cmd: UInt8, timeout: Double = 8) async throws -> Frame {
        try write(frame)
        requestSeq += 1
        let seq = requestSeq
        return try await withCheckedThrowingContinuation { c in
            waiters[cmd] = c
            waiterSeq[cmd] = seq
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(timeout))
                // Only time out this request, not a later one for the same cmd.
                guard waiterSeq[cmd] == seq, let w = waiters.removeValue(forKey: cmd) else { return }
                w.resume(throwing: ProbeError.timeout(String(format: "cmd 0x%02x", cmd)))
            }
        }
    }

    func deviceInfo() async throws {
        let f = try await request(buildFrame(Cmd.queryDeviceInfo), expect: Cmd.queryDeviceInfo)
        deviceSN = f.json?["sn"] as? String
        log.add("info: \(f.text)")
    }

    func status() async throws {
        let r = try await request(buildFrame(Cmd.queryRecStatus), expect: Cmd.queryRecStatus)
        log.add("rec status: \(r.text) hex=\(r.body.hex)")
        let b = try await request(buildFrame(Cmd.queryBond), expect: Cmd.queryBond)
        log.add("bond: isBonded=\(b.body.first == 1) bondId=\(b.body.dropFirst().prefix(16).hex)")
        let e = try await request(buildFrame(Cmd.queryChaCha20), expect: Cmd.queryChaCha20)
        log.add("chacha20: hex=\(e.body.hex)")
    }

    func pair() async throws {
        let id = bondId
        let r = try await request(frameBond(id), expect: Cmd.bond)
        log.add("pair: write bondId=\(id.hex) -> \(r.body.hex)")
        let b = try await request(buildFrame(Cmd.queryBond), expect: Cmd.queryBond)
        let ok = b.body.first == 1 && b.body.dropFirst().prefix(16) == id
        log.add("pair: verify isBonded=\(b.body.first == 1) match=\(ok) [\(ok ? "PASS" : "FAIL")]")
    }

    func unpair() async throws {
        let r = try await request(buildFrame(Cmd.bond, Data([0])), expect: Cmd.bond)
        log.add("unpair: -> \(r.body.hex)")
        let b = try await request(buildFrame(Cmd.queryBond), expect: Cmd.queryBond)
        log.add("unpair: verify isBonded=\(b.body.first == 1)")
    }

    func stopRecording() async throws {
        try write(buildFrame(Cmd.stopRecording))
        log.add("stop recording: sent")
        try await Task.sleep(for: .seconds(1))
        let r = try await request(buildFrame(Cmd.queryRecStatus), expect: Cmd.queryRecStatus)
        log.add("rec status: \(r.text)")
    }

    func listFiles() async throws {
        listItems = []
        try write(buildFrame(Cmd.queryFileList))
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            listDone = c
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(15))
                listDone?.resume(); listDone = nil
            }
        }
        files = listItems
        log.add("list: \(files.count) files " + files.map { "\($0.name)(\($0.size))" }.joined(separator: " "))
    }

    /// Download -> decrypt -> Ogg + WAV into Documents/downloads. Returns the WAV URL.
    @discardableResult
    func download(_ file: CardFile) async throws -> URL {
        // Keep the screen on so foreground throughput is not mixed with background behaviour.
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = false }
        let st = DownloadState()
        st.data.reserveCapacity(file.size)
        progress = 0
        let t0 = Date()
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            func finish(_ error: Error?) {
                guard !st.finished else { return }
                st.finished = true
                if let error { c.resume(throwing: error) } else { c.resume() }
            }
            // Stall watchdog: fail if no chunk arrives for 20 s.
            Task { @MainActor in
                while !st.finished {
                    try? await Task.sleep(for: .seconds(2))
                    if Date().timeIntervalSince(st.lastChunk) > 20 {
                        finish(ProbeError.timeout("download stalled at \(st.data.count)B"))
                    }
                }
            }
            chunkHandler = { [weak self] chunk in
                guard let self, !st.finished else { return }
                st.lastChunk = Date()
                switch chunk.status {
                case FileStatus.cancelled, FileStatus.error, FileStatus.notFound:
                    finish(ProbeError.transfer(chunk.status))
                default:
                    st.data.append(chunk.data)
                    if file.size > 0 { self.progress = Double(st.data.count) / Double(file.size) }
                    if chunk.status == FileStatus.eof { finish(nil) }
                }
            }
            do { try write(frameRequestFile(file.name)) } catch { finish(error) }
            log.add("download: start \(file.name) size=\(file.size)")
        }
        chunkHandler = nil
        let chunks = st.data
        let dt = Date().timeIntervalSince(t0)
        let rate = Double(chunks.count) / 1024 / dt
        log.add(String(format: "download: done %@ %dB in %.1fs = %.2f KB/s", file.name, chunks.count, dt, rate))

        let plain = isEncryptedAudio(chunks) ? try decryptAudioFile(chunks) : chunks
        let frames = splitOpusFrames(plain)
        let ogg = wrapOpusFramesAsOgg(frames)
        let wav = try decodeOpusToWav(frames)
        let base = (file.name as NSString).deletingPathExtension
        let dir = ProbeLog.documents.appendingPathComponent("downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try chunks.write(to: dir.appendingPathComponent(file.name + ".raw"))
        try ogg.write(to: dir.appendingPathComponent(base + ".ogg"))
        let wavURL = dir.appendingPathComponent(base + ".wav")
        try wav.write(to: wavURL)
        log.add("decode: encrypted=\(isEncryptedAudio(chunks)) frames=\(frames.count) remainder=\(plain.count % 40)B "
                + "wav=\(Double(wav.count - 44) / 32000)s")
        log.add("sha256 raw=\(chunks.sha256) ogg=\(ogg.sha256)")
        return wavURL
    }

    func run(_ label: String, _ op: @escaping () async throws -> Void) {
        guard !busy else { return }
        busy = true
        Task { @MainActor in
            defer { busy = false }
            do { try await op() } catch { log.add("\(label): ERROR \(error.localizedDescription)") }
        }
    }

    private func notifyUser(_ text: String) {
        guard UIApplication.shared.applicationState != .active else { return }
        let content = UNMutableNotificationContent()
        content.body = text
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}

extension Probe: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        MainActor.assumeIsolated {
            state = ["unknown", "resetting", "unsupported", "unauthorized", "poweredOff", "poweredOn"][central.state.rawValue]
            log.add("central: \(state)")
            guard central.state == .poweredOn else { return }
            // A connection kept by iOS (state restoration or a previous app run) stops the card
            // advertising, so adopt it instead of scanning.
            for p in central.retrieveConnectedPeripherals(withServices: [DNote.service]) where p.state == .connected {
                log.add("central: adopting existing connection \(p.identifier.uuidString.prefix(8))")
                lastPeripheralId = p.identifier
                p.delegate = self
                p.discoverServices([DNote.service])
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        MainActor.assumeIsolated {
            let ps = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] ?? []
            log.add("central: restored state peripherals=\(ps.map { "\($0.identifier.uuidString.prefix(8)):\($0.state.rawValue)" })")
            for p in ps { p.delegate = self }
            notifyUser("D·NOTE probe relaunched by iOS (state restoration)")
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDiscover p: CBPeripheral,
                                    advertisementData ad: [String: Any], rssi: NSNumber) {
        MainActor.assumeIsolated {
            guard let md = ad[CBAdvertisementDataManufacturerDataKey] as? Data, let info = AdvInfo(manufacturerData: md) else {
                // In background iOS may strip manufacturer data; log the service-matched hit anyway.
                if scanFE98Only { log.add("scan: hit without manufacturer data \(p.identifier.uuidString.prefix(8)) keys=\(Array(ad.keys))") }
                return
            }
            if !cards.contains(where: { $0.id == p.identifier }) {
                cards.append(FoundCard(peripheral: p, adv: info, rssi: rssi.intValue))
                // Full advertisement dump: tells which field (if any) a background scan could filter on.
                let serviceData = (ad[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data])?
                    .map { "\($0.key.uuidString)=\($0.value.hex)" } ?? []
                log.add("scan: found \(p.name ?? "?") \(p.identifier.uuidString.prefix(8)) fw=\(info.firmware) bat=\(info.battery)% rssi=\(rssi) "
                        + "services=\((ad[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID])?.map(\.uuidString) ?? []) "
                        + "overflow=\((ad[CBAdvertisementDataOverflowServiceUUIDsKey] as? [CBUUID])?.map(\.uuidString) ?? []) "
                        + "serviceData=\(serviceData) localName=\(ad[CBAdvertisementDataLocalNameKey] as? String ?? "-") "
                        + "connectable=\(ad[CBAdvertisementDataIsConnectable] ?? "-") md=\(md.hex)")
                notifyUser("D·NOTE card discovered")
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect p: CBPeripheral) {
        MainActor.assumeIsolated {
            log.add("central: connected \(p.identifier.uuidString.prefix(8))")
            p.delegate = self
            p.discoverServices([DNote.service])
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated {
            log.add("central: failed to connect \(error?.localizedDescription ?? "")")
            ready?.resume(throwing: error ?? ProbeError.notConnected); ready = nil
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated {
            log.add("central: disconnected \(error?.localizedDescription ?? "(by app)")")
            connected = nil; writeChar = nil
            for (_, w) in waiters { w.resume(throwing: ProbeError.notConnected) }
            waiters = [:]
            notifyUser("D·NOTE 连接断开")
            // Unexpected drop: register a pending connect so iOS reconnects when the card advertises.
            if error != nil { connectWhenSeen() }
        }
    }
}

extension Probe: CBPeripheralDelegate {
    nonisolated func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        MainActor.assumeIsolated {
            guard let s = p.services?.first(where: { $0.uuid == DNote.service }) else {
                log.add("gatt: service 6001 missing"); return
            }
            p.discoverCharacteristics([DNote.writeChar, DNote.notifyChar], for: s)
        }
    }

    nonisolated func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        MainActor.assumeIsolated {
            for ch in s.characteristics ?? [] {
                if ch.uuid == DNote.writeChar { writeChar = ch }
                if ch.uuid == DNote.notifyChar { p.setNotifyValue(true, for: ch) }
            }
        }
    }

    nonisolated func peripheral(_ p: CBPeripheral, didUpdateNotificationStateFor ch: CBCharacteristic, error: Error?) {
        MainActor.assumeIsolated {
            guard ch.isNotifying else { return }
            connected = p
            log.add("gatt: ready mtu(write)=\(p.maximumWriteValueLength(for: .withResponse)) "
                    + "mtu(noresp)=\(p.maximumWriteValueLength(for: .withoutResponse))")
            if let r = ready { ready = nil; r.resume() } else { notifyUser("D·NOTE 已重连") }
        }
    }

    nonisolated func peripheral(_ p: CBPeripheral, didWriteValueFor ch: CBCharacteristic, error: Error?) {
        guard let error else { return }
        MainActor.assumeIsolated { log.add("gatt: write error \(error.localizedDescription)") }
    }

    nonisolated func peripheral(_ p: CBPeripheral, didUpdateValueFor ch: CBCharacteristic, error: Error?) {
        guard let data = ch.value else { return }
        MainActor.assumeIsolated { handleNotify(data) }
    }

    private func handleNotify(_ data: Data) {
        guard let f = parseFrame(data) else { log.add("notify: invalid \(data.hex)"); return }
        if f.cmd == Cmd.requestFileData, let h = chunkHandler { h(FileChunk(f.body)); return }
        if f.cmd == Cmd.queryFileList, let j = f.json {
            if (j["end"] as? Int) == 1 { listDone?.resume(); listDone = nil }
            else if let n = j["name"] as? String { listItems.append(CardFile(name: n, size: j["size"] as? Int ?? 0)) }
            return
        }
        if let w = waiters.removeValue(forKey: f.cmd) { w.resume(returning: f); return }
        // Unsolicited frame: this is what the background test watches for (e.g. button press).
        log.add(String(format: "notify: unsolicited cmd=0x%02x body=%@", f.cmd, f.text))
        if f.cmd == Cmd.queryRecStatus, let rec = f.json?["rec"] as? Int {
            notifyUser(rec == 1 ? "D·NOTE 开始录音" : "D·NOTE 停止录音")
            if rec == 0 { run("auto-list") { try await self.listAfterRecording() } }
        }
    }

    /// Recording stopped: re-list and report files not seen before.
    private func listAfterRecording() async throws {
        let before = Set(files.map(\.name))
        try await Task.sleep(for: .seconds(1))
        try await listFiles()
        let new = files.filter { !before.contains($0.name) }
        log.add("auto-list: new files \(new.map { "\($0.name)(\($0.size))" })")
        if !new.isEmpty { notifyUser("D·NOTE 新录音: " + new.map(\.name).joined(separator: ", ")) }
    }
}

extension Data {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
    var sha256: String { SHA256.hash(data: self).map { String(format: "%02x", $0) }.joined() }
}
