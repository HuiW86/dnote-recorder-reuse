import AppModel
import Foundation
import Testing

// #75: the AI service's Markdown, tidied before the system parser reads it.
struct RichTextTests {
    @Test func tidiesBoldAndHeadings() {
        #expect(RichText.normalized("** 重点 **后面") == "**重点**后面")
        #expect(RichText.normalized("## 小标题\n正文") == "**小标题**\n正文")
        #expect(RichText.normalized("#话题不是标题") == "#话题不是标题")
        #expect(RichText.normalized("单个 ** 星号") == "单个  星号")
        #expect(RichText.normalized("- 列表 **一** 和 **二**") == "- 列表 **一** 和 **二**")
        #expect(RichText.normalized("空的 **  ** 粗体") == "空的  粗体")
    }

    @Test func rendersBoldWithoutTheMarkers() {
        let text = RichText.attributed("前面 ** 重点 **后面\n## 标题")
        let plain = String(text.characters)
        #expect(plain == "前面 重点后面\n标题")
        let bold = text.runs.filter { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true }
        #expect(bold.map { String(text[$0.range].characters) } == ["重点", "标题"])
    }
}
