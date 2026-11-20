import Foundation
import Library

/// A recording's summary and transcript as a Word document (features.md J1), for people who
/// keep editing it in Word, Pages or WPS. Same content and order as `PDFExport`. The smallest
/// valid package: content types, the package relationship and `word/document.xml`, with direct
/// formatting instead of a styles part. A4. Made on the phone; nothing is sent anywhere.
public enum DOCXExport {
    public static func docx(title: String, recording: Recording, sceneName: String?, summary: Summary?,
                            transcript: Transcript?, calendar: Calendar = .current) -> Data {
        ZipArchive.stored([
            ("[Content_Types].xml", Data(contentTypes.utf8)),
            ("_rels/.rels", Data(relationships.utf8)),
            ("word/document.xml", Data(document(title: title, recording: recording, sceneName: sceneName,
                                                summary: summary, transcript: transcript,
                                                calendar: calendar).utf8)),
        ])
    }

    /// `word/document.xml`: one paragraph per line of the PDF layout.
    public static func document(title: String, recording: Recording, sceneName: String?, summary: Summary?,
                                transcript: Transcript?, calendar: Calendar = .current) -> String {
        var body: [String] = []
        let heading = summary.map { $0.title.isEmpty ? title : $0.title } ?? title
        body.append(paragraph(heading, .title))
        var meta = [RecordingText.dateTime(recording.startedAt, calendar: calendar),
                    RecordingText.duration(ms: recording.durationMs)]
        if let sceneName { meta.append(sceneName) }
        body.append(paragraph(meta.joined(separator: " · "), .muted))
        if let summary {
            var who: [String] = []
            if !summary.people.isEmpty { who.append("人物：" + summary.people.joined(separator: "、")) }
            if !summary.tags.isEmpty { who.append("标签：" + summary.tags.joined(separator: "、")) }
            if !who.isEmpty { body.append(paragraph(who.joined(separator: "　"), .muted)) }
            body.append(paragraph(summary.summary, .body))
            for section in summary.sections where !section.items.isEmpty {
                body.append(paragraph(section.heading, .heading))
                body += section.items.map { paragraph("• " + $0, .body) }
            }
            if !summary.todos.isEmpty {
                body.append(paragraph("待办", .heading))
                body += summary.todos.map { paragraph(($0.done ? "☑ " : "☐ ") + $0.text, .body) }
            }
            if !summary.outline.isEmpty {
                body.append(paragraph("大纲", .heading))
                for (i, item) in summary.outline.enumerated() {
                    body.append(paragraph("\(i + 1). \(item.title)", .body))
                    body += item.points.map { paragraph("    – " + $0, .body) }
                }
            }
            if !summary.quotes.isEmpty {
                body.append(paragraph("金句", .heading))
                body += summary.quotes.map { paragraph("「\($0)」", .body) }
            }
        }
        if let transcript, !transcript.segments.isEmpty {
            body.append(paragraph("文字稿", .heading))
            for segment in transcript.segments {
                let time = run(RecordingText.clock(seconds: segment.startMs / 1000) + "  ", .muted)
                body.append("<w:p>\(spacing(.body))\(time)\(run(segment.text, .body))</w:p>")
            }
        }
        // A4 with 2 cm margins (twentieths of a point).
        let parts: [String] = [
            #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?>"#,
            "\n",
            #"<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body>"#,
            body.joined(),
            #"<w:sectPr><w:pgSz w:w="11906" w:h="16838"/>"#,
            #"<w:pgMar w:top="1134" w:right="1134" w:bottom="1134" w:left="1134" w:header="567" w:footer="567" w:gutter="0"/>"#,
            "</w:sectPr></w:body></w:document>",
        ]
        return parts.joined()
    }

    static let contentTypes: String = [
        #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?>"#,
        "\n",
        #"<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">"#,
        #"<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>"#,
        #"<Default Extension="xml" ContentType="application/xml"/>"#,
        #"<Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>"#,
        "</Types>",
    ].joined()

    static let relationships: String = [
        #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?>"#,
        "\n",
        #"<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">"#,
        #"<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>"#,
        "</Relationships>",
    ].joined()

    // MARK: Paragraphs

    enum Style {
        case title, heading, body, muted
    }

    private static func paragraph(_ text: String, _ style: Style) -> String {
        "<w:p>\(spacing(style))\(run(text, style))</w:p>"
    }

    private static func spacing(_ style: Style) -> String {
        let before = style == .heading ? 240 : 0
        return #"<w:pPr><w:spacing w:before="\#(before)" w:after="80"/></w:pPr>"#
    }

    /// One run; line breaks inside the text become `<w:br/>`.
    private static func run(_ text: String, _ style: Style) -> String {
        let (halfPoints, bold, color): (Int, Bool, String) = switch style {
        case .title: (40, true, "1A1A1A")
        case .heading: (28, true, "1A1A1A")
        case .body: (22, false, "1A1A1A")
        case .muted: (20, false, "737373")
        }
        let boldTag = bold ? "<w:b/>" : ""
        let properties = #"<w:rPr>\#(boldTag)<w:color w:val="\#(color)"/><w:sz w:val="\#(halfPoints)"/><w:szCs w:val="\#(halfPoints)"/></w:rPr>"#
        let lines: [String] = text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { #"<w:t xml:space="preserve">\#(escape(String($0)))</w:t>"# }
        let joined = lines.joined(separator: "<w:br/>")
        return "<w:r>\(properties)\(joined)</w:r>"
    }

    /// XML text: markup characters escaped, control characters other than tab dropped.
    static func escape(_ text: String) -> String {
        var out = ""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            default:
                if scalar.value < 0x20, scalar != "\t" { continue }
                out.unicodeScalars.append(scalar)
            }
        }
        return out
    }
}
