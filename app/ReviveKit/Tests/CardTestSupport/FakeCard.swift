import CardLink
import CardProtocol
import Foundation

/// In-memory card behind the `CardLink` protocol (test-spec.md §2).
///
/// Behaviour follows PROTOCOL.md and the v1.50 evidence. Where the card's behaviour has
/// not been observed, the choice is marked "assumed" below; when the real card disagrees,
/// fix the fake and add a regression test.
///
/// Replies are queued on `events` synchronously inside `send`, so tests are deterministic.
@MainActor
public final class FakeCard: CardLink {
    public struct StoredFile: Equatable, Sendable {
        public var name: String
        public var content: Data

        public init(name: String, content: Data) {
            self.name = name
            self.content = content
        }
    }

    public enum Fault: Equatable, Sendable {
        /// Drop the link after this many `0x70` chunks of the next download.
        case disconnectAfterChunks(Int)
        /// Never answer this command (the write itself succeeds).
        case noResponse(Command)
        /// Replace chunk number `index` (0-based) of the next download with this status byte, then stop.
        case chunkStatus(index: Int, status: UInt8)
        /// Send chunk number `index` with a body shorter than the 5-byte header, then stop.
        case truncatedChunk(index: Int)
        /// Deliver every reply's notifications with neighbours swapped (1,0,3,2,...).
        case reorderNotifications
        /// Ack `0xA0` writes without changing the bond, so `0xA1` disagrees.
        case ignoreBondWrites
    }

    // MARK: Configuration and observable state

    public let id: UUID
    public var serial: String
    public var firmware: String
    public var files: [StoredFile]
    /// nil = not paired.
    public var bondId: Data?
    public var encryptionKey: Data?
    public var switches: DeviceSwitches
    public private(set) var recording: (name: String, state: RecordingState)?
    public var faults: [Fault] = []
    public var chunkSize = 200

    /// Every request written, in order, and its encoded bytes (test-spec.md §3.5 gate 2).
    public private(set) var sentRequests: [CardRequest] = []
    public private(set) var writtenFrames: [Data] = []

    // MARK: CardLink

    public private(set) var state: LinkState = .idle {
        didSet { if state != oldValue { continuation.yield(.state(state)) } }
    }
    public private(set) var peripheralId: UUID?
    public let events: AsyncStream<LinkEvent>
    private let continuation: AsyncStream<LinkEvent>.Continuation
    private var pendingConnect = false
    private var clock = Date(timeIntervalSince1970: 1_793_000_000)

    public init(id: UUID = UUID(), serial: String = "FAKESN0000000001", firmware: String = "1.50",
                files: [StoredFile] = [], paired: Bool = true) {
        self.id = id
        self.serial = serial
        self.firmware = firmware
        self.files = files
        self.bondId = paired ? Data(repeating: 0x42, count: 16) : nil
        self.switches = DeviceSwitches(usbStorage: false, led: true, motor: true, noiseCancel: true, saveWav: false,
                                       vad: false, gain: 4, noiseLevel: 4, autoOffSeconds: 600)
        (events, continuation) = AsyncStream.makeStream(of: LinkEvent.self)
    }

    public func startScan() {
        guard state != .connected else { return }  // a connected card does not advertise
        continuation.yield(.discovered(DiscoveredCard(id: id, name: "D·NOTE", advertisement: advertisement, rssi: -50)))
    }

    public func stopScan() {}

    public func connect(_ id: UUID) async throws {
        guard id == self.id else { throw LinkError.unknownPeripheral }
        peripheralId = id
        state = .connecting
        state = .connected
    }

    public func connectWhenSeen(_ id: UUID) throws {
        guard id == self.id else { throw LinkError.unknownPeripheral }
        peripheralId = id
        pendingConnect = true
        state = .connecting
    }

    public func disconnect() {
        pendingConnect = false
        state = .disconnected(.requested)
    }

    public func send(_ request: CardRequest) async throws {
        let frame = try request.encode()
        guard state == .connected else { throw LinkError.notConnected }
        sentRequests.append(request)
        writtenFrames.append(frame)
        if faults.contains(.noResponse(request.command)) { return }
        var replies = reply(to: request)
        if faults.contains(.reorderNotifications) {
            for i in stride(from: 0, to: replies.count - 1, by: 2) { replies.swapAt(i, i + 1) }
        }
        for r in replies {
            switch r {
            case .frame(let data): continuation.yield(.notification(data))
            case .drop: dropLink(); return
            }
        }
    }

    // MARK: Test controls

    /// The card advertises again: completes a pending connect, as iOS would.
    public func advertise() {
        guard pendingConnect else { return }
        pendingConnect = false
        state = .connected
    }

    /// Unexpected link loss; registers a pending connect like `BluetoothCardLink`.
    public func dropLink() {
        state = .disconnected(.lost)
        pendingConnect = true
        state = .connecting
    }

    /// Card button starts a recording: pushes `0x54 {name}`.
    public func pressButtonToRecord() {
        let name = startRecordingFile()
        push(DevicePush.recordingStarted.rawValue, json: ["name": name])
    }

    /// Card button stops the recording: pushes `0x56 {rec:0}` then an empty `0x55`.
    public func pressButtonToStop() {
        for f in finishRecording() { continuation.yield(.notification(f)) }
    }

    /// Periodic `0x80` push (about every 4 minutes on the real card).
    public func pushDeviceInfo() {
        continuation.yield(.notification(deviceInfoFrame()))
    }

    /// Replays notifications captured on a real card, byte for byte (see `EvidenceLog`).
    public func replay(_ notifications: [Data]) {
        for n in notifications { continuation.yield(.notification(n)) }
    }

    /// True when every written frame is a whitelisted command (test-spec.md §3.5 gate 2).
    public var wroteOnlyWhitelistedCommands: Bool {
        writtenFrames.allSatisfy { $0.count >= 2 && Command(rawValue: $0[$0.startIndex + 1]) != nil }
    }

    public var advertisement: Advertisement {
        let parts = firmware.split(separator: ".").compactMap { UInt8($0) }
        let md: [UInt8] = [0xA3, 0x22, 0, 1, 0, 2, parts.first ?? 0, parts.dropFirst().first ?? 0, 1, 0, 80, 1, 0, 0, 1]
        return Advertisement(manufacturerData: Data(md))!
    }

    // MARK: Behaviour

    private enum Reply {
        case frame(Data)
        case drop
    }

    private var paired: Bool { bondId != nil }
    private var isRecording: Bool { recording != nil }
    private static let ack = Data([0x01])

    private func reply(to request: CardRequest) -> [Reply] {
        let cmd = request.command.rawValue
        switch request {
        case .deviceInfo:
            return [.frame(deviceInfoFrame())]
        case .switches:
            return [.frame(Self.frame(cmd, json: switchesJSON()))]
        case .recordingStatus:
            return [.frame(recordingStatusFrame())]
        case .bondStatus:
            let body = bondId.map { Data([1]) + $0 } ?? Data([0])
            return [.frame(Self.frame(cmd, body))]
        case .encryptionStatus:
            // Assumed format: one byte, 1 when a key is set.
            return [.frame(Self.frame(cmd, Data([encryptionKey == nil ? 0 : 1])))]
        case .set(let setting):
            apply(setting)
            return [.frame(Self.frame(cmd, Self.ack))]
        case .syncTime:
            return [.frame(Self.frame(cmd, Self.ack))]
        case .startRecording:
            guard paired else { return [.frame(Self.frame(cmd, Data("NULL".utf8)))] }
            let name = recording?.name ?? startRecordingFile()
            return [.frame(Self.frame(cmd, json: ["name": name]))]
        case .stopRecording:
            guard isRecording else { return [.frame(Self.frame(cmd, Self.ack))] }
            return [.frame(Self.frame(cmd, Self.ack))] + finishRecording().map { .frame($0) }
        case .pauseRecording, .resumeRecording:
            if let r = recording {
                recording = (r.name, request == .pauseRecording ? .paused : .recording)
            }
            return [.frame(Self.frame(cmd, Self.ack))]
        case .listFiles:
            guard paired else { return [] }  // unpaired: no response (#5)
            let end = Self.frame(cmd, json: ["index": isRecording ? 0 : files.count, "end": 1])
            if isRecording { return [.frame(end)] }  // recording: empty list (#5)
            let items = files.enumerated().map { i, f in
                Reply.frame(Self.frame(cmd, json: ["index": i, "name": f.name, "size": f.content.count, "end": 0]))
            }
            return items + [.frame(end)]
        case .download(let name, let offset):
            guard paired else { return [] }  // assumed: same as 0x90
            return downloadReplies(name: name, offset: offset)
        case .delete(let name):
            // No reply (PROTOCOL.md §4.2); the file is gone on the next list.
            if paired { files.removeAll { $0.name == name } }
            return []
        case .bond(let id):
            if !faults.contains(.ignoreBondWrites) { bondId = id }
            return [.frame(Self.frame(cmd, Self.ack))]
        case .unbond:
            if !faults.contains(.ignoreBondWrites) { bondId = nil }
            return [.frame(Self.frame(cmd, Self.ack))]
        case .setEncryptionKey(let enabled, let key):
            // Assumed reply: single 0x01 like the other settings.
            encryptionKey = enabled ? key : nil
            return [.frame(Self.frame(cmd, Self.ack))]
        }
    }

    private func downloadReplies(name: String, offset: Int) -> [Reply] {
        let cmd = Command.fileData.rawValue
        guard let file = files.first(where: { $0.name == name }) else {
            return [.frame(Self.chunk(status: 0xF0, offset: 0, Data()))]
        }
        var replies: [Reply] = []
        let content = file.content
        var pos = min(offset, content.count)
        var index = 0
        repeat {
            let end = min(pos + chunkSize, content.count)
            if faults.contains(.disconnectAfterChunks(index)) {
                faults.removeAll { $0 == .disconnectAfterChunks(index) }
                return replies + [.drop]
            }
            if let fault = faults.first(where: { if case .chunkStatus(index, _) = $0 { true } else { false } }),
               case .chunkStatus(_, let status) = fault {
                faults.removeAll { $0 == fault }
                return replies + [.frame(Self.chunk(status: status, offset: UInt32(pos), Data()))]
            }
            if faults.contains(.truncatedChunk(index: index)) {
                faults.removeAll { $0 == .truncatedChunk(index: index) }
                return replies + [.frame(Self.frame(cmd, Data([0x00, 0x00])))]
            }
            let status: UInt8 = end == content.count ? 0x20 : 0x00
            replies.append(.frame(Self.chunk(status: status, offset: UInt32(pos), content[pos..<end])))
            pos = end
            index += 1
        } while pos < content.count
        return replies
    }

    private func apply(_ s: CardSetting) {
        switch s {
        case .led(let on): switches.led = on
        case .motor(let on): switches.motor = on
        case .noiseCancel(let on): switches.noiseCancel = on
        case .vad(let on): switches.vad = on
        case .gain(let level): switches.gain = level
        case .noiseLevel(let level): switches.noiseLevel = level
        case .autoOff(let seconds): switches.autoOffSeconds = Int(seconds)
        }
    }

    private func startRecordingFile() -> String {
        clock += 60
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMddHHmmss"
        let name = f.string(from: clock) + ".opus"
        recording = (name, .recording)
        return name
    }

    /// Stores the recording as a small plaintext Opus stream and returns the stop pushes.
    private func finishRecording() -> [Data] {
        if let r = recording {
            files.append(StoredFile(name: r.name, content: Data(repeating: 0x08, count: 40 * 50)))
            recording = nil
        }
        return [recordingStatusFrame(), Self.frame(DevicePush.recordingStopped.rawValue, Data())]
    }

    private func push(_ cmd: UInt8, json: [String: Any]) {
        continuation.yield(.notification(Self.frame(cmd, json: json)))
    }

    private func deviceInfoFrame() -> Data {
        Self.frame(Command.deviceInfo.rawValue, json: [
            "sn": serial, "v": firmware, "time": "2026-11-07 09:00:00", "rec": recordingCode, "recmode": 0,
            "usb": 0, "bat": 80, "df": 7000, "total_df": 7671, "bt": "D·NOTE", "wifiap": 0,
        ])
    }

    private func recordingStatusFrame() -> Data {
        Self.frame(Command.recordingStatus.rawValue, json: [
            "name": recording?.name ?? "", "size": 0, "recd": 0, "rec": recordingCode, "upload": 0,
        ])
    }

    private var recordingCode: Int {
        switch recording?.state {
        case .recording: 1
        case .paused: 2
        default: 0
        }
    }

    private func switchesJSON() -> [String: Any] {
        [
            "ms": (switches.usbStorage ?? false) ? 1 : 0, "led": switches.led ? 1 : 0,
            "motor": switches.motor ? 1 : 0, "nc": switches.noiseCancel ? 1 : 0,
            "wav": (switches.saveWav ?? false) ? 1 : 0, "vad": switches.vad ? 1 : 0,
            "gain": switches.gain, "nn": switches.noiseLevel, "autoff": switches.autoOffSeconds,
        ]
    }

    // MARK: Frame builders (card -> phone; any CMD byte, unlike CardRequest)

    nonisolated public static func frame(_ cmd: UInt8, _ body: Data) -> Data {
        precondition(body.count <= 255)
        return Data([Frame.pid, cmd, UInt8(body.count)]) + body
    }

    nonisolated static func frame(_ cmd: UInt8, json: [String: Any]) -> Data {
        frame(cmd, try! JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]))
    }

    nonisolated static func chunk(status: UInt8, offset: UInt32, _ data: Data) -> Data {
        frame(Command.fileData.rawValue, Data([status]) + withUnsafeBytes(of: offset.bigEndian) { Data($0) } + data)
    }
}
