import AVFoundation
import Foundation
import Testing
@testable import Transcription

struct SpeechRecognitionWindowTests {
    @Test(arguments: [0, 1, 44_999, 45_000, 45_001, 46_000, 90_000, 90_001, 300_000, 1_800_000])
    func ownsTheWholeRecordingWithinTheTaskLimit(durationMs: Int) {
        let windows = SpeechRecognitionWindow.covering(durationMs)
        var next = 0
        for window in windows {
            #expect(window.owned.lowerBound == next)
            #expect(window.input.lowerBound >= 0)
            #expect(window.input.upperBound <= durationMs)
            #expect(window.input.count <= 47_000)
            #expect(window.input.lowerBound <= window.owned.lowerBound)
            #expect(window.owned.upperBound <= window.input.upperBound)
            next = window.owned.upperBound
        }
        #expect(next == durationMs)
    }

    @Test func placesOverlappingWordsOnceAtTheirOriginalTime() throws {
        let windows = SpeechRecognitionWindow.covering(90_000)
        let first = try #require(windows.first)
        let second = try #require(windows.last)
        let a = SpokenPiece(text: "一", startMs: 44_700, durationMs: 400)
        let b = SpokenPiece(text: "二", startMs: 44_900, durationMs: 400)
        let repeated = [a, b].map {
            SpokenPiece(text: $0.text, startMs: $0.startMs - second.input.lowerBound, durationMs: $0.durationMs)
        }
        #expect(first.place([a, b]) == [a])
        #expect(second.place(repeated) == [b])
    }

    @Test func slicesAACIntoTheRequestedPCMFrames() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("speech-test-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("input.m4a")
        let target = dir.appendingPathComponent("window.caf")
        let rate = 16_000.0
        do {
            let audio = try AVAudioFile(forWriting: source, settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: rate, AVNumberOfChannelsKey: 2,
            ])
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: 16_000))
            let channels = try #require(buffer.floatChannelData)
            buffer.frameLength = buffer.frameCapacity
            for channel in 0..<2 {
                channels[channel].initialize(repeating: 0.125, count: Int(buffer.frameLength))
            }
            try audio.write(from: buffer)
        }

        let input = try AVAudioFile(forReading: source)
        try OnDeviceTranscriber.writeWindow(125..<725, from: input, to: target)
        let window = try AVAudioFile(forReading: target)
        #expect(window.fileFormat.streamDescription.pointee.mFormatID == kAudioFormatLinearPCM)
        #expect(window.processingFormat.sampleRate == rate)
        #expect(window.processingFormat.channelCount == 2)
        #expect(window.length == 9_600)
    }
}
