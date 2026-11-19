import CardLink
import CardProtocol
import Foundation
import os

// Device operations, pairing and unsolicited events (prd.md §2.3, §3).

/// Events for the UI and SyncEngine. Single consumer, like `CardLink.events`.
public enum CardEvent: Equatable, Sendable {
    case discovered(DiscoveredCard)
    /// Every link state change except disconnects, which arrive as `disconnected`.
    case stateChanged(LinkState)
    case disconnected(DisconnectReason)
    /// `0x54`: recording started with the card button.
    case recordingStarted(name: String)
    /// `0x56 {rec:0}` or `0x55`; reported once per stop.
    case recordingStopped
    /// Any `0x80`, polled or the periodic push.
    case deviceInfo(DeviceInfo)
    /// Firmware outside the verified table (prd.md §2.4); a warning, never a block.
    case firmwareUnverified(version: String)
}

@MainActor
public final class CardService {
    public struct Timing: Sendable {
        public var request: Duration
        /// No `0x90` reply within this time means the card is not paired (prd.md §2.3).
        public var listFiles: Duration
        /// Download timeout = remaining bytes / this rate + `downloadSlack`.
        public var downloadBytesPerSecond: Double
        public var downloadSlack: Duration

        public init(request: Duration = .seconds(5), listFiles: Duration = .seconds(8),
                    downloadBytesPerSecond: Double = 15_000, downloadSlack: Duration = .seconds(10)) {
            self.request = request
            self.listFiles = listFiles
            self.downloadBytesPerSecond = downloadBytesPerSecond
            self.downloadSlack = downloadSlack
        }
    }

    public let events: AsyncStream<CardEvent>
    public var linkState: LinkState { link.state }
    public var peripheralId: UUID? { link.peripheralId }
    /// Latest `0x80` seen on this link.
    public private(set) var lastInfo: DeviceInfo?

    private let link: any CardLink
    private let bondStore: any BondStore
    /// Settable so a test can connect with patient timeouts and then shorten only the one it
    /// exercises; the app sets it once, at init.
    var timing: Timing
    private let now: () -> Date
    private let timeZone: () -> TimeZone
    private let continuation: AsyncStream<CardEvent>.Continuation
    private let log = Logger(subsystem: "revive", category: "CardService")

    private var waiters: [UInt8: Waiter] = [:]
    private var busy: Set<UInt8> = []
    private var queued: [UInt8: [CheckedContinuation<Void, Never>]] = [:]
    /// Set while `connect` runs the after-connect routine itself.
    private var connectInProgress = false
    /// A stop is pushed as `0x56 {rec:0}` followed by `0x55`; report it once.
    private var stopReported = false

    public init(link: any CardLink, bondStore: any BondStore, timing: Timing = Timing(),
                now: @escaping () -> Date = Date.init, timeZone: @escaping () -> TimeZone = { .current }) {
        self.link = link
        self.bondStore = bondStore
        self.timing = timing
        self.now = now
        self.timeZone = timeZone
        (events, continuation) = AsyncStream.makeStream(of: CardEvent.self)
        let linkEvents = link.events
        Task { [weak self] in
            for await event in linkEvents { self?.handle(event) }
        }
    }

    // MARK: - Connection

    public func startScan() { link.startScan() }
    public func stopScan() { link.stopScan() }

    /// Connects, then reads `0x80` (firmware check) and syncs the clock, as after every connect.
    @discardableResult
    public func connect(_ id: UUID) async throws -> DeviceInfo {
        connectInProgress = true
        defer { connectInProgress = false }
        do {
            try await link.connect(id)
        } catch {
            throw CardServiceError.from(error)
        }
        return try await afterConnect()
    }

    /// Pending connect; the after-connect routine runs when the card shows up.
    public func connectWhenSeen(_ id: UUID) throws {
        do { try link.connectWhenSeen(id) } catch { throw CardServiceError.from(error) }
    }

    public func disconnect() { link.disconnect() }

    // MARK: - Queries and settings

    public func info() async throws -> DeviceInfo {
        let info = try await request(.deviceInfo, parse: DeviceInfo.parse)
        lastInfo = info
        return info
    }

    public func switches() async throws -> DeviceSwitches {
        try await request(.switches, parse: DeviceSwitches.parse)
    }

    /// Writes a setting, waits for the `0x01` ack, then reads `0x81` back to confirm it.
    public func set(_ setting: CardSetting) async throws {
        let req = CardRequest.set(setting)
        try await ack(req)
        guard try await switches().reflects(setting) else { throw CardServiceError.unexpectedReply(req.command) }
    }

    /// Sets the card clock to the phone's local time.
    public func syncTime() async throws {
        try await ack(.syncTime(now(), timeZone()))
    }

    public func recordingStatus() async throws -> RecordingStatus {
        let status = try await request(.recordingStatus, parse: RecordingStatus.parse)
        // A recording known only from here (a start whose reply was lost, #47) still needs its stop reported.
        if status.state != .idle { stopReported = false }
        return status
    }

    // MARK: - Recording

    /// Returns the new file name (`YYYYMMDDHHmmss.opus`).
    public func startRecording() async throws -> String {
        let reply = try await request(.startRecording, parse: StartRecordingReply.parse)
        switch reply {
        case .started(let name):
            stopReported = false
            return name
        case .notPaired:
            throw CardServiceError.notPaired
        }
    }

    public func stopRecording() async throws { try await ack(.stopRecording) }
    public func pause() async throws { try await ack(.pauseRecording) }
    public func resume() async throws { try await ack(.resumeRecording) }

    // MARK: - Files

    /// Files on the card. Throws `cardBusyRecording` instead of returning the empty list a
    /// recording card sends, which would wrongly mean "no files" (#5). The card lists files
    /// whether or not it is paired (#38 E); check pairing with `isPairedWithThisPhone`.
    public func listFiles() async throws -> [CardFile] {
        var files: [CardFile] = []
        try await exchange(.listFiles, timeout: timing.listFiles) { frame in
            switch FileListMessage.parse(frame) {
            case .file(let f): files.append(f); return false
            case .end: return true
            case nil: throw CardServiceError.unexpectedReply(.listFiles)
            }
        }
        if files.isEmpty, try await recordingStatus().state != .idle {
            throw CardServiceError.cardBusyRecording
        }
        return files
    }

    /// Downloads `file` from byte `offset` to the end, handing each chunk to `onData` as it
    /// arrives. On failure, bytes already handed over stay valid: resume from
    /// `offset + received` on the next connection (#34).
    public func download(_ file: CardFile, from offset: Int = 0, onData: @escaping (Data) -> Void) async throws {
        guard offset >= 0, offset <= file.size else {
            throw CardServiceError.invalidArgument("offset \(offset) for size \(file.size)")
        }
        let remaining = file.size - offset
        var next = offset
        let timeout = .seconds(Double(remaining) / timing.downloadBytesPerSecond) + timing.downloadSlack
        try await exchange(.download(name: file.name, offset: offset), timeout: timeout) { frame in
            if FileChunk.isRefusal(frame) { throw CardServiceError.cardBusy }
            guard let chunk = FileChunk.parse(frame) else { throw CardServiceError.transferFailed }
            switch chunk.status {
            case .notFound: throw CardServiceError.fileNotFound
            case .cancelled, .error: throw CardServiceError.transferFailed
            case .data, .eof:
                // Offset is the chunk's position in the file (#34); a jump means lost notifications.
                guard Int(chunk.offset) == next, next + chunk.data.count <= file.size else {
                    throw CardServiceError.transferFailed
                }
                onData(chunk.data)
                next += chunk.data.count
                guard chunk.status == .eof else { return false }
                guard next == file.size else { throw CardServiceError.transferFailed }
                return true
            }
        }
    }

    /// Whole download from `offset` in memory.
    public func download(_ file: CardFile, from offset: Int = 0) async throws -> Data {
        var data = Data()
        try await download(file, from: offset) { data.append($0) }
        return data
    }

    /// Deletes a file on the card. The v1.50 card acks with `0x01` (#38 E), but the ack is not
    /// awaited: the outcome is confirmed with `listFiles`. Only SyncEngine may call this, after the file is stored locally (CLAUDE.md rule 2).
    public func delete(_ name: String) async throws {
        let req = CardRequest.delete(name: name)
        await acquire(req.command.rawValue)
        defer { release(req.command.rawValue) }
        do { try await link.send(req) } catch { throw CardServiceError.from(error) }
    }

    // MARK: - Pairing (prd.md §3)

    /// Pairs on the current connection and returns the bondId.
    ///
    /// Order: `0x80` → `0xA1` (query) → `0x87` → `0xA2` → [`0xA0 [0]`] → `0xA0 [1]` → `0xA1`.
    /// A card already bonded to this phone is left alone. A card bonded elsewhere is only
    /// unbonded after `confirmRebind` returns true; until then nothing is written.
    public func pair(confirmRebind: () async -> Bool) async throws -> Data {
        let serial = try await infoRetryingOnce().serial
        let status = try await bondStatus()
        let local = try bondStore.bondId(serial: serial)
        if status.isBonded, let id = status.bondId, id == local { return id }
        if status.isBonded {
            guard await confirmRebind() else { throw CardServiceError.pairCancelled }
        }

        do { try await syncTime() } catch { log.error("syncTime during pairing failed: \(String(describing: error))") }
        // The v1.50 card acks 0xA2 with 0x01 (#38 D). It is sent before any bond write, so a
        // refusal leaves the card as it was.
        try await ack(.setEncryptionKey(enabled: true, key: AudioCrypto.deviceKey(serial: serial)))
        if status.isBonded { try await ack(.unbond) }

        let bondId = Data((0..<16).map { _ in UInt8.random(in: .min ... .max) })
        try await ack(.bond(bondId: bondId))
        let check = try await bondStatus()
        guard check.isBonded, check.bondId == bondId else { throw CardServiceError.pairVerifyFailed }
        try bondStore.save(bondId, serial: serial)
        return bondId
    }

    /// `0xA0 [0]`, confirmed by `0xA1`, then forgets the local bondId. Recordings are untouched.
    public func unpair() async throws {
        let serial = try await currentSerial()
        try await ack(.unbond)
        guard try await !bondStatus().isBonded else { throw CardServiceError.pairVerifyFailed }
        try bondStore.remove(serial: serial)
    }

    /// Whether the card is bonded to this phone.
    public func isPairedWithThisPhone() async throws -> Bool {
        let serial = try await currentSerial()
        let status = try await bondStatus()
        let local = try bondStore.bondId(serial: serial)
        return status.isBonded && status.bondId != nil && status.bondId == local
    }

    private func currentSerial() async throws -> String {
        if let serial = lastInfo?.serial { return serial }
        return try await info().serial
    }

    private func bondStatus() async throws -> BondStatus {
        try await request(.bondStatus, parse: BondStatus.parse)
    }

    private func infoRetryingOnce() async throws -> DeviceInfo {
        do {
            return try await info()
        } catch CardServiceError.requestTimeout {
            return try await info()
        }
    }

    // MARK: - After connect

    private func afterConnect() async throws -> DeviceInfo {
        stopReported = false
        let info = try await info()
        if case .unverified(let version) = Firmware.check(info.firmware) {
            log.notice("unverified firmware \(version, privacy: .public)")
            continuation.yield(.firmwareUnverified(version: version))
        }
        do { try await syncTime() } catch { log.error("syncTime after connect failed: \(String(describing: error))") }
        return info
    }

    // MARK: - Link events

    private func handle(_ event: LinkEvent) {
        switch event {
        case .discovered(let card):
            continuation.yield(.discovered(card))
        case .state(let state):
            // Events are delivered asynchronously, so judge the link by its current state: a stale
            // `.connecting` from before `connect` returned must not fail requests on the new link.
            if link.state != .connected {
                failWaiters(.disconnected)
                // A stale 0x80 would name the previous card after a reconnect to another one.
                lastInfo = nil
            }
            if case .disconnected(let reason) = state {
                continuation.yield(.disconnected(reason))
            } else {
                continuation.yield(.stateChanged(state))
            }
            // Reconnects (pending connect, restoration) run the routine here; `connect` runs its own.
            if state == .connected, link.state == .connected, !connectInProgress {
                Task { [weak self] in _ = try? await self?.afterConnect() }
            }
        case .notification(let data):
            guard let frame = Frame.parse(data) else {
                log.error("unparsable notification, \(data.count) bytes")
                return
            }
            handle(frame)
        }
    }

    private func handle(_ frame: Frame) {
        if frame.command == .deviceInfo, let info = DeviceInfo.parse(frame) {
            lastInfo = info
            if info.recordingState != .idle { stopReported = false }
            continuation.yield(.deviceInfo(info))
        }
        if let waiter = waiters[frame.cmd] {
            waiter.receive(frame)
            return
        }
        switch frame.cmd {
        case DevicePush.recordingStarted.rawValue:
            stopReported = false
            if let name = recordingStartedName(frame) { continuation.yield(.recordingStarted(name: name)) }
        case DevicePush.recordingStopped.rawValue:
            reportStop()
        case Command.recordingStatus.rawValue:
            if RecordingStatus.parse(frame)?.state == .idle { reportStop() }
        case Command.deviceInfo.rawValue:
            break  // handled above
        default:
            log.notice("unsolicited frame 0x\(String(frame.cmd, radix: 16), privacy: .public)")
        }
    }

    private func reportStop() {
        guard !stopReported else { return }
        stopReported = true
        continuation.yield(.recordingStopped)
    }

    private func failWaiters(_ error: CardServiceError) {
        for waiter in waiters.values { waiter.complete(.failure(error)) }
    }

    // MARK: - Request / response

    /// One reply frame, parsed. A frame that does not parse is `unexpectedReply`.
    private func request<T>(_ req: CardRequest, parse: @escaping (Frame) -> T?) async throws -> T {
        var value: T?
        try await exchange(req, timeout: timing.request) { frame in
            guard let v = parse(frame) else { throw CardServiceError.unexpectedReply(req.command) }
            value = v
            return true
        }
        return value!
    }

    /// One reply that must be the single-byte `0x01` ack.
    private func ack(_ req: CardRequest) async throws {
        _ = try await request(req) { $0.isAck ? () : nil }
    }

    /// Sends `req` and feeds every frame with the same CMD byte to `onFrame` until it returns
    /// true. Requests with the same CMD byte run one at a time; others run concurrently.
    private func exchange(_ req: CardRequest, timeout: Duration,
                          onFrame: @escaping (Frame) throws -> Bool) async throws {
        let cmd = req.command.rawValue
        await acquire(cmd)
        defer { release(cmd) }
        guard link.state == .connected else { throw CardServiceError.disconnected }

        let waiter = Waiter(onFrame: onFrame)
        waiters[cmd] = waiter
        defer { if waiters[cmd] === waiter { waiters[cmd] = nil } }
        do {
            try await link.send(req)
        } catch {
            throw CardServiceError.from(error)
        }
        let timer = Task { [weak waiter] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            waiter?.complete(.failure(.requestTimeout(req.command)))
        }
        defer { timer.cancel() }
        try await waiter.wait()
    }

    private func acquire(_ cmd: UInt8) async {
        guard busy.contains(cmd) else {
            busy.insert(cmd)
            return
        }
        await withCheckedContinuation { queued[cmd, default: []].append($0) }
    }

    /// Hands the command to the next queued request, if any; `busy` stays set in that case.
    private func release(_ cmd: UInt8) {
        if var queue = queued[cmd], !queue.isEmpty {
            let next = queue.removeFirst()
            queued[cmd] = queue.isEmpty ? nil : queue
            next.resume()
        } else {
            busy.remove(cmd)
        }
    }
}

/// One in-flight request. Completed by its frames, a link drop, or its timer, whichever is first.
@MainActor
private final class Waiter {
    private let onFrame: (Frame) throws -> Bool
    private var result: Result<Void, CardServiceError>?
    private var continuation: CheckedContinuation<Void, Error>?

    init(onFrame: @escaping (Frame) throws -> Bool) {
        self.onFrame = onFrame
    }

    func receive(_ frame: Frame) {
        guard result == nil else { return }
        do {
            if try onFrame(frame) { complete(.success(())) }
        } catch {
            complete(.failure(CardServiceError.from(error)))
        }
    }

    func complete(_ r: Result<Void, CardServiceError>) {
        guard result == nil else { return }
        result = r
        continuation?.resume(with: r.mapError { $0 as Error })
        continuation = nil
    }

    func wait() async throws {
        if let result { return try result.get() }
        try await withCheckedThrowingContinuation { continuation = $0 }
    }
}
