import Foundation

// Port of split_opus_frames (client/dnote_protocol.py) and wrap_opus_frames_as_ogg
// (client/ogg_opus.py). Output must be byte-identical to the Python reference.

public enum OggOpus {
    /// Card audio is fixed 40-byte Opus frames (16 kHz mono, 20 ms). A trailing remainder is dropped.
    public static func splitFrames(_ buf: Data, frameLength: Int = 40) -> [Data] {
        guard buf.count >= frameLength else { return [] }
        return stride(from: buf.startIndex, through: buf.endIndex - frameLength, by: frameLength).map {
            buf.subdata(in: $0..<$0 + frameLength)
        }
    }

    public static func wrap(_ frames: [Data], serial: UInt32 = 1, preSkip: UInt16 = 312,
                            granulePerFrame: Int64 = 960, packetsPerPage: Int = 50) -> Data {
        var head = [UInt8]("OpusHead".utf8) + [1, 1]
        head.appendLE(preSkip); head.appendLE(UInt32(16000)); head.appendLE(Int16(0)); head.append(0)
        let vendor = [UInt8]("dnote-client".utf8)
        var tags = [UInt8]("OpusTags".utf8)
        tags.appendLE(UInt32(vendor.count)); tags += vendor; tags.appendLE(UInt32(0))

        var out = page(serial: serial, seq: 0, granule: 0, segments: [Data(head)], headerType: 0x02)
        out += page(serial: serial, seq: 1, granule: 0, segments: [Data(tags)], headerType: 0x00)
        var seq: UInt32 = 2, granule: Int64 = 0
        for i in stride(from: 0, to: frames.count, by: packetsPerPage) {
            let chunk = Array(frames[i..<min(i + packetsPerPage, frames.count)])
            granule += granulePerFrame * Int64(chunk.count)
            let isLast = i + packetsPerPage >= frames.count
            out += page(serial: serial, seq: seq, granule: granule, segments: chunk, headerType: isLast ? 0x04 : 0x00)
            seq += 1
        }
        return Data(out)
    }

    private static func page(serial: UInt32, seq: UInt32, granule: Int64, segments: [Data], headerType: UInt8) -> [UInt8] {
        var lacing = [UInt8](), body = [UInt8]()
        for seg in segments {
            var n = seg.count
            while n >= 255 { lacing.append(255); n -= 255 }
            lacing.append(UInt8(n))
            body += seg
        }
        var page = [UInt8]("OggS".utf8) + [0, headerType]
        page.appendLE(granule); page.appendLE(serial); page.appendLE(seq); page.appendLE(UInt32(0))
        page.append(UInt8(lacing.count))
        page += lacing + body
        let crc = crc32(page)
        page.replaceSubrange(22..<26, with: withUnsafeBytes(of: crc.littleEndian, Array.init))
        return page
    }

    private static let crcTable: [UInt32] = (0..<256).map { i in
        var r = UInt32(i) << 24
        for _ in 0..<8 { r = r & 0x8000_0000 != 0 ? (r << 1) ^ 0x04C1_1DB7 : r << 1 }
        return r
    }

    private static func crc32(_ data: [UInt8]) -> UInt32 {
        data.reduce(UInt32(0)) { crc, b in (crc << 8) ^ crcTable[Int((crc >> 24) ^ UInt32(b)) & 0xFF] }
    }
}

private extension Array where Element == UInt8 {
    mutating func appendLE<T: FixedWidthInteger>(_ v: T) {
        Swift.withUnsafeBytes(of: v.littleEndian) { append(contentsOf: $0) }
    }
}
