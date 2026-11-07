import Foundation

// Typed responses. JSON field names stay in this file; upper layers see Swift types
// (prd.md §1). Field meanings follow PROTOCOL.md §4, verified on firmware v1.50.

extension Frame {
    /// Settings, bond and recording control reply with a single 0x01 byte.
    public var isAck: Bool { body == Data([0x01]) }
}

/// `0x80` device info.
public struct DeviceInfo: Equatable, Sendable {
    public var serial: String
    public var firmware: String
    /// Card clock as `YYYY-MM-DD HH:mm:ss`.
    public var time: String?
    public var recordingState: RecordingState
    public var battery: Int?
    /// Free and total storage; unit is presumably MB.
    public var freeSpace: Int?
    public var totalSpace: Int?
    public var bluetoothName: String?
    public var hotspotOn: Bool?

    public init(serial: String, firmware: String, time: String? = nil, recordingState: RecordingState = .idle,
                battery: Int? = nil, freeSpace: Int? = nil, totalSpace: Int? = nil,
                bluetoothName: String? = nil, hotspotOn: Bool? = nil) {
        self.serial = serial
        self.firmware = firmware
        self.time = time
        self.recordingState = recordingState
        self.battery = battery
        self.freeSpace = freeSpace
        self.totalSpace = totalSpace
        self.bluetoothName = bluetoothName
        self.hotspotOn = hotspotOn
    }

    public static func parse(_ frame: Frame) -> DeviceInfo? {
        guard frame.cmd == Command.deviceInfo.rawValue, let raw = frame.decode(Raw.self) else { return nil }
        return DeviceInfo(serial: raw.sn, firmware: raw.v, time: raw.time,
                          recordingState: RecordingState(code: raw.rec ?? 0), battery: raw.bat,
                          freeSpace: raw.df, totalSpace: raw.total_df, bluetoothName: raw.bt,
                          hotspotOn: raw.wifiap.map { $0 != 0 })
    }

    // btaddr is not read: the app has no use for it and it must not end up in logs (CLAUDE.md rule 4).
    private struct Raw: Decodable {
        let sn: String
        let v: String
        let time: String?
        let rec: Int?
        let bat: Int?
        let df: Int?
        let total_df: Int?
        let bt: String?
        let wifiap: Int?
    }
}

/// `0x81` switch states (#34).
public struct DeviceSwitches: Equatable, Sendable {
    public var usbStorage: Bool?
    public var led: Bool
    public var motor: Bool
    public var noiseCancel: Bool
    public var saveWav: Bool?
    public var vad: Bool
    public var gain: Int
    public var noiseLevel: Int
    public var autoOffSeconds: Int

    public init(usbStorage: Bool? = nil, led: Bool, motor: Bool, noiseCancel: Bool, saveWav: Bool? = nil,
                vad: Bool, gain: Int, noiseLevel: Int, autoOffSeconds: Int) {
        self.usbStorage = usbStorage
        self.led = led
        self.motor = motor
        self.noiseCancel = noiseCancel
        self.saveWav = saveWav
        self.vad = vad
        self.gain = gain
        self.noiseLevel = noiseLevel
        self.autoOffSeconds = autoOffSeconds
    }

    public static func parse(_ frame: Frame) -> DeviceSwitches? {
        guard frame.cmd == Command.switches.rawValue, let r = frame.decode(Raw.self) else { return nil }
        return DeviceSwitches(usbStorage: r.ms.map { $0 != 0 }, led: r.led != 0, motor: r.motor != 0,
                              noiseCancel: r.nc != 0, saveWav: r.wav.map { $0 != 0 }, vad: r.vad != 0,
                              gain: r.gain, noiseLevel: r.nn, autoOffSeconds: r.autoff)
    }

    /// Whether `setting` is reflected in these switches; used to read back after a set.
    public func reflects(_ setting: CardSetting) -> Bool {
        switch setting {
        case .led(let on): led == on
        case .motor(let on): motor == on
        case .noiseCancel(let on): noiseCancel == on
        case .vad(let on): vad == on
        case .gain(let level): gain == level
        case .noiseLevel(let level): noiseLevel == level
        case .autoOff(let seconds): autoOffSeconds == Int(seconds)
        }
    }

    private struct Raw: Decodable {
        let ms: Int?
        let led: Int
        let motor: Int
        let nc: Int
        let wav: Int?
        let vad: Int
        let gain: Int
        let nn: Int
        let autoff: Int
    }
}

public enum RecordingState: Equatable, Sendable {
    case idle, recording, paused
    case unknown(Int)

    public init(code: Int) {
        switch code {
        case 0: self = .idle
        case 1: self = .recording
        case 2: self = .paused
        default: self = .unknown(code)
        }
    }
}

/// `0x56` recording status, polled or pushed after a stop.
public struct RecordingStatus: Equatable, Sendable {
    /// Current file; empty when idle.
    public var name: String
    public var size: Int
    public var state: RecordingState
    /// Recorded time in ms (`recd`), as counted by the card; nil when the field is absent.
    /// Size and `recd` grow 2:1 on v1.50 (evidence/v34-device-check); whether `recd` stops
    /// while paused is still to be checked on a real card.
    public var recordedMs: Int?

    public init(name: String, size: Int, state: RecordingState, recordedMs: Int? = nil) {
        self.name = name
        self.size = size
        self.state = state
        self.recordedMs = recordedMs
    }

    public static func parse(_ frame: Frame) -> RecordingStatus? {
        guard frame.cmd == Command.recordingStatus.rawValue, let r = frame.decode(Raw.self) else { return nil }
        return RecordingStatus(name: r.name ?? "", size: r.size ?? 0, state: RecordingState(code: r.rec),
                               recordedMs: r.recd)
    }

    private struct Raw: Decodable {
        let name: String?
        let size: Int?
        let rec: Int
        let recd: Int?
    }
}

/// Reply to `0x51`: a new file name, or `NULL` when the card is not paired (#5).
public enum StartRecordingReply: Equatable, Sendable {
    case started(name: String)
    case notPaired

    public static func parse(_ frame: Frame) -> StartRecordingReply? {
        guard frame.cmd == Command.startRecording.rawValue else { return nil }
        if let name = frame.decode(NameOnly.self)?.name, !name.isEmpty { return .started(name: name) }
        return frame.text.trimmingCharacters(in: .whitespacesAndNewlines) == "NULL" ? .notPaired : nil
    }
}

/// `0x54` push: recording started with the card button.
public func recordingStartedName(_ frame: Frame) -> String? {
    guard frame.push == .recordingStarted else { return nil }
    return frame.decode(NameOnly.self)?.name
}

private struct NameOnly: Decodable {
    let name: String?
}

public struct CardFile: Equatable, Hashable, Sendable {
    public var name: String
    /// Bytes on the card, including the encryption header when encrypted.
    public var size: Int

    public init(name: String, size: Int) {
        self.name = name
        self.size = size
    }
}

/// One `0x90` notification: a file entry, or the terminator with `end=1`.
public enum FileListMessage: Equatable, Sendable {
    case file(CardFile)
    case end

    public static func parse(_ frame: Frame) -> FileListMessage? {
        guard frame.cmd == Command.listFiles.rawValue, let r = frame.decode(Raw.self) else { return nil }
        if r.end == 1 { return .end }
        guard let name = r.name, !name.isEmpty else { return nil }
        return .file(CardFile(name: name, size: r.size ?? 0))
    }

    private struct Raw: Decodable {
        let name: String?
        let size: Int?
        let end: Int?
    }
}

/// `0xA1`: [isBonded(1)][bondId(16)]; bondId is absent when not bonded.
public struct BondStatus: Equatable, Sendable {
    public var isBonded: Bool
    public var bondId: Data?

    public init(isBonded: Bool, bondId: Data?) {
        self.isBonded = isBonded
        self.bondId = bondId
    }

    public static func parse(_ frame: Frame) -> BondStatus? {
        guard frame.cmd == Command.bondStatus.rawValue, let first = frame.body.first else { return nil }
        let id = frame.body.count >= 17 ? Data(frame.body.dropFirst().prefix(16)) : nil
        return BondStatus(isBonded: first == 1, bondId: id)
    }
}

/// `0x70` chunk: [start(1)][offset(4, BE)][data...]; status is `start & 0xF0` (PROTOCOL.md §5).
public struct FileChunk: Equatable, Sendable {
    public enum Status: Equatable, Sendable {
        case data, eof, cancelled, error, notFound
    }

    public var status: Status
    public var offset: UInt32
    public var data: Data

    public init(status: Status, offset: UInt32, data: Data) {
        self.status = status
        self.offset = offset
        self.data = data
    }

    /// Nil when the body is shorter than the 5-byte header (a truncated chunk).
    public static func parse(_ frame: Frame) -> FileChunk? {
        guard frame.cmd == Command.fileData.rawValue else { return nil }
        let b = [UInt8](frame.body)
        guard b.count >= 5 else { return nil }
        let status: Status = switch b[0] & 0xF0 {
        case 0x20: .eof
        case 0x30: .cancelled
        case 0x40: .error
        case 0xF0: .notFound
        default: .data
        }
        let offset = UInt32(b[1]) << 24 | UInt32(b[2]) << 16 | UInt32(b[3]) << 8 | UInt32(b[4])
        return FileChunk(status: status, offset: offset, data: Data(b[5...]))
    }
}
