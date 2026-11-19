import Foundation

/// Text from the user's AI service shown with its Markdown (features.md X15, G3; #75 "显示模型输出的
/// Markdown"). Models often write bold that the system parser leaves as literal asterisks
/// ("** 重点 **", "**重点**后面"), and headings the inline parser does not read; both are
/// tidied first. Anything that still does not parse is shown as it came.
public enum RichText {
    public static func attributed(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: normalized(text), options: options)) ?? AttributedString(text)
    }

    /// Headings become bold lines; spaces just inside `**…**` are dropped; an unpaired `**` on a
    /// line is removed.
    public static func normalized(_ text: String) -> String {
        text.components(separatedBy: "\n").map(line).joined(separator: "\n")
    }

    private static func line(_ raw: String) -> String {
        var line = raw
        if let heading = line.range(of: #"^\s{0,3}#{1,6}\s+"#, options: .regularExpression) {
            let rest = line[heading.upperBound...].trimmingCharacters(in: .whitespaces)
            line = rest.isEmpty ? "" : "**\(rest)**"
        }
        let parts = line.components(separatedBy: "**")
        // An even number of markers: tidy each bold run. An odd number: drop the markers.
        guard parts.count > 1 else { return line }
        guard parts.count % 2 == 1 else { return parts.joined() }
        return parts.enumerated().map { index, part in
            guard index % 2 == 1 else { return part }
            let inner = part.trimmingCharacters(in: .whitespaces)
            return inner.isEmpty ? "" : "**\(inner)**"
        }.joined()
    }
}
