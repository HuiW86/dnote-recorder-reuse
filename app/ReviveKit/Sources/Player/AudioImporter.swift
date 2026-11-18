// Importing an audio file from elsewhere (features.md E2): Files, a share from another app.
// The library keeps two formats: OGG Opus as the card makes it, and AAC `.m4a`. Anything else
// the system can read is converted to `.m4a` here, so playback, export and transcription only
// ever see those two.

import AVFoundation
import Foundation

public enum AudioImporter {
    public enum ImportError: Error, Equatable, Sendable {
        /// Not audio the system can read (or an OGG that is not Opus).
        case unsupported
    }

    /// A temporary file ready for `RecordingLibrary.addLocalRecording`, and its length.
    public struct Prepared: Sendable {
        public let file: URL
        public let durationMs: Int
    }

    /// Reads `source` (which the caller may only access for now) and writes a library-ready copy
    /// into the temporary directory. Runs off the main actor; a long file takes a while.
    public static func prepare(_ source: URL) async throws -> Prepared {
        try await Task.detached(priority: .userInitiated) { try prepareNow(source) }.value
    }

    static func prepareNow(_ source: URL) throws -> Prepared {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("import-\(UUID().uuidString)",
                                                                                 isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let ext = source.pathExtension.lowercased()

        if ext == "ogg" || ext == "opus" {
            let data = try Data(contentsOf: source)
            guard let (_, packets) = try? OggOpusDecoder.demux(data), !packets.isEmpty else {
                throw ImportError.unsupported
            }
            let target = dir.appendingPathComponent("import.ogg")
            try data.write(to: target)
            // Opus packets of 20 ms are the common case; an estimate is enough for the list.
            return Prepared(file: target, durationMs: packets.count * 20)
        }

        let input: AVAudioFile
        do { input = try AVAudioFile(forReading: source) } catch { throw ImportError.unsupported }
        let format = input.processingFormat
        let durationMs = Int((Double(input.length) / format.sampleRate * 1000).rounded())
        let target = dir.appendingPathComponent("import.m4a")
        if ext == "m4a" {
            try FileManager.default.copyItem(at: source, to: target)
            return Prepared(file: target, durationMs: durationMs)
        }
        // Scoped so the output is finished before it is handed on.
        do {
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: format.sampleRate,
                AVNumberOfChannelsKey: Int(format.channelCount),
            ]
            let output = try AVAudioFile(forWriting: target, settings: settings, commonFormat: format.commonFormat,
                                         interleaved: format.isInterleaved)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16384) else {
                throw ImportError.unsupported
            }
            while input.framePosition < input.length {
                try input.read(into: buffer)
                if buffer.frameLength == 0 { break }
                try output.write(from: buffer)
            }
        }
        return Prepared(file: target, durationMs: durationMs)
    }
}
