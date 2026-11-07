import Foundation

/// Manufacturer data in the card's advertisement (PROTOCOL.md §2.2).
public struct Advertisement: Equatable, Sendable {
    /// `major.minor`, same form as the `v` field of `0x80` (e.g. "1.50").
    public var firmware: String
    public var hardware: String
    public var battery: Int
    /// 0 unknown / 1 battery only / 2 charging only / 3 discharging only / 4 pass-through.
    public var powerState: Int
    /// 24-bit device id.
    public var sid: Int

    /// Parses CoreBluetooth manufacturer data: company ID little-endian, then the body.
    /// Returns nil for other vendors or short data.
    public init?(manufacturerData md: Data) {
        let b = [UInt8](md)
        guard b.count >= 15, UInt16(b[0]) | UInt16(b[1]) << 8 == CardGATT.companyId else { return nil }
        // Offsets follow PROTOCOL.md §2.2 (which counts the 2-byte CID).
        firmware = "\(b[6]).\(b[7])"
        hardware = "\(b[8]).\(b[9])"
        battery = Int(b[10])
        powerState = Int(b[11])
        sid = Int(b[12]) << 16 | Int(b[13]) << 8 | Int(b[14])
    }
}
