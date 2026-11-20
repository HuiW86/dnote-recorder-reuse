#if canImport(CoreText)
import CoreGraphics
import CoreText
import Foundation
import Library

/// A recording's summary and transcript as a PDF (features.md J1), for people who print or
/// send a document rather than a Markdown file. Same content and order as `MarkdownExport`:
/// title, date and length, summary, sections, to-dos, outline, quotes, then the transcript with
/// times. A4, laid out with Core Text; made on the phone, nothing is sent anywhere.
public enum PDFExport {
    /// A4 in points.
    public static let pageSize = CGSize(width: 595, height: 842)
    static let margin: CGFloat = 50

    public static func pdf(title: String, recording: Recording, sceneName: String?, summary: Summary?,
                           transcript: Transcript?, calendar: Calendar = .current) -> Data {
        let heading = summary.map { $0.title.isEmpty ? title : $0.title } ?? title
        let text = NSMutableAttributedString()
        text.append(paragraph(heading, .title))

        var meta = [RecordingText.dateTime(recording.startedAt, calendar: calendar),
                    RecordingText.duration(ms: recording.durationMs)]
        if let sceneName { meta.append(sceneName) }
        text.append(paragraph(meta.joined(separator: " · "), .muted))
        if let summary {
            var who: [String] = []
            if !summary.people.isEmpty { who.append("人物：" + summary.people.joined(separator: "、")) }
            if !summary.tags.isEmpty { who.append("标签：" + summary.tags.joined(separator: "、")) }
            if !who.isEmpty { text.append(paragraph(who.joined(separator: "　"), .muted)) }

            text.append(paragraph(summary.summary, .body))
            for section in summary.sections where !section.items.isEmpty {
                text.append(paragraph(section.heading, .heading))
                for item in section.items { text.append(paragraph("• " + item, .body)) }
            }
            if !summary.todos.isEmpty {
                text.append(paragraph("待办", .heading))
                for todo in summary.todos { text.append(paragraph((todo.done ? "☑ " : "☐ ") + todo.text, .body)) }
            }
            if !summary.outline.isEmpty {
                text.append(paragraph("大纲", .heading))
                for (i, item) in summary.outline.enumerated() {
                    text.append(paragraph("\(i + 1). \(item.title)", .body))
                    for point in item.points { text.append(paragraph("    – " + point, .body)) }
                }
            }
            if !summary.quotes.isEmpty {
                text.append(paragraph("金句", .heading))
                for quote in summary.quotes { text.append(paragraph("「\(quote)」", .body)) }
            }
        }
        if let transcript, !transcript.segments.isEmpty {
            text.append(paragraph("文字稿", .heading))
            for segment in transcript.segments {
                let line = NSMutableAttributedString(
                    attributedString: run(RecordingText.clock(seconds: segment.startMs / 1000) + "  ", .muted))
                line.append(run(segment.text + "\n", .body))
                line.addAttributes(paragraphAttributes(.body), range: NSRange(location: 0, length: line.length))
                text.append(line)
            }
        }
        return render(text, title: heading)
    }

    /// Pages `text` onto A4 until all of it is drawn.
    static func render(_ text: NSAttributedString, title: String) -> Data {
        let data = NSMutableData()
        var box = CGRect(origin: .zero, size: pageSize)
        let info: [CFString: Any] = [kCGPDFContextTitle: title, kCGPDFContextCreator: "闻笺"]
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &box, info as CFDictionary) else { return Data() }
        let framesetter = CTFramesetterCreateWithAttributedString(text as CFAttributedString)
        let frameRect = box.insetBy(dx: margin, dy: margin)
        var position = 0
        repeat {
            context.beginPDFPage(nil)
            let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: position, length: 0),
                                                 CGPath(rect: frameRect, transform: nil), nil)
            CTFrameDraw(frame, context)
            context.endPDFPage()
            let shown = CTFrameGetVisibleStringRange(frame).length
            // A line taller than a page would never fit; stop rather than loop.
            guard shown > 0 else { break }
            position += shown
        } while position < text.length
        context.closePDF()
        return data as Data
    }

    // MARK: Styles

    enum Style: Equatable {
        case title, heading, body, muted
    }

    /// A whole paragraph in one style.
    private static func paragraph(_ string: String, _ style: Style) -> NSAttributedString {
        NSAttributedString(string: string + "\n",
                           attributes: fontAttributes(style).merging(paragraphAttributes(style)) { a, _ in a })
    }

    /// Part of a paragraph; the caller sets the paragraph style over the whole line.
    private static func run(_ string: String, _ style: Style) -> NSAttributedString {
        NSAttributedString(string: string, attributes: fontAttributes(style))
    }

    private static func fontAttributes(_ style: Style) -> [NSAttributedString.Key: Any] {
        let (size, emphasized, gray): (CGFloat, Bool, CGFloat) = switch style {
        case .title: (20, true, 0.1)
        case .heading: (14, true, 0.1)
        case .body: (11, false, 0.1)
        case .muted: (10, false, 0.45)
        }
        let font = CTFontCreateUIFontForLanguage(emphasized ? .emphasizedSystem : .system, size, "zh-Hans" as CFString)
            ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
        return [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: gray, alpha: 1),
        ]
    }

    private static func paragraphAttributes(_ style: Style) -> [NSAttributedString.Key: Any] {
        var before: CGFloat = style == .heading ? 12 : 0
        var after: CGFloat = 4
        var lineSpacing: CGFloat = 2
        let size = MemoryLayout<CGFloat>.size
        let paragraphStyle = withUnsafeBytes(of: &before) { b in
            withUnsafeBytes(of: &after) { a in
                withUnsafeBytes(of: &lineSpacing) { l in
                    let settings = [
                        CTParagraphStyleSetting(spec: .paragraphSpacingBefore, valueSize: size, value: b.baseAddress!),
                        CTParagraphStyleSetting(spec: .paragraphSpacing, valueSize: size, value: a.baseAddress!),
                        CTParagraphStyleSetting(spec: .lineSpacingAdjustment, valueSize: size, value: l.baseAddress!),
                    ]
                    return CTParagraphStyleCreate(settings, settings.count)
                }
            }
        }
        return [NSAttributedString.Key(kCTParagraphStyleAttributeName as String): paragraphStyle]
    }
}
#endif
