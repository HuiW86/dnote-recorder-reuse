import AppModel
import Foundation
import Library
import Testing

// J1: summary and transcript as one Markdown file.
struct MarkdownExportTests {
    @Test func layoutFollowsFrontMatterSummaryTodosTranscript() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Asia/Shanghai"))
        let start = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 7, hour: 14, minute: 2)))
        let id = UUID()
        let recording = Recording(id: id, deviceId: nil, source: .card, cardFileName: "a.opus", cardFileSize: 1,
                                  startedAt: start, durationMs: 125_000, audioPath: "a", audioSha256: "",
                                  title: "2026-11-07 14:02", createdAt: start, updatedAt: start)
        let summary = Summary(recordingId: id, scene: "meeting", title: "定发布日", summary: "周三发布。",
                              sections: [SummarySection(heading: "结论与决定", items: ["下周三发布"]),
                                         SummarySection(heading: "空栏", items: [])],
                              todos: [SummaryTodo(text: "发通知", done: true), SummaryTodo(text: "排查汇款率", done: false)],
                              tags: ["发布", "a,b"], people: ["李工"], model: "m", createdAt: start)
        let transcript = Transcript(recordingId: id, engine: "on-device", language: "zh-CN",
                                    segments: [TranscriptSegment(startMs: 0, text: "那就下周三。"),
                                               TranscriptSegment(startMs: 65_000, text: "好的")],
                                    createdAt: start)
        let md = MarkdownExport.markdown(title: "11月7日 14:02", recording: recording, sceneName: "会议",
                                         summary: summary, transcript: transcript, calendar: calendar)
        #expect(md.hasPrefix("---\ndate: 2026-11-07 14:02\n"))
        #expect(md.contains("scene: 会议\ntags: [发布, \"a,b\"]\npeople: [李工]\n---\n\n# 定发布日\n\n周三发布。\n"))
        #expect(md.contains("## 结论与决定\n\n- 下周三发布\n"))
        #expect(!md.contains("空栏"))
        #expect(md.contains("## 待办\n\n- [x] 发通知\n- [ ] 排查汇款率\n"))
        #expect(md.contains("## 文字稿\n\n**00:00:00** 那就下周三。\n\n**00:01:05** 好的\n"))

        let bare = MarkdownExport.markdown(title: "11月7日 14:02", recording: recording, sceneName: nil,
                                           summary: nil, transcript: transcript, calendar: calendar)
        #expect(bare.contains("# 11月7日 14:02\n\n## 文字稿"))
        #expect(!bare.contains("scene:"))
    }
}
