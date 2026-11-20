import Foundation

/// Turning an imported text file into transcript lines (features.md E2). A text-only recording
/// has no audio, so every line starts at 0 and the page shows no times.
public enum TextImport {
    /// `Transcript.engine` of an imported text.
    public static let engine = "text"
    /// Longer paragraphs are split at sentence ends, so 「修改这一句」 and 「解释这一句」 work on
    /// sentences rather than pages.
    public static let maxLine = 200

    /// Paragraphs with their blank lines and surrounding spaces removed; long ones split after
    /// 。！？.!? (or hard at `maxLine` when a sentence is longer still).
    public static func segments(from text: String) -> [TranscriptSegment] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var lines: [String] = []
        for paragraph in normalized.split(separator: "\n") {
            let trimmed = paragraph.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            lines += split(trimmed)
        }
        return lines.map { TranscriptSegment(startMs: 0, text: $0) }
    }

    private static func split(_ paragraph: String) -> [String] {
        guard paragraph.count > maxLine else { return [paragraph] }
        var out: [String] = []
        var current = ""
        for character in paragraph {
            current.append(character)
            let atEnd = "。！？!?".contains(character) || (character == "." && current.count > 1)
            if (atEnd && current.count >= 20) || current.count >= maxLine {
                let piece = current.trimmingCharacters(in: .whitespaces)
                if !piece.isEmpty { out.append(piece) }
                current = ""
            }
        }
        let rest = current.trimmingCharacters(in: .whitespaces)
        if !rest.isEmpty { out.append(rest) }
        return out
    }

    /// The text of a file's bytes: UTF-8 (with or without a byte order mark), UTF-16 with a byte
    /// order mark, or GB 18030 (older Chinese files); nil when none of them reads it.
    public static func decode(_ data: Data) -> String? {
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
            return String(data: data, encoding: .utf16)
        }
        if let utf8 = String(data: data, encoding: .utf8) {
            return utf8.hasPrefix("\u{FEFF}") ? String(utf8.dropFirst()) : utf8
        }
        #if canImport(Darwin)
        let gb18030 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        return String(data: data, encoding: gb18030)
        #else
        return nil
        #endif
    }
}
