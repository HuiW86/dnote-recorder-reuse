import CardLink
import CardProtocol

/// App error codes for device operations (prd.md §6).
public enum CardServiceError: Error, Equatable, Sendable {
    case bluetoothOff
    case bluetoothUnauthorized
    /// Bluetooth LE unavailable on this device, or still resetting.
    case bluetoothUnsupported
    case connectTimeout
    case connectFailed
    /// The peripheral id is not known to the system (never seen, or Bluetooth was reset).
    case unknownCard
    /// The link dropped during the operation, or there was no link.
    case disconnected
    case requestTimeout(Command)
    /// `0x51` replied `NULL`, or `0x90` got no reply (prd.md §2.3).
    case notPaired
    /// `0xA0`/`0xA1` disagree after a bond or unbond write.
    case pairVerifyFailed
    /// The card is bonded to another device and the user declined to re-bind.
    case pairCancelled
    /// The card is recording, so it lists no files (#5).
    case cardBusyRecording
    /// `0x70` replied `0xF0`.
    case fileNotFound
    /// `0x70` replied `0x30`/`0x40`, a chunk was malformed or out of order, or the length is off.
    case transferFailed
    /// A reply the protocol does not allow, or a setting that did not read back.
    case unexpectedReply(Command)
    case invalidArgument(String)
    /// Keychain read or write of the bondId failed.
    case bondStorageFailed

    /// Maps transport and protocol errors to app error codes.
    static func from(_ error: Error) -> CardServiceError {
        switch error {
        case let e as CardServiceError: e
        case let e as LinkError:
            switch e {
            case .bluetoothOff: .bluetoothOff
            case .bluetoothUnauthorized: .bluetoothUnauthorized
            case .bluetoothUnsupported: .bluetoothUnsupported
            case .connectTimeout: .connectTimeout
            case .connectFailed: .connectFailed
            case .unknownPeripheral: .unknownCard
            case .notConnected, .writeFailed: .disconnected
            }
        case let e as ProtocolError:
            switch e {
            case .payloadTooLong(let n): .invalidArgument("payload \(n) bytes")
            case .invalidArgument(let s), .settingOutOfRange(let s): .invalidArgument(s)
            }
        default: .disconnected
        }
    }
}
