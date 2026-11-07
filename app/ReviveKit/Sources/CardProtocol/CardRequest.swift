import Foundation

/// M1 settings (PROTOCOL.md §4.1). Switches are single bytes; levels are 1...9.
public enum CardSetting: Equatable, Sendable {
    case led(Bool)
    case motor(Bool)
    case noiseCancel(Bool)
    case vad(Bool)
    case gain(Int)
    case noiseLevel(Int)
    /// Idle power-off delay in seconds, sent as uint32 big-endian.
    case autoOff(seconds: UInt32)

    public static let levelRange = 1...9
}

/// Everything the app can ask the card to do. The only way to build an outgoing frame.
public enum CardRequest: Equatable, Sendable {
    case deviceInfo
    case switches
    case recordingStatus
    case bondStatus
    case encryptionStatus
    case set(CardSetting)
    /// Card clock, formatted in the given time zone (the phone's local time).
    case syncTime(Date, TimeZone)
    case startRecording
    case stopRecording
    case pauseRecording
    case resumeRecording
    case listFiles
    /// Download from `offset` to the end of file; any offset is accepted (#34).
    case download(name: String, offset: Int)
    case delete(name: String)
    case bond(bondId: Data)
    case unbond
    /// `key` is `AudioCrypto.deviceKey(serial:)` of the card.
    case setEncryptionKey(enabled: Bool, key: Data)

    public var command: Command {
        switch self {
        case .deviceInfo: .deviceInfo
        case .switches: .switches
        case .recordingStatus: .recordingStatus
        case .bondStatus: .bondStatus
        case .encryptionStatus: .encryptionStatus
        case .set(let s):
            switch s {
            case .led: .setLED
            case .motor: .setMotor
            case .noiseCancel: .setNoiseCancel
            case .vad: .setVAD
            case .gain: .setGain
            case .noiseLevel: .setNoiseLevel
            case .autoOff: .setAutoOff
            }
        case .syncTime: .syncTime
        case .startRecording: .startRecording
        case .stopRecording: .stopRecording
        case .pauseRecording: .pauseRecording
        case .resumeRecording: .resumeRecording
        case .listFiles: .listFiles
        case .download: .fileData
        case .delete: .deleteFile
        case .bond, .unbond: .bond
        case .setEncryptionKey: .setEncryptionKey
        }
    }

    /// Frame bytes, identical to client/dnote_protocol.py for the same request.
    public func encode() throws -> Data {
        try Frame.encode(command, try payload())
    }

    private func payload() throws -> Data {
        switch self {
        case .deviceInfo, .switches, .recordingStatus, .bondStatus, .encryptionStatus,
             .stopRecording, .pauseRecording, .resumeRecording, .listFiles:
            return Data()
        case .set(let s):
            return try Self.settingPayload(s)
        case .syncTime(let date, let zone):
            return json([("time", .string(Self.timeFormatter(zone).string(from: date)))])
        case .startRecording:
            // [0] = normal recording; [1] (live streaming) is M3.
            return Data([0])
        case .download(let name, let offset):
            guard !name.isEmpty else { throw ProtocolError.invalidArgument("empty file name") }
            guard offset >= 0, offset <= Int(UInt32.max) else {
                throw ProtocolError.invalidArgument("offset \(offset)")
            }
            return json([("cmd", .int(1)), ("name", .string(name)), ("offset", .int(offset))])
        case .delete(let name):
            guard !name.isEmpty else { throw ProtocolError.invalidArgument("empty file name") }
            return json([("name", .string(name))])
        case .bond(let bondId):
            guard bondId.count == 16 else { throw ProtocolError.invalidArgument("bondId must be 16 bytes") }
            return Data([1]) + bondId
        case .unbond:
            return Data([0])
        case .setEncryptionKey(let enabled, let key):
            guard key.count == 32 else { throw ProtocolError.invalidArgument("key must be 32 bytes") }
            return Data([enabled ? 1 : 0]) + key
        }
    }

    private static func settingPayload(_ s: CardSetting) throws -> Data {
        switch s {
        case .led(let on), .motor(let on), .noiseCancel(let on), .vad(let on):
            return Data([on ? 1 : 0])
        case .gain(let level), .noiseLevel(let level):
            guard CardSetting.levelRange.contains(level) else {
                throw ProtocolError.settingOutOfRange("level \(level)")
            }
            return Data([UInt8(level)])
        case .autoOff(let seconds):
            return withUnsafeBytes(of: seconds.bigEndian) { Data($0) }
        }
    }

    private static func timeFormatter(_ zone: TimeZone) -> DateFormatter {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = zone
        f.dateFormat = "yyyyMMddHHmmss"
        return f
    }
}

// MARK: - JSON with fixed key order

/// The Python client emits compact JSON in insertion order; JSONSerialization does not
/// guarantee key order, so payloads are assembled by hand to stay byte-identical.
private enum JSONScalar {
    case string(String)
    case int(Int)
}

private func json(_ fields: [(String, JSONScalar)]) -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.withoutEscapingSlashes]
    func quoted(_ s: String) -> String {
        String(decoding: (try? encoder.encode(s)) ?? Data("\"\"".utf8), as: UTF8.self)
    }
    let body = fields.map { key, value in
        switch value {
        case .string(let s): "\(quoted(key)):\(quoted(s))"
        case .int(let i): "\(quoted(key)):\(i)"
        }
    }.joined(separator: ",")
    return Data("{\(body)}".utf8)
}
