import Foundation
import Testing
import CardTestSupport
@testable import CardProtocol

// #66: read the Opus frame header instead of taking 20 ms mono for granted.
// The same cases as client/tests/test_opus_toc.py.
struct OpusTOCTests {
    @Test func decodesFields() {
        let cases: [(UInt8, OpusTOC.Mode, Int, Bool, Int)] = [
            (0x48, .silk, 20000, false, 0),
            (0x08, .silk, 20000, false, 0),
            (0x58, .silk, 60000, false, 0),
            (0x68, .hybrid, 20000, false, 0),
            (0x78, .hybrid, 20000, false, 0),
            (0x80, .celt, 2500, false, 0),
            (0xB8, .celt, 20000, false, 0),
            (0xFC, .celt, 20000, true, 0),
            (0x4B, .silk, 20000, false, 3),
        ]
        for (byte, mode, micros, stereo, code) in cases {
            let toc = OpusTOC(byte)
            #expect(toc.mode == mode, "byte \(byte)")
            #expect(toc.frameMicroseconds == micros, "byte \(byte)")
            #expect(toc.isStereo == stereo, "byte \(byte)")
            #expect(toc.frameCountCode == code, "byte \(byte)")
        }
    }

    @Test func everyConfigDecodes() {
        let durations = Set((0..<32).map { OpusTOC(UInt8($0) << 3).frameMicroseconds })
        #expect(durations == [2500, 5000, 10000, 20000, 40000, 60000])
    }

    private func frame(_ toc: UInt8) -> Data {
        var data = Data(count: 40)
        data[0] = toc
        return data
    }

    @Test func countsFirstBytes() {
        #expect(OpusTOC.counts(in: [frame(0x48), frame(0x48), frame(0x58)]) == [0x48: 2, 0x58: 1])
        #expect(OpusTOC.counts(in: []).isEmpty)
        let sliced = Data([0, 0, 0x48, 1]).dropFirst(2)  // non-zero startIndex
        #expect(OpusTOC.counts(in: [sliced]) == [0x48: 1])
    }

    @Test func acceptsMono20msFrames() {
        #expect(OpusTOC.framesMatchCardFormat(Array(repeating: frame(0x48), count: 5)))
        #expect(OpusTOC.framesMatchCardFormat([frame(0x48), frame(0xB8)]))  // mode switch, still 20 ms
    }

    @Test func rejectsOtherFormats() {
        #expect(!OpusTOC.framesMatchCardFormat([]))
        #expect(!OpusTOC.framesMatchCardFormat([frame(0x48), frame(0x58)]))  // a 60 ms frame
        #expect(!OpusTOC.framesMatchCardFormat([frame(0x4C)]))  // stereo
        #expect(!OpusTOC.framesMatchCardFormat([frame(0x49)]))  // two frames per packet
    }

    /// The random fixture stands in for misaligned or undecrypted data.
    @Test func randomBytesDoNotPass() throws {
        let frames = OggOpus.splitFrames(try fixture("plain.bin"))
        #expect(!OpusTOC.framesMatchCardFormat(frames))
    }

    /// Packets from the system encoder at the card's settings (16 kHz mono, 20 ms) pass.
    @Test func systemEncoderPacketsPass() throws {
        let packets = try SyntheticOpus.sine(seconds: 1)
        #expect(OpusTOC.framesMatchCardFormat(packets), "headers \(OpusTOC.counts(in: packets))")
    }
}
