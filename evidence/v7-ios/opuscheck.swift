import AVFoundation
// Demux Ogg pages -> opus packets (skip OpusHead/OpusTags), decode via AVAudioConverter.
let data = try! Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
let b = [UInt8](data)
var packets: [[UInt8]] = []; var i = 0; var cur: [UInt8] = []
while i + 27 <= b.count {
  let nseg = Int(b[i+26]); let lac = Array(b[i+27..<i+27+nseg]); var p = i+27+nseg
  for l in lac { cur += b[p..<p+Int(l)]; p += Int(l); if l < 255 { packets.append(cur); cur = [] } }
  i = p
}
packets.removeFirst(2)
print("packets", packets.count, "sizes", Set(packets.map{$0.count}))
for rate in [16000.0, 48000.0] {
  var asbd = AudioStreamBasicDescription(mSampleRate: rate, mFormatID: kAudioFormatOpus, mFormatFlags: 0, mBytesPerPacket: 0, mFramesPerPacket: UInt32(rate/50), mBytesPerFrame: 0, mChannelsPerFrame: 1, mBitsPerChannel: 0, mReserved: 0)
  let inF = AVAudioFormat(streamDescription: &asbd)!
  let outF = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
  guard let conv = AVAudioConverter(from: inF, to: outF) else { print(rate, "no converter"); continue }
  var idx = 0; var total = 0; var peak: Float = 0
  while true {
    let out = AVAudioPCMBuffer(pcmFormat: outF, frameCapacity: 3200)!
    var err: NSError?
    let st = conv.convert(to: out, error: &err) { _, status in
      if idx >= packets.count { status.pointee = .endOfStream; return nil }
      let pk = packets[idx]; idx += 1
      let cb = AVAudioCompressedBuffer(format: inF, packetCapacity: 1, maximumPacketSize: pk.count)
      pk.withUnsafeBytes { cb.data.copyMemory(from: $0.baseAddress!, byteCount: pk.count) }
      cb.packetDescriptions![0] = AudioStreamPacketDescription(mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: UInt32(pk.count))
      cb.packetCount = 1; cb.byteLength = UInt32(pk.count)
      status.pointee = .haveData; return cb
    }
    total += Int(out.frameLength)
    for k in 0..<Int(out.frameLength) { peak = max(peak, abs(out.floatChannelData![0][k])) }
    if st == .endOfStream || st == .error || out.frameLength == 0 { if let err { print("err", err) }; break }
  }
  print("inRate", rate, "decoded frames", total, "sec", Double(total)/16000, "peak", peak)
}
