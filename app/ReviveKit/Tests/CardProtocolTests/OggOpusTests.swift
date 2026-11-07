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
        let packets = try encodeSineAsOpus(seconds: 2)
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

private func encodeSineAsOpus(seconds: Int) throws -> [Data] {
    let rate = 16000.0
    let pcmFormat = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1,
                                               interleaved: false))
    var asbd = AudioStreamBasicDescription(
        mSampleRate: rate, mFormatID: kAudioFormatOpus, mFormatFlags: 0, mBytesPerPacket: 0,
        mFramesPerPacket: 320, mBytesPerFrame: 0, mChannelsPerFrame: 1, mBitsPerChannel: 0, mReserved: 0)
    let opusFormat = try #require(AVAudioFormat(streamDescription: &asbd))
    let converter = try #require(AVAudioConverter(from: pcmFormat, to: opusFormat))

    let frameCount = AVAudioFrameCount(rate) * AVAudioFrameCount(seconds)
    let pcm = try #require(AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: frameCount))
    pcm.frameLength = frameCount
    for i in 0..<Int(frameCount) {
        pcm.floatChannelData![0][i] = 0.3 * sin(2 * .pi * 440 * Float(i) / Float(rate))
    }

    var packets: [Data] = []
    var fed = false
    while true {
        let out = AVAudioCompressedBuffer(format: opusFormat, packetCapacity: 64, maximumPacketSize: 1500)
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, inStatus in
            if fed { inStatus.pointee = .endOfStream; return nil }
            fed = true
            inStatus.pointee = .haveData
            return pcm
        }
        if let error { throw error }
        for i in 0..<Int(out.packetCount) {
            let d = out.packetDescriptions![i]
            packets.append(Data(bytes: out.data + Int(d.mStartOffset), count: Int(d.mDataByteSize)))
        }
        if status == .endOfStream || status == .error || out.packetCount == 0 { break }
    }
    return packets
}
