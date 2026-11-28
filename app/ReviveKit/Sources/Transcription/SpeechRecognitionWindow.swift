/// The legacy speech recognizer has a one-minute task limit. Each request reads at most
/// 47 seconds including context. Only one window owns each word's midpoint.
struct SpeechRecognitionWindow: Sendable {
    let owned: Range<Int>
    let input: Range<Int>

    static func covering(_ durationMs: Int) -> [Self] {
        stride(from: 0, to: durationMs, by: 45_000).map { start in
            let end = min(start + 45_000, durationMs)
            return Self(owned: start..<end, input: max(0, start - 1_000)..<min(end + 1_000, durationMs))
        }
    }

    func place(_ pieces: [SpokenPiece]) -> [SpokenPiece] {
        pieces.compactMap { piece in
            let start = input.lowerBound + max(0, piece.startMs)
            guard start < input.upperBound else { return nil }
            let duration = min(max(0, piece.durationMs), input.upperBound - start)
            guard owned.contains(start + duration / 2) else { return nil }
            return SpokenPiece(text: piece.text, startMs: start, durationMs: duration)
        }
    }
}
