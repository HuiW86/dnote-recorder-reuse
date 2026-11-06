import AVFoundation
import CryptoKit
import Foundation

// Port of decrypt_audio_file / split_opus_frames (dnote_protocol.py) and
// wrap_opus_frames_as_ogg (ogg_opus.py). Output must be byte-identical to Python.

enum AudioCodecError: Error {
    case tooShort, notEncrypted, verificationMismatch, decoder(String)
}

let deviceKeySecret = Data([
    58, 127, 209, 158, 82, 196, 139, 6, 175, 45, 232, 116, 25, 92, 179, 240,
    110, 161, 71, 220, 131, 47, 149, 107, 12, 212, 231, 56, 242, 26, 142, 89,
])

func isEncryptedAudio(_ buf: Data) -> Bool {
    buf.count >= 6 && buf.prefix(6) == Data("encryt".utf8)
}

/// Layout: [0:24] header (magic + 18B key material), [24:36] nonce, [36:] ciphertext.
/// The first 24 plaintext bytes must equal the header.
func decryptAudioFile(_ buf: Data) throws -> Data {
    let b = [UInt8](buf)
    guard b.count >= 60 else { throw AudioCodecError.tooShort }
    guard isEncryptedAudio(buf) else { throw AudioCodecError.notEncrypted }
    let mac = HMAC<SHA256>.authenticationCode(for: Data(b[6..<24]), using: SymmetricKey(data: deviceKeySecret))
    let plain = chacha20(key: [UInt8](Data(mac)), nonce: Array(b[24..<36]), data: Array(b[36...]))
    guard Array(plain[0..<24]) == Array(b[0..<24]) else { throw AudioCodecError.verificationMismatch }
    return Data(plain[24...])
}

/// Raw ChaCha20 (RFC 8439), 12-byte nonce, initial counter 0. CryptoKit only exposes the AEAD.
func chacha20(key: [UInt8], nonce: [UInt8], data: [UInt8], counter: UInt32 = 0) -> [UInt8] {
    func word(_ p: [UInt8], _ i: Int) -> UInt32 {
        UInt32(p[i]) | UInt32(p[i + 1]) << 8 | UInt32(p[i + 2]) << 16 | UInt32(p[i + 3]) << 24
    }
    var state = [UInt32](repeating: 0, count: 16)
    state[0] = 0x6170_7865; state[1] = 0x3320_646e; state[2] = 0x7962_2d32; state[3] = 0x6b20_6574
    for i in 0..<8 { state[4 + i] = word(key, i * 4) }
    for i in 0..<3 { state[13 + i] = word(nonce, i * 4) }
    state[12] = counter

    var out = data
    var x = [UInt32](repeating: 0, count: 16)
    var off = 0
    while off < out.count {
        x = state
        @inline(__always) func qr(_ a: Int, _ b: Int, _ c: Int, _ d: Int) {
            x[a] &+= x[b]; x[d] ^= x[a]; x[d] = x[d] << 16 | x[d] >> 16
            x[c] &+= x[d]; x[b] ^= x[c]; x[b] = x[b] << 12 | x[b] >> 20
            x[a] &+= x[b]; x[d] ^= x[a]; x[d] = x[d] << 8 | x[d] >> 24
            x[c] &+= x[d]; x[b] ^= x[c]; x[b] = x[b] << 7 | x[b] >> 25
        }
        for _ in 0..<10 {
            qr(0, 4, 8, 12); qr(1, 5, 9, 13); qr(2, 6, 10, 14); qr(3, 7, 11, 15)
            qr(0, 5, 10, 15); qr(1, 6, 11, 12); qr(2, 7, 8, 13); qr(3, 4, 9, 14)
        }
        for i in 0..<16 {
            let k = x[i] &+ state[i]
            for j in 0..<4 where off + i * 4 + j < out.count {
                out[off + i * 4 + j] ^= UInt8(truncatingIfNeeded: k >> (8 * UInt32(j)))
            }
        }
        state[12] &+= 1
        off += 64
    }
    return out
}

/// Device audio is fixed 40-byte Opus frames (16 kHz mono, 20 ms). Trailing remainder is dropped.
func splitOpusFrames(_ buf: Data, frameLen: Int = 40) -> [Data] {
    stride(from: buf.startIndex, through: buf.endIndex - frameLen, by: frameLen).map {
        buf.subdata(in: $0..<$0 + frameLen)
    }
}

// MARK: - Ogg Opus muxer

private let oggCRCTable: [UInt32] = (0..<256).map { i in
    var r = UInt32(i) << 24
    for _ in 0..<8 { r = r & 0x8000_0000 != 0 ? (r << 1) ^ 0x04C1_1DB7 : r << 1 }
    return r
}

private func oggCRC(_ data: [UInt8]) -> UInt32 {
    data.reduce(UInt32(0)) { crc, b in (crc << 8) ^ oggCRCTable[Int((crc >> 24) ^ UInt32(b)) & 0xFF] }
}

private extension Array where Element == UInt8 {
    mutating func appendLE<T: FixedWidthInteger>(_ v: T) {
        Swift.withUnsafeBytes(of: v.littleEndian) { append(contentsOf: $0) }
    }
}

private func oggPage(serial: UInt32, seq: UInt32, granule: Int64, segments: [Data], headerType: UInt8) -> [UInt8] {
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
    let crc = oggCRC(page)
    page.replaceSubrange(22..<26, with: withUnsafeBytes(of: crc.littleEndian, Array.init))
    return page
}

func wrapOpusFramesAsOgg(_ frames: [Data], serial: UInt32 = 1, preSkip: UInt16 = 312,
                         granulePerFrame: Int64 = 960, packetsPerPage: Int = 50) -> Data {
    var head = [UInt8]("OpusHead".utf8) + [1, 1]
    head.appendLE(preSkip); head.appendLE(UInt32(16000)); head.appendLE(Int16(0)); head.append(0)
    let vendor = [UInt8]("dnote-client".utf8)
    var tags = [UInt8]("OpusTags".utf8)
    tags.appendLE(UInt32(vendor.count)); tags += vendor; tags.appendLE(UInt32(0))

    var out = oggPage(serial: serial, seq: 0, granule: 0, segments: [Data(head)], headerType: 0x02)
    out += oggPage(serial: serial, seq: 1, granule: 0, segments: [Data(tags)], headerType: 0x00)
    var seq: UInt32 = 2, granule: Int64 = 0
    for i in stride(from: 0, to: frames.count, by: packetsPerPage) {
        let chunk = Array(frames[i..<Swift.min(i + packetsPerPage, frames.count)])
        granule += granulePerFrame * Int64(chunk.count)
        let isLast = i + packetsPerPage >= frames.count
        out += oggPage(serial: serial, seq: seq, granule: granule, segments: chunk, headerType: isLast ? 0x04 : 0x00)
        seq += 1
    }
    return Data(out)
}

// MARK: - Opus -> WAV (AudioToolbox decoder; verified on real card frames on macOS)

func decodeOpusToWav(_ frames: [Data], sampleRate: Double = 16000) throws -> Data {
    var asbd = AudioStreamBasicDescription(
        mSampleRate: sampleRate, mFormatID: kAudioFormatOpus, mFormatFlags: 0, mBytesPerPacket: 0,
        mFramesPerPacket: UInt32(sampleRate / 50), mBytesPerFrame: 0, mChannelsPerFrame: 1,
        mBitsPerChannel: 0, mReserved: 0)
    guard let inFormat = AVAudioFormat(streamDescription: &asbd),
          let outFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: sampleRate, channels: 1, interleaved: true),
          let converter = AVAudioConverter(from: inFormat, to: outFormat)
    else { throw AudioCodecError.decoder("no Opus converter") }

    var pcm = Data()
    var index = 0
    while true {
        let buffer = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: 16000)!
        var error: NSError?
        let status = converter.convert(to: buffer, error: &error) { _, inStatus in
            guard index < frames.count else { inStatus.pointee = .endOfStream; return nil }
            let packet = frames[index]; index += 1
            let cb = AVAudioCompressedBuffer(format: inFormat, packetCapacity: 1, maximumPacketSize: packet.count)
            packet.withUnsafeBytes { cb.data.copyMemory(from: $0.baseAddress!, byteCount: packet.count) }
            cb.packetDescriptions![0] = AudioStreamPacketDescription(
                mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: UInt32(packet.count))
            cb.packetCount = 1
            cb.byteLength = UInt32(packet.count)
            inStatus.pointee = .haveData
            return cb
        }
        if let error { throw AudioCodecError.decoder(error.localizedDescription) }
        pcm.append(Data(bytes: buffer.int16ChannelData![0], count: Int(buffer.frameLength) * 2))
        if status == .endOfStream || status == .error || buffer.frameLength == 0 { break }
    }

    var header = [UInt8]("RIFF".utf8)
    header.appendLE(UInt32(36 + pcm.count))
    header += [UInt8]("WAVEfmt ".utf8)
    header.appendLE(UInt32(16)); header.appendLE(UInt16(1)); header.appendLE(UInt16(1))
    header.appendLE(UInt32(sampleRate)); header.appendLE(UInt32(sampleRate * 2))
    header.appendLE(UInt16(2)); header.appendLE(UInt16(16))
    header += [UInt8]("data".utf8)
    header.appendLE(UInt32(pcm.count))
    return Data(header) + pcm
}
