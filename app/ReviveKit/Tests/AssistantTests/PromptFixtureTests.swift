import Foundation
import Testing
@testable import Assistant

/// The summary prompts, byte for byte, as Fixtures/prompts holds them. The backend sends the same
/// prompts and checks the same files (backend/tests/test_summaries.py), so the app and the server
/// cannot drift apart unnoticed (ADR-009: one source of prompts). After changing a prompt here,
/// port it to backend/revive_api/summaries.py and run backend/scripts/make_prompt_fixtures.py.
struct PromptFixtureTests {
    private static let folder = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/prompts")

    private func fixture(_ name: String) throws -> String {
        try String(contentsOf: Self.folder.appendingPathComponent(name), encoding: .utf8)
    }

    @Test func systemPromptsMatch() throws {
        #expect(Summarizer.systemPrompt(fixedScene: nil) == (try fixture("system-auto.txt")))
        #expect(Summarizer.systemPrompt(fixedScene: .meeting) == (try fixture("system-meeting.txt")))
        #expect(Summarizer.systemPrompt(fixedScene: nil, profession: " 律师 ")
            == (try fixture("system-auto-profession.txt")))
    }

    @Test func requestPartsMatch() throws {
        #expect(Summarizer.chunkPrompt(index: 2) == (try fixture("chunk-2.txt")))
        #expect(Summarizer.chunkNotes(["第一段的要点", "第二段的要点"]) == (try fixture("chunk-notes.txt")))
        #expect(Summarizer.userMessage(material: "第一句。\n第二句。", durationMs: 3_900_000)
            == (try fixture("user-65min.txt")))
        #expect(Summarizer.retitlePrompt == (try fixture("retitle.txt")))
    }
}
