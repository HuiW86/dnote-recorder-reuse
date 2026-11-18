import AppModel
import Foundation
import Library
import Testing

// D1b 最近删除 (product-spec.md P14): the list, days left, restore, delete for good, last copy.
@MainActor
struct TrashModelTests {
    @Test func listsRestoresAndDeletes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("trash-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let library = RecordingLibrary(database: try AppDatabase.inMemory(), store: try AudioStore(root: root))
        let device = try library.upsertDevice(sn: "S") { $0.name = "card"; $0.firmware = "1.50" }
        func store(_ name: String) throws -> Recording {
            let item = try library.syncItem(deviceId: device.id, name: name, size: 10)
            let id = UUID()
            let path = try library.store.storeAudio(Data("OggS".utf8), id: id)
            let r = Recording(id: id, deviceId: device.id, source: .card, cardFileName: name, cardFileSize: 10,
                              startedAt: Date(), durationMs: 20, audioPath: path, audioSha256: "x",
                              title: "2026-11-07 14:02", createdAt: Date(), updatedAt: Date())
            _ = try library.commitStored(r, item: item, deleteAfterSync: false)
            return r
        }
        let kept = try store("a.opus")
        let gone = try store("b.opus")
        var cardGone = try #require(try library.syncItems(deviceId: device.id).first { $0.cardFileName == "b.opus" })
        cardGone.state = .deletedOnCard
        try library.update(cardGone)

        let deletedAt = Date(timeIntervalSince1970: 1_800_000_000)
        try library.trashRecording(id: kept.id, now: deletedAt)
        try library.trashRecording(id: gone.id, now: deletedAt)
        var now = deletedAt.addingTimeInterval(2.5 * 86_400)
        let model = TrashModel(library: library, now: { now })
        model.start()
        await waitUntil("listed") { model.recordings.count == 2 }

        let first = try #require(model.recordings.first { $0.id == kept.id })
        #expect(model.daysLeft(first) == 4)
        #expect(model.remainingText(first) == "还剩 4 天")
        now = deletedAt.addingTimeInterval(6.5 * 86_400)
        #expect(model.remainingText(first) == "今天到期")

        // The card still has a.opus; b.opus is gone from the card, so the phone copy is the last one.
        #expect(!model.isLastCopy(first))
        #expect(model.isLastCopy(try #require(model.recordings.first { $0.id == gone.id })))

        model.restore(kept.id)
        await waitUntil("restored") { model.recordings.count == 1 }
        #expect(model.toast?.text == "已恢复")
        #expect(try library.recording(id: kept.id)?.trashedAt == nil)

        model.deleteForever(gone.id)
        await waitUntil("deleted") { model.recordings.isEmpty }
        #expect(try library.recording(id: gone.id) == nil)
        model.stop()
    }
}
