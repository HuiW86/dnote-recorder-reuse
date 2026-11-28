import CardProtocol
import CardService
import Foundation
import Library
import Observation

/// P07 device page: static card info, the seven card settings, disconnect and unpair
/// (product-spec.md P07, §5.3).
@MainActor
@Observable
public final class DeviceModel {
    public enum Setting: Hashable, Sendable {
        case led, motor, noiseCancel, vad, gain, noiseLevel, autoOff
    }

    /// Idle power-off delays offered, in seconds. `autoff` is in seconds and the card powers off
    /// when the delay passes without a connection (evidence/v38-card-link 03d). No "never":
    /// how the card takes it is unverified.
    public static let autoOffChoices = [300, 600, 1800, 3600]

    public let deviceId: UUID
    /// `0x81` as last read, with changes applied while they are sent; nil until read.
    public private(set) var switches: DeviceSwitches?
    /// Reading `0x81` failed; the settings group shows "读取失败" with a retry.
    public private(set) var switchesFailed = false
    /// Settings being sent; their rows show a spinner.
    public private(set) var pending: Set<Setting> = []
    public private(set) var unpairing = false
    public var toast: Toast?

    @ObservationIgnored private let session: CardSession
    @ObservationIgnored private let preferences: Preferences

    public init(session: CardSession, preferences: Preferences, deviceId: UUID) {
        self.session = session
        self.preferences = preferences
        self.deviceId = deviceId
    }

    // MARK: - Info

    public var device: Device? { session.pairedDevices.first { $0.id == deviceId } }

    public var status: DeviceStatus { session.status(of: deviceId) }

    /// Settings can be read and changed, also while recording (product-spec.md §5.3).
    public var isConnected: Bool {
        switch status {
        case .idle, .recording, .paused: true
        default: false
        }
    }

    public var battery: Int? { isConnected ? session.cardInfo?.battery : nil }

    /// Free card storage in MB; nil while not connected or not read yet (`total_df` 0 right
    /// after power-on, evidence/v38-card-link).
    public var freeSpaceMb: Int? {
        guard isConnected, let info = session.cardInfo, let total = info.totalSpace, total > 0 else { return nil }
        return info.freeSpace
    }

    /// Never the full serial on screen (product-spec.md §9).
    public var maskedSerial: String {
        guard let sn = device?.sn else { return "" }
        return "···" + sn.suffix(4)
    }

    public var firmware: String { device?.firmware ?? "" }

    /// Firmware other than the verified v1.50 (CLAUDE.md rule 7); shown, never blocking.
    public var firmwareUnverified: Bool {
        guard let version = device?.firmware, !version.isEmpty else { return false }
        if case .unverified = Firmware.check(version) { return true }
        return false
    }

    public func rename(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != device?.name else { return }
        do {
            try session.library.renameDevice(id: deviceId, to: trimmed)
            session.refreshDevices()
        } catch {
            toast = Toast("改名失败，请重试")
        }
    }

    // MARK: - Settings

    /// Reads `0x81` once connected, again after a reconnect, or with `force` ("重试"). Not while a
    /// setting is being sent: a read sent just before it would put the old value back on screen.
    public func load(force: Bool = false) async {
        guard isConnected else {
            switches = nil
            return
        }
        guard force || switches == nil, pending.isEmpty else { return }
        do {
            let read = try await retryingOnce { try await self.session.service.switches() }
            // A setting sent meanwhile has its own read-back; keep its value on screen.
            guard pending.isEmpty else { return }
            switches = read
            switchesFailed = false
        } catch {
            switchesFailed = switches == nil
        }
    }

    /// Sends a setting at once; the row spins meanwhile. On failure the value goes back and a
    /// Toast says so (product-spec.md P07). `CardService.set` reads `0x81` back to confirm.
    public func set(_ setting: CardSetting) {
        let key = Self.key(setting)
        guard isConnected, let before = switches, !pending.contains(key) else { return }
        pending.insert(key)
        switches = before.applying(setting)
        Task {
            defer { pending.remove(key) }
            do {
                try await retryingOnce { try await self.session.service.set(setting) }
            } catch {
                session.diagnostics?.add("device", "set \(key) failed: \(error)")
                switches = switches.map { $0.restoring(key, from: before) }
                toast = Toast("设置失败，请重试")
            }
        }
    }

    // MARK: - Delete after sync

    public var deleteAfterSync: Bool { preferences.deleteAfterSync(for: deviceId) }

    /// Turning it on needs the confirmation on P07 first; off takes effect at once.
    public func setDeleteAfterSync(_ on: Bool) {
        preferences.setDeleteAfterSync(on, for: deviceId)
        session.deleteAfterSyncChanged(for: deviceId)
    }

    // MARK: - Disconnect and unpair

    public func disconnect() { session.disconnect() }

    /// After 断开连接 the app stops looking for the card; 重新连接 starts again (the same as
    /// pulling down on 录音).
    public var canReconnect: Bool { session.userDisconnected && status == .waiting }

    public func reconnect() {
        guard canReconnect, let device else { return }
        do {
            try session.connectWhenSeen(device)
        } catch {
            toast = Toast((error as? CardServiceError)?.userText ?? "连接失败，请重试")
        }
    }

    /// Why "解绑此卡" is disabled; nil when it can be used (product-spec.md §5.3).
    public var unpairBlockedReason: String? {
        switch status {
        case .idle: nil
        case .recording, .paused: "请先停止录音"
        default: "请先连接录音卡"
        }
    }

    /// Returns true once the card is unpaired. The home screen then shows the next paired card,
    /// or first use when none is left (product-spec.md §2.1).
    public func unpair() async -> Bool {
        guard unpairBlockedReason == nil, let device, !unpairing else { return false }
        unpairing = true
        defer { unpairing = false }
        do {
            try await session.unpair(device)
            preferences.forget(deviceId)
            if preferences.currentDeviceId == nil { preferences.currentDeviceId = session.pairedDevices.first?.id }
            return true
        } catch {
            session.diagnostics?.add("device", "unpair failed: \(error)")
            toast = Toast((error as? CardServiceError)?.userText ?? "解绑失败，请重试")
            return false
        }
    }

    // MARK: - Helpers

    /// One automatic retry for a timeout or an unexpected reply, then the error (product-spec.md §7.1).
    private func retryingOnce<T>(_ operation: () async throws -> T) async throws -> T {
        do {
            return try await operation()
        } catch CardServiceError.requestTimeout, CardServiceError.unexpectedReply {
            return try await operation()
        }
    }

    static func key(_ setting: CardSetting) -> Setting {
        switch setting {
        case .led: .led
        case .motor: .motor
        case .noiseCancel: .noiseCancel
        case .vad: .vad
        case .gain: .gain
        case .noiseLevel: .noiseLevel
        case .autoOff: .autoOff
        }
    }
}

extension DeviceSwitches {
    func applying(_ setting: CardSetting) -> DeviceSwitches {
        var s = self
        switch setting {
        case .led(let on): s.led = on
        case .motor(let on): s.motor = on
        case .noiseCancel(let on): s.noiseCancel = on
        case .vad(let on): s.vad = on
        case .gain(let level): s.gain = level
        case .noiseLevel(let level): s.noiseLevel = level
        case .autoOff(let seconds): s.autoOffSeconds = Int(seconds)
        }
        return s
    }

    /// Puts one setting back, leaving others that changed meanwhile alone.
    func restoring(_ key: DeviceModel.Setting, from old: DeviceSwitches) -> DeviceSwitches {
        var s = self
        switch key {
        case .led: s.led = old.led
        case .motor: s.motor = old.motor
        case .noiseCancel: s.noiseCancel = old.noiseCancel
        case .vad: s.vad = old.vad
        case .gain: s.gain = old.gain
        case .noiseLevel: s.noiseLevel = old.noiseLevel
        case .autoOff: s.autoOffSeconds = old.autoOffSeconds
        }
        return s
    }
}
