import AppModel
import Foundation
import Library
import Testing

// J1 思维导图: the outline as OPML that other outliners import.
struct MindMapExportTests {
    @Test func outlineBecomesNestedOutlines() throws {
        let opml = MindMapExport.opml(title: "定发布日 & 分工",
                                      outline: [OutlineItem(title: "排期", points: ["周三 \"上线\"", "<测试>"]),
                                                OutlineItem(title: "风险", points: [])])
        let head: String = #"<?xml version="1.0" encoding="UTF-8"?>"# + "\n" + #"<opml version="2.0">"#
        #expect(opml.hasPrefix(head))
        #expect(opml.contains("<head><title>定发布日 &amp; 分工</title></head>"))
        #expect(opml.contains(#"    <outline text="定发布日 &amp; 分工">"#))
        let topic: String = [
            #"      <outline text="排期">"#,
            #"        <outline text="周三 &quot;上线&quot;"/>"#,
            #"        <outline text="&lt;测试&gt;"/>"#,
            "      </outline>",
        ].joined(separator: "\n")
        #expect(opml.contains(topic))
        #expect(opml.contains(#"      <outline text="风险"/>"#))
        #expect(opml.hasSuffix("</opml>\n"))

        #if os(macOS) || os(iOS)
        // Well-formed: an XML parser reads it to the end.
        let parser = XMLParser(data: Data(opml.utf8))
        #expect(parser.parse())
        #endif
    }
}
