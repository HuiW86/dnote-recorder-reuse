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

    /// How often each TOC byte occurs across `frames`.
    public static func counts(in frames: [Data]) -> [UInt8: Int] {
        var counts: [UInt8: Int] = [:]
        for frame in frames {
            if let first = frame.first { counts[first, default: 0] += 1 }
        }
        return counts
    }

    /// One mono 20 ms frame in this packet. Code 0 says so directly; code 3 says so when the
    /// count in the second byte is 1. The card's live stream carries TOC 0x4b, which is code 3
    /// (evidence/v1-live/README.md). Port of `opus_frame_is_card_format` in the Python client.
    public static func isCardFrame(_ frame: Data) -> Bool {
        guard let first = frame.first else { return false }
        let toc = OpusTOC(first)
        guard toc.frameMicroseconds == 20000, !toc.isStereo else { return false }
        switch toc.frameCountCode {
        case 0:
            return true
        case 3:
            guard frame.count >= 2 else { return false }
            return frame[frame.index(after: frame.startIndex)] & 0x3F == 1
        default:
            return false
        }
    }

    /// True when there is at least one frame and every frame holds one mono 20 ms Opus frame.
    /// Headers may differ between frames (an encoder can switch mode); misaligned data fails,
    /// because few byte values pass.
    public static func framesMatchCardFormat(_ frames: [Data]) -> Bool {
        !frames.isEmpty && frames.allSatisfy(isCardFrame)
    }
}
