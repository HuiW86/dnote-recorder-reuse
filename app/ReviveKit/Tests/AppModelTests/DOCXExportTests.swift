import AppModel
import Foundation
import Library
import Testing

// J1: summary and transcript as a Word document, in a stored ZIP package.
struct DOCXExportTests {
    /// Entries of a ZIP whose entries are all stored, read through the local headers, after
    /// checking the end record points at a central directory with the same count.
    private func entries(_ zip: Data) throws -> [String: Data] {
        let bytes = [UInt8](zip)
        func u16(_ i: Int) -> Int { Int(bytes[i]) | Int(bytes[i + 1]) << 8 }
        func u32(_ i: Int) -> Int { u16(i) | u16(i + 2) << 16 }
        let end = bytes.count - 22
        #expect(u32(end) == 0x0605_4B50)
        let count = u16(end + 10)
        #expect(u32(u32(end + 16)) == 0x0201_4B50)
        var result: [String: Data] = [:]
        var at = 0
        for _ in 0..<count {
            #expect(u32(at) == 0x0403_4B50)
            #expect(u16(at + 8) == 0)  // stored
            let size = u32(at + 18), nameLength = u16(at + 26), extra = u16(at + 28)
            let name = String(decoding: bytes[(at + 30)..<(at + 30 + nameLength)], as: UTF8.self)
            let start = at + 30 + nameLength + extra
            let data = Data(bytes[start..<(start + size)])
            #expect(UInt32(u32(at + 14)) == ZipArchive.crc32(data), "crc of \(name)")
            result[name] = data
            at = start + size
        }
        return result
    }

    @Test func crcMatchesTheStandardCheckValue() {
        #expect(ZipArchive.crc32(Data("123456789".utf8)) == 0xCBF4_3926)
        #expect(ZipArchive.crc32(Data()) == 0)
    }

    @Test func packageHoldsTheDocumentWithTheSummaryAndTranscript() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Asia/Shanghai"))
        let start = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 7, hour: 14, minute: 2)))
        let id = UUID()
        let recording = Recording(id: id, deviceId: nil, source: .card, cardFileName: "a.opus", cardFileSize: 1,
                                  startedAt: start, durationMs: 125_000, audioPath: "a", audioSha256: "",
                                  title: "2026-11-07 14:02", createdAt: start, updatedAt: start)
        let summary = Summary(recordingId: id, scene: "meeting", title: "定发布日 & 分工", summary: "周三发布。\n再确认一次。",
                              sections: [SummarySection(heading: "结论与决定", items: ["下周三 <发布>"])],
                              todos: [SummaryTodo(text: "发通知", done: true)], tags: ["发布"], people: ["李工"],
                              outline: [OutlineItem(title: "排期", points: ["周三"])], quotes: ["那就下周三。"],
                              model: "m", createdAt: start)
        let transcript = Transcript(recordingId: id, engine: "t", language: "zh-CN",
                                    segments: [TranscriptSegment(startMs: 65_000, text: "好的\u{0007}")], createdAt: start)
        let data = DOCXExport.docx(title: "11月7日 14:02", recording: recording, sceneName: "会议", summary: summary,
                                   transcript: transcript, calendar: calendar)
        let files = try entries(data)
        #expect(Set(files.keys) == ["[Content_Types].xml", "_rels/.rels", "word/document.xml"])
        let document = String(decoding: try #require(files["word/document.xml"]), as: UTF8.self)
        for expected in ["定发布日 &amp; 分工", "11月7日 14:02 · 2 分钟 · 会议", "人物：李工", "周三发布。</w:t><w:br/>",
                         "结论与决定", "• 下周三 &lt;发布&gt;", "☑ 发通知", "1. 排期", "「那就下周三。」", "文字稿",
                         "00:01:05", "好的</w:t>", #"<w:pgSz w:w="11906" w:h="16838"/>"#] {
            #expect(document.contains(expected), "missing \(expected)")
        }
        #expect(!document.contains("\u{0007}"))
        let types = String(decoding: try #require(files["[Content_Types].xml"]), as: UTF8.self)
        #expect(types.contains("wordprocessingml.document.main+xml"))

        #if os(macOS) || os(iOS)
        for name in files.keys {
            #expect(XMLParser(data: try #require(files[name])).parse(), "\(name) is well-formed")
        }
        #endif
    }
}
