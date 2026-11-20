import Foundation
import Testing
@testable import Library

/// E2 文字文件: a text file becomes a recording with no audio, its paragraphs the transcript.
struct TextImportTests {
    private func makeLibrary() throws -> (RecordingLibrary, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("text-\(UUID().uuidString)")
        return (RecordingLibrary(database: try AppDatabase.inMemory(), store: try AudioStore(root: root)), root)
    }

    @Test func paragraphsBecomeLinesAndLongOnesAreSplit() {
        let lines = TextImport.segments(from: "第一段。\r\n\r\n  第二段  \n\n").map(\.text)
        #expect(lines == ["第一段。", "第二段"])
        #expect(TextImport.segments(from: " \n\n ").isEmpty)
        #expect(TextImport.segments(from: "一").allSatisfy { $0.startMs == 0 })

        let sentence = String(repeating: "很长的一句话，", count: 8) + "到这里结束。"
        let long = String(repeating: sentence, count: 5)
        let parts = TextImport.segments(from: long).map(\.text)
        #expect(parts.count == 5 && parts.allSatisfy { $0 == sentence })
        let unbroken = TextImport.segments(from: String(repeating: "字", count: 450)).map(\.text.count)
        #expect(unbroken == [200, 200, 50])
    }

    @Test func decodesCommonEncodings() throws {
        #expect(TextImport.decode(Data("你好".utf8)) == "你好")
        #expect(TextImport.decode(Data([0xEF, 0xBB, 0xBF]) + Data("你好".utf8)) == "你好")
        let utf16 = try #require("你好".data(using: .utf16))  // with a byte order mark
        #expect(TextImport.decode(utf16) == "你好")
        #if canImport(Darwin)
        let gb = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        let gbData = try #require("你好，世界".data(using: gb))
        #expect(TextImport.decode(gbData) == "你好，世界")
        #endif
    }

    @Test func textRecordingHasATranscriptAndNoAudio() throws {
        let (lib, root) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(try lib.addTextRecording(text: "  \n", title: "空", startedAt: start) == nil)
        let r = try #require(try lib.addTextRecording(text: "周三发布。\n测试通过以后上线。", title: " 会议记录 ",
                                                      startedAt: start))
        #expect(!r.hasAudio && r.audioPath.isEmpty && r.durationMs == 0 && r.source == .import)
        #expect(r.title == "会议记录")
        let transcript = try #require(try lib.transcript(recordingId: r.id))
        #expect(transcript.segments.map(\.text) == ["周三发布。", "测试通过以后上线。"])
        #expect(transcript.engine == TextImport.engine)
        #expect(try lib.searchRecordings("上线").map(\.id) == [r.id])
    }

    /// An empty audio path names the store itself: deleting a text recording, or removing an
    /// empty path, must leave every other file alone.
    @Test func deletingATextRecordingLeavesTheAudioAlone() throws {
        let (lib, root) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let kept = try lib.store.storeAudio(Data("OggS".utf8), id: UUID())
        let text = try #require(try lib.addTextRecording(text: "一句话", title: "t", startedAt: Date()))
        lib.store.removeAudio("")
        lib.store.removeAudio("audio/")
        lib.store.removeAudio("audio/../audio")
        #expect(FileManager.default.fileExists(atPath: lib.store.url(forAudioPath: kept).path))
        try lib.trashRecording(id: text.id, now: Date(timeIntervalSince1970: 0))
        #expect(try lib.purgeTrash(trashedBefore: Date(timeIntervalSince1970: 1)) == 1)
        #expect(try lib.recording(id: text.id) == nil)
        #expect(FileManager.default.fileExists(atPath: lib.store.url(forAudioPath: kept).path))
    }
}
