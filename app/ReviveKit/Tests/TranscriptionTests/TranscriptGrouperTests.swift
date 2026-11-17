import Library
import Testing
@testable import Transcription

// X9: recognizer output becomes sentences that know where they start.
struct TranscriptGrouperTests {
    private func pieces(_ items: [(String, Int)], each: Int = 300) -> [SpokenPiece] {
        items.map { SpokenPiece(text: $0.0, startMs: $0.1, durationMs: each) }
    }

    @Test func splitsAtSentenceEnds() {
        let out = TranscriptGrouper.group(pieces([("那", 0), ("就", 300), ("下周三。", 600), ("好", 1000), ("的", 1300)]))
        #expect(out == [TranscriptSegment(startMs: 0, text: "那就下周三。"), TranscriptSegment(startMs: 1000, text: "好的")])
    }

    @Test func splitsAtLongPauses() {
        let out = TranscriptGrouper.group(pieces([("第一句", 0), ("第二句", 5000)]))
        #expect(out.map(\.startMs) == [0, 5000])
        #expect(out.map(\.text) == ["第一句", "第二句"])
    }

    @Test func splitsLongRunsWithoutPunctuation() {
        let run = (0..<50).map { (String(repeating: "字", count: 3), $0 * 300) }
        let out = TranscriptGrouper.group(pieces(run), maxCharacters: 60)
        #expect(out.count == 3)
        #expect(out.allSatisfy { $0.text.count <= 60 })
        #expect(out.map(\.text).joined().count == 150)  // nothing lost
    }

    @Test func joinsLatinWordsWithSpacesOnly() {
        let out = TranscriptGrouper.group(pieces([("see", 0), ("you", 300), ("周三", 600), ("at", 900), ("9", 1200)]))
        #expect(out.map(\.text) == ["see you周三at 9"])
    }

    @Test func emptyInputGivesNothing() {
        #expect(TranscriptGrouper.group([]).isEmpty)
        #expect(TranscriptGrouper.group(pieces([("", 0), ("  ", 300)])).isEmpty)
    }
}
