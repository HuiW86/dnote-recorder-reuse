#if canImport(PDFKit)
import AppModel
import Foundation
import Library
import PDFKit
import Testing

// J1: summary and transcript as a PDF, same content as the Markdown file.
struct PDFExportTests {
    private func sample(lines: Int) throws -> (Recording, Summary, Transcript, Calendar) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Asia/Shanghai"))
        let start = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 7, hour: 14, minute: 2)))
        let id = UUID()
        let recording = Recording(id: id, deviceId: nil, source: .card, cardFileName: "a.opus", cardFileSize: 1,
                                  startedAt: start, durationMs: 125_000, audioPath: "a", audioSha256: "",
                                  title: "2026-11-07 14:02", createdAt: start, updatedAt: start)
        let summary = Summary(recordingId: id, scene: "meeting", title: "定发布日", summary: "周三发布。",
                              sections: [SummarySection(heading: "结论与决定", items: ["下周三发布"])],
                              todos: [SummaryTodo(text: "发通知", done: true)], tags: ["发布"], people: ["李工"],
                              outline: [OutlineItem(title: "排期", points: ["周三发布"])], quotes: ["那就下周三。"],
                              model: "m", createdAt: start)
        let segments = (0..<lines).map { TranscriptSegment(startMs: $0 * 65_000, text: "第\($0 + 1)句，那就下周三。") }
        let transcript = Transcript(recordingId: id, engine: "on-device", language: "zh-CN", segments: segments,
                                    createdAt: start)
        return (recording, summary, transcript, calendar)
    }

    @Test func containsTheSummaryAndTheTranscriptWithTimes() throws {
        let (recording, summary, transcript, calendar) = try sample(lines: 2)
        let data = PDFExport.pdf(title: "11月7日 14:02", recording: recording, sceneName: "会议", summary: summary,
                                 transcript: transcript, calendar: calendar)
        let document = try #require(PDFDocument(data: data))
        #expect(document.pageCount == 1)
        let page = try #require(document.page(at: 0))
        #expect(page.bounds(for: .mediaBox).size == PDFExport.pageSize)
        let text = try #require(document.string)
        for expected in ["定发布日", "11月7日 14:02", "会议", "李工", "周三发布。", "结论与决定", "下周三发布",
                         "待办", "发通知", "大纲", "排期", "金句", "文字稿", "00:01:05", "第2句"] {
            #expect(text.contains(expected), "missing \(expected)")
        }
        #expect(document.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String == "定发布日")
    }

    /// A long transcript goes on over several A4 pages, and nothing is lost at a page break.
    @Test func longTranscriptBreaksIntoPages() throws {
        let (recording, _, transcript, calendar) = try sample(lines: 300)
        let data = PDFExport.pdf(title: "长录音", recording: recording, sceneName: nil, summary: nil,
                                 transcript: transcript, calendar: calendar)
        let document = try #require(PDFDocument(data: data))
        #expect(document.pageCount > 1)
        let text = try #require(document.string)
        #expect(text.contains("长录音") && text.contains("第1句") && text.contains("第300句"))
    }
}
#endif
