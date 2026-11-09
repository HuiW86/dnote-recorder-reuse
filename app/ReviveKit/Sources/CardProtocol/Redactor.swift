import CryptoKit
import Foundation

/// Frame descriptions that are safe to log or commit as evidence (CLAUDE.md rule 4).
///
/// `sn` becomes the first 8 hex digits of its SHA-256 and `btaddr` keeps its last two
/// bytes; bondIds, the `0xA2` audio key and audio bytes in `0x70` chunks are never shown.
public enum Redactor {
    public enum Direction: String, Sendable {
        /// Phone to card.
        case tx
        /// Card to phone.
        case rx
    }

    public static func serialTag(_ serial: String) -> String {
        SHA256.hash(data: Data(serial.utf8)).prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    /// `btaddr` as 12 hex digits, with or without separators; keeps the last two bytes.
    public static func addressTag(_ address: String) -> String {
        let hex = address.filter(\.isHexDigit)
        return "…" + String(hex.suffix(4))
    }

    /// One frame as `CMD len=N body`. Bytes that are not a frame are shown by length only.
    public static func describe(_ data: Data, _ direction: Direction) -> String {
        guard let frame = Frame.parse(data) else { return "<not a frame, \(data.count) B>" }
        let head = String(format: "%02X len=%d", frame.cmd, frame.body.count)
        return head + " " + body(frame, direction)
    }

    private static func body(_ frame: Frame, _ direction: Direction) -> String {
        let b = [UInt8](frame.body)
        switch (frame.cmd, direction) {
        case (Command.deviceInfo.rawValue, .rx):
            return redactedDeviceInfo(frame.body)
        case (Command.bondStatus.rawValue, .rx), (Command.bond.rawValue, .tx):
            // [flag][bondId(16)?]
            guard let first = b.first else { return "" }
            return hex([first]) + (b.count > 1 ? " <bondId \(b.count - 1) B>" : "")
        case (Command.setEncryptionKey.rawValue, .tx):
            guard let first = b.first else { return "" }
            return hex([first]) + (b.count > 1 ? " <key \(b.count - 1) B>" : "")
        case (Command.fileData.rawValue, .rx):
            // Header only: the rest is (encrypted) audio, which never goes into evidence.
            guard b.count >= 5 else { return "truncated " + hex(b) }
            let offset = Int(b[1]) << 24 | Int(b[2]) << 16 | Int(b[3]) << 8 | Int(b[4])
            return String(format: "status=0x%02X offset=%d data=<%d B>", b[0], offset, b.count - 5)
        default:
            return printable(frame.body) ?? hex(b)
        }
    }

    private static func redactedDeviceInfo(_ body: Data) -> String {
        guard var json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else {
            // Unparsable 0x80 may still carry the serial; show only its size.
            return "<unparsed, \(body.count) B>"
        }
        if let sn = json["sn"] as? String { json["sn"] = "sha256:" + serialTag(sn) }
        if let addr = json["btaddr"] as? String { json["btaddr"] = addressTag(addr) }
        guard let out = try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]) else {
            return "<unparsed, \(body.count) B>"
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// UTF-8 text with no control characters (JSON payloads, `NULL`), else nil.
    private static func printable(_ body: Data) -> String? {
        guard !body.isEmpty, let s = String(data: body, encoding: .utf8),
              s.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7F }) else { return nil }
        return s
    }

    private static func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
    }
}
