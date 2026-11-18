import AppModel
import Foundation
import Library
import Testing

// 最近删除 (features.md D1b) and the sync notification text (features.md X8), #85.

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

private func cardRecording(_ name: String, path: String = "audio/x.ogg", createdAt: Date = t0) -> Recording {
    Recording(deviceId: nil, source: .card, cardFileName: name, cardFileSize: 3, startedAt: createdAt,
              durationMs: 1000, audioPath: path, audioSha256: "", title: name, createdAt: createdAt,
              updatedAt: createdAt)
}

@MainActor
struct TrashModelTests {
    @Test func listsCountsDownRestoresAndDeletesForGood() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("trash-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let library = RecordingLibrary(database: try AppDatabase.inMemory(), store: try AudioStore(root: root))
        var added: [Recording] = []
        for name in ["a.opus", "b.opus"] {
            let id = UUID()
            var r = cardRecording(name, path: try library.store.storeAudio(Data([1, 2, 3]), id: id))
            r.id = id
            let row = r
            try await library.database.writer.write { try row.insert($0) }
            added.append(row)
        }
        let (a, b) = (added[0], added[1])
        try library.trashRecording(id: a.id, now: t0.addingTimeInterval(-6.5 * 86_400))
        try library.trashRecording(id: b.id, now: t0.addingTimeInterval(-0.5 * 86_400))

        let model = TrashModel(library: library, now: { t0 })
        model.start()
        await waitUntil("listed") { model.recordings.count == 2 }
        // The most recently deleted first.
        #expect(model.recordings.map(\.id) == [b.id, a.id])
        let (trashedB, trashedA) = (model.recordings[0], model.recordings[1])
        #expect(model.daysLeft(trashedB) == 6 && model.remainingText(trashedB) == "还剩 6 天")
        #expect(model.daysLeft(trashedA) == 0 && model.remainingText(trashedA) == "今天到期")
        // Nothing says the card still has it: deleting it here loses it.
        #expect(model.isLastCopy(trashedA))

        model.restore(b.id)
        #expect(model.toast?.text == "已恢复")
        await waitUntil("restored") { model.recordings.map(\.id) == [a.id] }
        #expect(try library.recording(id: b.id)?.trashedAt == nil)

        model.deleteForever(a.id)
        #expect(model.toast?.text == "已彻底删除")
        await waitUntil("gone") { model.recordings.isEmpty }
        #expect(try library.recording(id: a.id) == nil)
        #expect(!FileManager.default.fileExists(atPath: library.store.url(forAudioPath: a.audioPath).path))

        try library.trashRecording(id: b.id)
        await waitUntil("trashed again") { model.recordings.count == 1 }
        model.empty()
        #expect(model.toast?.text == "已清空")
        await waitUntil("emptied") { model.recordings.isEmpty }
        #expect(try library.recordings().isEmpty)
        model.stop()
    }
}

struct SyncNoticeTests {
    @Test func countsNewCardRecordingsAndOpensASingleOne() {
        let start = t0
        let before = cardRecording("old.opus", createdAt: start.addingTimeInterval(-60))
        let one = cardRecording("new.opus", createdAt: start.addingTimeInterval(5))
        var trashed = cardRecording("unwanted.opus", createdAt: start.addingTimeInterval(6))
        trashed.trashedAt = start.addingTimeInterval(7)
        var imported = cardRecording("import", createdAt: start.addingTimeInterval(8))
        imported.source = .`import`

        #expect(SyncNotice.make([before, trashed, imported], storedSince: start) == nil)
        let single = SyncNotice.make([before, one, trashed, imported], storedSince: start)
        #expect(single == SyncNotice(count: 1, recordingId: one.id))
        #expect(single?.title == "录音已同步")
        #expect(single?.body == "1 条新录音已存入手机")

        let two = cardRecording("newer.opus", createdAt: start.addingTimeInterval(9))
        let several = SyncNotice.make([one, two], storedSince: start)
        #expect(several?.count == 2)
        #expect(several?.recordingId == nil)
    }
}
