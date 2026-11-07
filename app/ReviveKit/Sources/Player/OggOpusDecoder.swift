// Fallback for systems whose AVAudioPlayer cannot open OGG Opus directly (only iOS 27 and
// macOS 27 are verified to). Demuxes the Ogg pages and decodes the Opus packets with the
// system decoder (AVAudioConverter), as in evidence/v7-ios/opuscheck.swift, into a PCM CAF.

import AVFoundation
import Foundation

enum OggOpusDecoder {
    enum DecodeError: Error {
        case notOggOpus
        case decoderUnavailable
    }

    /// Opus always counts granule and pre-skip at 48 kHz (RFC 7845 §4.2).
    private static let granuleRate = 48000.0

    /// Decodes `source` into a 16-bit PCM CAF at `target`, written atomically.
    static func decode(_ source: URL, to target: URL) throws {
        let (head, packets) = try demux(Data(contentsOf: source))
        // Opus decodes only at these rates; the header's input rate is informational (RFC 7845 §5.1).
        let rate = [8000, 12000, 16000, 24000, 48000].contains(head.inputRate) ? Double(head.inputRate) : granuleRate
        // Card audio is 20 ms per packet; a constant packet length is required here.
        var asbd = AudioStreamBasicDescription(
            mSampleRate: rate, mFormatID: kAudioFormatOpus, mFormatFlags: 0, mBytesPerPacket: 0,
            mFramesPerPacket: UInt32(rate / 50), mBytesPerFrame: 0, mChannelsPerFrame: UInt32(head.channels),
            mBitsPerChannel: 0, mReserved: 0)
        guard let inFormat = AVAudioFormat(streamDescription: &asbd),
              let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate,
                                            channels: AVAudioChannelCount(head.channels), interleaved: false)
        else { throw DecodeError.decoderUnavailable }

        // The system decoder already drops part of the stream start on its own (40 samples at
        // 16 kHz on macOS 27), and that may differ by OS version. Measure it on the first few
        // packets so pre-skip is not applied twice.
        let probe = Array(packets.prefix(10))
        var probed = 0
        try convert(probe, from: inFormat, to: outFormat) { probed += Int($0.frameLength) }
        let decoderTrim = max(0, probe.count * Int(rate / 50) - probed)
        var toSkip = max(0, Int((Double(head.preSkip) * rate / granuleRate).rounded()) - decoderTrim)

        // Unique per call: two plays of the same recording may decode at the same time.
        let partial = target.deletingLastPathComponent()
            .appendingPathComponent("\(UUID().uuidString).part")
        defer { try? FileManager.default.removeItem(at: partial) }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate,
            AVNumberOfChannelsKey: Int(head.channels), AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
        ]
        // Scoped so the file is closed before the move.
        do {
            let file = try AVAudioFile(forWriting: partial, settings: settings, commonFormat: .pcmFormatFloat32,
                                       interleaved: false)
            try convert(packets, from: inFormat, to: outFormat) { try write($0, to: file, skipping: &toSkip) }
        }
        // rename(2) replaces any existing copy in one step, so a concurrent decode of the same
        // recording cannot slip in between a remove and a move.
        guard rename(partial.path, target.path) == 0 else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: target.path])
        }
    }

    /// Runs `packets` through a fresh converter, handing each decoded buffer to `sink`.
    private static func convert(_ packets: [Data], from inFormat: AVAudioFormat, to outFormat: AVAudioFormat,
                                sink: (AVAudioPCMBuffer) throws -> Void) throws {
        guard let converter = AVAudioConverter(from: inFormat, to: outFormat) else {
            throw DecodeError.decoderUnavailable
        }
        var next = 0
        while true {
            guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: AVAudioFrameCount(outFormat.sampleRate))
            else { throw DecodeError.decoderUnavailable }
            var error: NSError?
            let status = converter.convert(to: out, error: &error) { _, inStatus in
                guard next < packets.count else { inStatus.pointee = .endOfStream; return nil }
                let packet = packets[next]
                next += 1
                let buffer = AVAudioCompressedBuffer(format: inFormat, packetCapacity: 1,
                                                     maximumPacketSize: packet.count)
                packet.withUnsafeBytes { buffer.data.copyMemory(from: $0.baseAddress!, byteCount: packet.count) }
                buffer.packetDescriptions![0] = AudioStreamPacketDescription(
                    mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: UInt32(packet.count))
                buffer.packetCount = 1
                buffer.byteLength = UInt32(packet.count)
                inStatus.pointee = .haveData
                return buffer
            }
            if let error { throw error }
            if status == .error { throw DecodeError.decoderUnavailable }
            try sink(out)
            if status == .endOfStream || out.frameLength == 0 { break }
        }
    }

    /// Drops the encoder's pre-skip from the start of the stream, then writes the rest.
    private static func write(_ buffer: AVAudioPCMBuffer, to file: AVAudioFile, skipping toSkip: inout Int) throws {
        let length = Int(buffer.frameLength)
        let drop = min(toSkip, length)
        toSkip -= drop
        guard drop < length else { return }
        if drop > 0, let channels = buffer.floatChannelData {
            for c in 0..<Int(buffer.format.channelCount) {
                channels[c].update(from: channels[c] + drop, count: length - drop)
            }
            buffer.frameLength = AVAudioFrameCount(length - drop)
        }
        try file.write(from: buffer)
    }

    struct Head: Equatable {
        var channels: UInt8
        var preSkip: UInt16
        var inputRate: UInt32
    }

    /// Splits an Ogg stream into packets and parses OpusHead; OpusTags is dropped.
    static func demux(_ data: Data) throws -> (Head, [Data]) {
        let b = [UInt8](data)
        var packets: [Data] = []
        var current: [UInt8] = []
        var i = 0
        while i + 27 <= b.count {
            guard b[i..<i + 4].elementsEqual("OggS".utf8) else { throw DecodeError.notOggOpus }
            let segments = Int(b[i + 26])
            var p = i + 27 + segments
            guard p <= b.count else { throw DecodeError.notOggOpus }
            for lacing in b[i + 27..<i + 27 + segments] {
                guard p + Int(lacing) <= b.count else { throw DecodeError.notOggOpus }
                current += b[p..<p + Int(lacing)]
                p += Int(lacing)
                // A lacing value of 255 means the packet continues in the next segment.
                // Zero-length packets (allowed by Opus for lost frames) are dropped; the decoder
                // cannot take an empty buffer.
                if lacing < 255 {
                    if !current.isEmpty { packets.append(Data(current)) }
                    current = []
                }
            }
            i = p
        }
        guard packets.count >= 2 else { throw DecodeError.notOggOpus }
        let h = [UInt8](packets[0])
        guard h.count >= 19, h[0..<8].elementsEqual("OpusHead".utf8), h[9] >= 1 else { throw DecodeError.notOggOpus }
        let head = Head(channels: h[9],
                        preSkip: UInt16(h[10]) | UInt16(h[11]) << 8,
                        inputRate: UInt32(h[12]) | UInt32(h[13]) << 8 | UInt32(h[14]) << 16 | UInt32(h[15]) << 24)
        guard head.inputRate > 0 else { throw DecodeError.notOggOpus }
        return (head, Array(packets.dropFirst(2)))
    }
}
