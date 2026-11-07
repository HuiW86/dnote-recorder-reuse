import Foundation

// Frame codec, ported from client/dnote_protocol.py (PROTOCOL.md §3).
// Frame: [PID=0xA0][CMD][LEN][PAYLOAD...], no checksum.

/// GATT and advertisement identifiers (PROTOCOL.md §2). Strings so this module stays
/// free of CoreBluetooth; CardLink turns them into CBUUIDs.
public enum CardGATT {
    public static let service = "00006001-0000-1000-8000-00805f9b34fb"
    public static let writeCharacteristic = "00006002-0000-1000-8000-00805f9b34fb"
    public static let notifyCharacteristic = "00006003-0000-1000-8000-00805f9b34fb"
    public static let companyId: UInt16 = 0x22A3
}

public enum ProtocolError: Error, Equatable, Sendable {
    case payloadTooLong(Int)
    case invalidArgument(String)
    case settingOutOfRange(String)
}

/// A frame received from the card. `cmd` stays a raw byte because the card also
/// pushes frames the app never sends (see `DevicePush`).
public struct Frame: Equatable, Sendable {
    public static let pid: UInt8 = 0xA0

    public let cmd: UInt8
    public let body: Data

    public init(cmd: UInt8, body: Data) {
        self.cmd = cmd
        self.body = Data(body)
    }

    /// Whitelisted command this frame answers, if any.
    public var command: Command? { Command(rawValue: cmd) }
    public var push: DevicePush? { DevicePush(rawValue: cmd) }
    public var text: String { String(decoding: body, as: UTF8.self) }

    /// Decodes the payload as UTF-8 JSON.
    public func decode<T: Decodable>(_ type: T.Type) -> T? {
        try? JSONDecoder().decode(type, from: body)
    }

    /// Parses a notification. Returns nil for a wrong PID or a length field larger
    /// than the data; bytes after the declared length are ignored, as in the Python client.
    public static func parse(_ data: Data) -> Frame? {
        let b = [UInt8](data)
        guard b.count >= 3, b[0] == pid, b.count >= 3 + Int(b[2]) else { return nil }
        return Frame(cmd: b[1], body: Data(b[3..<3 + Int(b[2])]))
    }

    /// Encodes an outgoing frame. Internal: callers go through `CardRequest`, which
    /// only accepts whitelisted commands.
    static func encode(_ command: Command, _ payload: Data = Data()) throws -> Data {
        guard payload.count <= 255 else { throw ProtocolError.payloadTooLong(payload.count) }
        return Data([pid, command.rawValue, UInt8(payload.count)]) + payload
    }
}
