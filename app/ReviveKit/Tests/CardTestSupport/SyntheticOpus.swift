import AVFoundation
import Foundation

/// Opus test audio. Card fixtures are random bytes; playback and export checks need packets
/// a decoder accepts. No audio is committed to the repo.
public enum SyntheticOpus {
    /// Real Opus packets from the system encoder: a 440 Hz sine, 16 kHz mono, 20 ms per packet.
    public static func sine(seconds: Int) throws -> [Data] {
        let rate = 16000.0
        let pcmFormat = try required(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1,
                                                   interleaved: false))
        var asbd = AudioStreamBasicDescription(
            mSampleRate: rate, mFormatID: kAudioFormatOpus, mFormatFlags: 0, mBytesPerPacket: 0,
            mFramesPerPacket: 320, mBytesPerFrame: 0, mChannelsPerFrame: 1, mBitsPerChannel: 0, mReserved: 0)
        let opusFormat = try required(AVAudioFormat(streamDescription: &asbd))
        let converter = try required(AVAudioConverter(from: pcmFormat, to: opusFormat))

        let frameCount = AVAudioFrameCount(rate) * AVAudioFrameCount(seconds)
        let pcm = try required(AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: frameCount))
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

    private static func required<T>(_ value: T?) throws -> T {
        guard let value else { throw CocoaError(.coderInvalidValue) }
        return value
    }
}
