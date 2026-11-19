import AppModel
import CardProtocol
import CardService
import CardTestSupport
import Foundation
import Testing

// Diagnostic log exported from P09 (product-spec.md §4.2, §8): what it records, that it
// never holds a serial or bond id in clear (hard rule 4), and that it stays bounded.

@MainActor
struct DiagnosticLogTests {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("diag-\(UUID().uuidString)/diagnostics.log")
    }

    @Test func keepsNewestLinesWithinLimit() throws {
        let log = DiagnosticLog(fileURL: tempURL(), maxBytes: 2_000)
        for i in 0..<200 { log.add("test", "line \(i)") }
        let text = try #require(log.contents())
        #expect(text.utf8.count <= 2_000)
        #expect(text.hasSuffix("line 199\n"))
        #expect(!text.contains("line 0\n"))
        // Cut at a line start: every line is whole.
        #expect(text.split(separator: "\n").allSatisfy { $0.contains("[test] line ") })
    }

    @Test func emptyUntilWritten() {
        #expect(DiagnosticLog(fileURL: tempURL()).contents() == nil)
    }

    /// Pairing, the first sync and a failed command, logged without the serial or bond id.
    @Test func sessionLogsRedactedEvents() async throws {
        let log = DiagnosticLog(fileURL: tempURL())
        let card = FakeCard(files: [.init(name: "20261101090000.opus", content: Data(repeating: 0x08, count: 400))])
        let h = try Harness(card: card, bonds: InMemoryBondStore([card.serial: card.bondId!]), diagnostics: log)
        try await h.scanAndSelect()
        await waitUntil("paired") { h.isDone }
        await h.firstSyncDone()
        await waitUntil("synced") { (try? h.library.recordings().count) == 1 }
        let model = HomeModel(session: h.session, preferences: h.preferences)
        model.start()
        await h.session.syncEngine.idle()
        h.preferences.recordingConsentGiven = true
        h.shortenRequestTimeouts()
        h.card.faults = [.noResponse(.startRecording)]
        model.startTapped()
        await waitUntil("toast") { model.toast != nil }

        let text = try #require(log.contents())
        #expect(text.contains("[pair] already paired"))
        #expect(text.contains("[card] paired card on the link: sn \(Redactor.serialTag(card.serial))"))
        #expect(text.contains("[sync] idle after"))
        #expect(text.contains("timed out, reading 0x56"))
        #expect(text.contains("[home] start not taken effect, card is idle"))
        #expect(!text.contains(card.serial))
        let bond = try #require(card.bondId).map { String(format: "%02x", $0) }.joined()
        #expect(!text.lowercased().contains(bond))
    }
}
