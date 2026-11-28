import AppModel
import Foundation
import Library
import Testing

// #89: list days with totals, 总览 and 知识库, the transcript line being played, 外观.

struct RecordingDayTests {
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return c
    }

    private func recording(_ date: Date, ms: Int) -> Recording {
        Recording(deviceId: nil, source: .phone, cardFileName: nil, cardFileSize: nil, startedAt: date,
                  durationMs: ms, audioPath: "audio/x.m4a", audioSha256: "", title: "t", createdAt: date,
                  updatedAt: date)
    }

    @Test func groupsByDayWithCountAndTotal() throws {
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 18, hour: 20)))
        let today = now.addingTimeInterval(-3600)
        let earlierToday = now.addingTimeInterval(-7200)
        let yesterday = now.addingTimeInterval(-86_400)
        let lastYear = try #require(calendar.date(from: DateComponents(year: 2025, month: 11, day: 7, hour: 9)))
        let thisYear = try #require(calendar.date(from: DateComponents(year: 2026, month: 3, day: 2, hour: 9)))
        let days = RecordingDay.group([recording(today, ms: 60_000), recording(earlierToday, ms: 3_900_000),
                                       recording(yesterday, ms: 45_000), recording(thisYear, ms: 1_000),
                                       recording(lastYear, ms: 1_000)],
                                      calendar: calendar, now: now)
        #expect(days.map(\.title) == ["今天", "昨天", "3月2日", "2025年11月7日"])
        #expect(days[0].recordings.count == 2)
        #expect(days[0].totalMs == 3_960_000)
        #expect(days[0].countText == "2 条 · 1 小时 6 分钟")
        #expect(days[1].countText == "1 条 · 45 秒")
    }

    @Test func emptyListHasNoDays() {
        #expect(RecordingDay.group([]).isEmpty)
    }
}

struct TranscriptPositionTests {
    @Test func lastLineStartedAtOrBeforeThePosition() {
        let starts = [0, 4_000, 9_500]
        #expect(RecordingDetailModel.segmentIndex(starts, atMs: 0) == 0)
        #expect(RecordingDetailModel.segmentIndex(starts, atMs: 3_999) == 0)
        #expect(RecordingDetailModel.segmentIndex(starts, atMs: 4_000) == 1)
        #expect(RecordingDetailModel.segmentIndex(starts, atMs: 60_000) == 2)
        #expect(RecordingDetailModel.segmentIndex([1_000], atMs: 500) == nil)
        #expect(RecordingDetailModel.segmentIndex([], atMs: 500) == nil)
    }
}

@MainActor
struct OverviewModelTests {
    @Test func listsOpenTodosAndCompletesThem() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("overview-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let library = RecordingLibrary(database: try AppDatabase.inMemory(), store: try AudioStore(root: root))
        let id = UUID()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let path = try library.store.storeAudio(Data("OggS".utf8), id: id)
        let r = Recording(id: id, deviceId: nil, source: .phone, cardFileName: nil, cardFileSize: nil,
                          startedAt: start, durationMs: 1_000, audioPath: path, audioSha256: "", title: "周会",
                          createdAt: start, updatedAt: start)
        try await library.database.writer.write { try r.insert($0) }
        try library.saveSummary(Summary(recordingId: id, scene: "meeting", title: "T", summary: "S", sections: [],
                                        todos: (1...7).map { SummaryTodo(text: "事项 \($0)") }, tags: [],
                                        people: [], model: "m", createdAt: start))

        let model = OverviewModel(library: library)
        model.start()
        await waitUntil("listed") { model.digest.openTodos.count == 7 }
        #expect(model.visibleTodos.map(\.text) == (1...5).map { "事项 \($0)" })
        #expect(model.moreTodosText == "还有 2 件，在各条录音的纪要里")
        #expect(model.sourceText(model.visibleTodos[0]) == "来自「周会」")
        #expect(model.untranscribedText == "还有 1 条没转成文字")
        #expect(model.digest.recentSummaries.map(\.recording.id) == [id])

        model.complete(model.visibleTodos[0])
        await waitUntil("ticked") { model.digest.openTodos.count == 6 }
        #expect(model.toast?.text == "已完成")
        #expect(model.visibleTodos.first?.text == "事项 2")
        #expect(model.moreTodosText == "还有 1 件，在各条录音的纪要里")
        #expect(try library.summary(recordingId: id)?.todos.first?.done == true)
        #expect(model.toast?.action == "撤销")

        // 撤销 opens the todo again.
        model.undoComplete()
        await waitUntil("reopened") { model.digest.openTodos.count == 7 }
        #expect(model.visibleTodos.first?.text == "事项 1")
        #expect(try library.summary(recordingId: id)?.todos.first?.done == false)
        model.complete(model.visibleTodos[0])
        await waitUntil("ticked again") { model.digest.openTodos.count == 6 }

        try library.saveTranscript(Transcript(recordingId: id, engine: "t", language: "zh-CN", segments: [],
                                              createdAt: start))
        await waitUntil("transcribed") { model.untranscribedText == nil }
        model.stop()
    }
}

@MainActor
struct AppearanceTests {
    @Test func defaultsToSystemAndIsKept() throws {
        let suite = "appearance-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(Preferences(defaults: defaults).appearance == .system)
        Preferences(defaults: defaults).appearance = .dark
        #expect(Preferences(defaults: defaults).appearance == .dark)
        #expect(Preferences.Appearance.allCases.map(\.title) == ["跟随系统", "浅色", "深色"])
    }
}
