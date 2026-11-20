import Foundation

/// A ZIP file with every entry stored as is (no compression), for the DOCX export (features.md
/// J1): Foundation on iOS has no ZIP writer, and a document is small enough not to need
/// deflate. Names are UTF-8 (general purpose flag bit 11); times are 1980-01-01 00:00.
public enum ZipArchive {
    public static func stored(_ entries: [(name: String, data: Data)]) -> Data {
        var out = Data()
        var central = Data()
        for entry in entries {
            let name = Data(entry.name.utf8)
            let crc = crc32(entry.data)
            let size = UInt32(entry.data.count)
            let offset = UInt32(out.count)

            out.le32(0x0403_4B50)  // local file header
            out.le16(20)  // version needed
            out.le16(0x0800)  // UTF-8 names
            out.le16(0)  // stored
            out.le16(0)  // time
            out.le16(0x21)  // date: 1980-01-01
            out.le32(crc)
            out.le32(size)
            out.le32(size)
            out.le16(UInt16(name.count))
            out.le16(0)  // extra
            out.append(name)
            out.append(entry.data)

            central.le32(0x0201_4B50)  // central directory header
            central.le16(20)  // made by
            central.le16(20)  // needed
            central.le16(0x0800)
            central.le16(0)
            central.le16(0)
            central.le16(0x21)
            central.le32(crc)
            central.le32(size)
            central.le32(size)
            central.le16(UInt16(name.count))
            central.le16(0)  // extra
            central.le16(0)  // comment
            central.le16(0)  // disk
            central.le16(0)  // internal attributes
            central.le32(0)  // external attributes
            central.le32(offset)
            central.append(name)
        }
        let centralOffset = UInt32(out.count)
        out.append(central)
        out.le32(0x0605_4B50)  // end of central directory
        out.le16(0)
        out.le16(0)
        out.le16(UInt16(entries.count))
        out.le16(UInt16(entries.count))
        out.le32(UInt32(central.count))
        out.le32(centralOffset)
        out.le16(0)  // comment
        return out
    }

    /// CRC-32 (IEEE 802.3, the one ZIP uses).
    public static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }

    private static let table: [UInt32] = (0..<256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }
}

private extension Data {
    mutating func le16(_ value: UInt16) {
        append(UInt8(value & 0xFF))
        append(UInt8(value >> 8))
    }

    mutating func le32(_ value: UInt32) {
        for shift in stride(from: 0, to: 32, by: 8) { append(UInt8((value >> UInt32(shift)) & 0xFF)) }
    }
}
