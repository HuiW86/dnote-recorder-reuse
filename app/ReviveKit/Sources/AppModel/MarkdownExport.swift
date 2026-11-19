import Foundation
import Library

/// A recording's summary and transcript as one Markdown file (features.md J1), in the layout
/// beanpod uses for Obsidian: YAML front matter, summary, sections, to-dos, then the transcript
/// with times. Plain text only; nothing leaves the phone until the user shares the file.
public enum MarkdownExport {
    public static func markdown(title: String, recording: Recording, sceneName: String?, summary: Summary?,
                                transcript: Transcript?, calendar: Calendar = .current) -> String {
        var lines = ["---"]
        let day = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: recording.startedAt)
        lines.append(String(format: "date: %04d-%02d-%02d %02d:%02d", day.year ?? 0, day.month ?? 0, day.day ?? 0,
                            day.hour ?? 0, day.minute ?? 0))
        lines.append("duration: \(RecordingText.duration(ms: recording.durationMs))")
        if let sceneName { lines.append("scene: \(sceneName)") }
        if let summary, !summary.tags.isEmpty { lines.append("tags: [\(summary.tags.map(yaml).joined(separator: ", "))]") }
        if let summary, !summary.people.isEmpty {
            lines.append("people: [\(summary.people.map(yaml).joined(separator: ", "))]")
        }
        lines.append("---")
        lines.append("")
        lines.append("# \(summary.map { $0.title.isEmpty ? title : $0.title } ?? title)")
        if let summary {
            lines.append("")
            lines.append(summary.summary)
            for section in summary.sections where !section.items.isEmpty {
                lines.append("")
                lines.append("## \(section.heading)")
                lines.append("")
                lines += section.items.map { "- \($0)" }
            }
            if !summary.todos.isEmpty {
                lines.append("")
                lines.append("## 待办")
                lines.append("")
                lines += summary.todos.map { "- [\($0.done ? "x" : " ")] \($0.text)" }
            }
            if !summary.outline.isEmpty {
                lines.append("")
                lines.append("## 大纲")
                lines.append("")
                for item in summary.outline {
                    lines.append("- \(item.title)")
                    lines += item.points.map { "  - \($0)" }
                }
            }
            if !summary.quotes.isEmpty {
                lines.append("")
                lines.append("## 金句")
                for quote in summary.quotes {
                    lines.append("")
                    lines.append("> \(quote)")
                }
            }
        }
        if let transcript, !transcript.segments.isEmpty {
            lines.append("")
            lines.append("## 文字稿")
            for segment in transcript.segments {
                lines.append("")
                lines.append("**\(RecordingText.clock(seconds: segment.startMs / 1000))** \(segment.text)")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Quoted when the value could break a YAML flow list.
    private static func yaml(_ value: String) -> String {
        let special = CharacterSet(charactersIn: ",[]{}:#\"'")
        guard value.unicodeScalars.contains(where: special.contains) else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
