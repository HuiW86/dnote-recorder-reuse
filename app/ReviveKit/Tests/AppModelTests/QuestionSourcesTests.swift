import Foundation
import Library
import Testing
@testable import AppModel

// G3: which summaries a 知识库 question is sent with.
struct QuestionSourcesTests {
    private func item(_ title: String, summary: String = "", tags: [String] = [], todos: [String] = [],
                      minutes: Double) -> SummarizedRecording {
        let at = Date(timeIntervalSince1970: 1_800_000_000 + minutes * 60)
        let id = UUID()
        let recording = Recording(id: id, deviceId: nil, source: .card, cardFileName: nil, cardFileSize: nil,
                                  startedAt: at, durationMs: 1_000, audioPath: "a", audioSha256: "", title: title,
                                  createdAt: at, updatedAt: at)
        let s = Summary(recordingId: id, scene: "meeting", title: title, summary: summary, sections: [],
                        todos: todos.map { SummaryTodo(text: $0, done: false) }, tags: tags, people: [],
                        model: "m", createdAt: at)
        return SummarizedRecording(recording: recording, summary: s)
    }

    @Test func chineseQuestionsSplitIntoPairsWithoutQuestionWords() {
        #expect(QuestionSources.terms(of: "什么时候上线？") == ["候上", "上线"])
        #expect(QuestionSources.terms(of: "Q3 的 OKR 定了吗") == ["q3", "okr", "定了"])
        #expect(QuestionSources.terms(of: "？！").isEmpty)
        #expect(QuestionSources.terms(of: "我").isEmpty)
    }

    /// Matching summaries go first, more matches before fewer; the newest fill the rest.
    @Test func relevantFirstThenNewest() {
        // Newest summary first, as the library gives them.
        let newest = item("灵感", summary: "选题", minutes: 30)
        let budget = item("预算会", summary: "预算定了", tags: ["预算"], minutes: 20)
        let launch = item("周会", summary: "周三上线，预算不变", minutes: 10)
        let old = item("旧会", summary: "无关", minutes: 0)
        let all = [newest, budget, launch, old]

        let picked = QuestionSources.pick("预算什么时候定了", from: all, limit: 3)
        #expect(picked.map(\.id) == [budget.id, launch.id, newest.id])

        // Nothing matches: the newest, as before.
        #expect(QuestionSources.pick("最近怎么样", from: all, limit: 2).map(\.id) == [newest.id, budget.id])
        // A question with no words to match also gets the newest.
        #expect(QuestionSources.pick("？", from: all, limit: 2).map(\.id) == [newest.id, budget.id])
        // Never more than the limit, even when more match.
        #expect(QuestionSources.pick("预算", from: all, limit: 1).map(\.id) == [budget.id])
    }

    @Test func matchesTodosTagsAndTitlesIgnoringCase() {
        let a = item("Weekly", todos: ["发 OKR 邮件"], minutes: 1)
        let b = item("别的", minutes: 2)
        #expect(QuestionSources.pick("okr", from: [b, a], limit: 1).map(\.id) == [a.id])
        #expect(QuestionSources.pick("weekly 会", from: [b, a], limit: 1).map(\.id) == [a.id])
    }
}
