import Foundation
import Library

/// A word or character run as the recognizer reports it, with its place in the audio.
public struct SpokenPiece: Equatable, Sendable {
    public var text: String
    public var startMs: Int
    public var durationMs: Int

    public init(text: String, startMs: Int, durationMs: Int) {
        self.text = text
        self.startMs = startMs
        self.durationMs = durationMs
    }
}

/// Turns the recognizer's word-level output into sentences that each know where they start,
/// so tapping one can play from there.
public enum TranscriptGrouper {
    private static let sentenceEnds: Set<Character> = ["。", "！", "？", "!", "?", ".", "；", ";"]

    /// A sentence ends at end punctuation, at a pause longer than `maxGapMs`, or once it is
    /// `maxCharacters` long. Latin words are joined with spaces; CJK text is joined as it is.
    public static func group(_ pieces: [SpokenPiece], maxCharacters: Int = 60, maxGapMs: Int = 1200) -> [TranscriptSegment] {
        var segments: [TranscriptSegment] = []
        var text = ""
        var start = 0
        var lastEnd: Int?

        func flush() {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { segments.append(TranscriptSegment(startMs: start, text: trimmed)) }
            text = ""
        }

        for piece in pieces where !piece.text.isEmpty {
            if let lastEnd, !text.isEmpty, piece.startMs - lastEnd > maxGapMs { flush() }
            if text.isEmpty {
                start = max(0, piece.startMs)
            } else if needsSpace(between: text, and: piece.text) {
                text += " "
            }
            text += piece.text
            lastEnd = piece.startMs + piece.durationMs
            if let last = piece.text.last, sentenceEnds.contains(last) || text.count >= maxCharacters { flush() }
        }
        flush()
        return segments
    }

    /// A space goes between two runs only when both sides are ASCII letters or digits.
    private static func needsSpace(between left: String, and right: String) -> Bool {
        guard let a = left.last, let b = right.first else { return false }
        return a.isASCII && b.isASCII && (a.isLetter || a.isNumber) && (b.isLetter || b.isNumber)
    }
}
