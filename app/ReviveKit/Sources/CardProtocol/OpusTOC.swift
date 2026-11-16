import Foundation

/// The first byte of an Opus packet (TOC, RFC 6716 §3.1). Port of `opus_toc` in
/// client/dnote_protocol.py.
///
/// The card's audio is cut into fixed 40-byte frames on the assumption that each is one
/// mono 20 ms packet. That was verified on firmware v1.50 only, so the header is read to
/// find out when a file does not fit the assumption (#66).
public struct OpusTOC: Equatable, Sendable {
    public enum Mode: String, Sendable { case silk = "SILK", hybrid = "Hybrid", celt = "CELT" }

    public let byte: UInt8
    public let mode: Mode
    /// Duration of one frame in microseconds: 2500, 5000, 10000, 20000, 40000 or 60000.
    public let frameMicroseconds: Int
    public let isStereo: Bool
    /// 0: one frame in the packet. 1 and 2: two. 3: the count is in the packet's second byte.
    public let frameCountCode: Int

    public init(_ byte: UInt8) {
        self.byte = byte
        let config = Int(byte >> 3)
        if config < 12 {
            mode = .silk
            frameMicroseconds = [10000, 20000, 40000, 60000][config % 4]
        } else if config < 16 {
            mode = .hybrid
            frameMicroseconds = [10000, 20000][config % 2]
        } else {
            mode = .celt
            frameMicroseconds = [2500, 5000, 10000, 20000][config % 4]
        }
        isStereo = byte & 0x04 != 0
        frameCountCode = Int(byte & 0x03)
    }

    /// One mono 20 ms frame per packet: what `OggOpus.splitFrames` and `OggOpus.wrap` assume.
    public var isCardFormat: Bool {
        frameMicroseconds == 20000 && frameCountCode == 0 && !isStereo
    }

    /// How often each TOC byte occurs across `frames`.
    public static func counts(in frames: [Data]) -> [UInt8: Int] {
        var counts: [UInt8: Int] = [:]
        for frame in frames {
            if let first = frame.first { counts[first, default: 0] += 1 }
        }
        return counts
    }

    /// True when there is at least one frame and every frame's header says one mono 20 ms
    /// frame per packet. The bytes may differ between frames (an encoder can switch mode);
    /// misaligned data fails, because about 1 byte value in 28 passes.
    public static func framesMatchCardFormat(_ frames: [Data]) -> Bool {
        let seen = Self.counts(in: frames)
        return !seen.isEmpty && seen.keys.allSatisfy { OpusTOC($0).isCardFormat }
    }
}
