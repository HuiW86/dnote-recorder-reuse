import AVFoundation
import Foundation
import Testing
import CardTestSupport
@testable import CardProtocol

// T-M1-04: OGG muxing is byte-identical to Python and decodable by the system player.
struct OggOpusTests {
    @Test func matchesPython() throws {
        let frames = OggOpus.splitFrames(try fixture("plain.bin"))
        #expect(frames.count == 123)  // 7-byte remainder dropped
        #expect(OggOpus.wrap(frames) == (try fixture("expected_ogg.bin")))
    }

    @Test func splitHandlesShortAndSlicedInput() {
        #expect(OggOpus.splitFrames(Data(count: 39)).isEmpty)
        let sliced = Data(count: 100).dropFirst(10)  // non-zero startIndex
        #expect(OggOpus.splitFrames(sliced).map(\.count) == [40, 40])
    }

    /// The fixture frames are random bytes, so real Opus packets are made with the system
    /// encoder (16 kHz mono, 20 ms, like the card) and the muxed file is opened with
    /// AVAudioPlayer. No audio is committed to the repo.
    @Test func systemPlayerReadsDuration() throws {
        let packets = try SyntheticOpus.sine(seconds: 2)
        #expect(packets.count >= 99, "packets \(packets.count)")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).ogg")
        defer { try? FileManager.default.removeItem(at: url) }
        try OggOpus.wrap(packets).write(to: url)
        let player = try AVAudioPlayer(contentsOf: url)
        // 20 ms per packet, minus the 312-sample pre-skip at 48 kHz.
        let expected = Double(packets.count) * 0.02 - 312.0 / 48000
        #expect(abs(player.duration - expected) < 0.002, "duration \(player.duration), expected \(expected)")
    }
}
