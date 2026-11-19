import AppModel
import Foundation
import Library
import Testing

// X8 and #85: what the "录音已同步" notification says, and which recording a tap opens.

struct SyncNoticeTests {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func card(_ name: String, createdAt: Date) -> Recording {
        Recording(deviceId: nil, source: .card, cardFileName: name, cardFileSize: 10, startedAt: createdAt,
                  durationMs: 1_000, audioPath: "audio/\(name).ogg", audioSha256: "", title: "t",
                  createdAt: createdAt, updatedAt: createdAt)
    }

    @Test func countsNewCardRecordingsAndOpensASingleOne() {
        let before = card("old.opus", createdAt: start.addingTimeInterval(-60))
        let one = card("new.opus", createdAt: start.addingTimeInterval(5))
        var trashed = card("unwanted.opus", createdAt: start.addingTimeInterval(6))
        trashed.trashedAt = start.addingTimeInterval(7)
        var imported = card("import", createdAt: start.addingTimeInterval(8))
        imported.source = .`import`

        #expect(SyncNotice.make([before, trashed, imported], storedSince: start) == nil)
        let single = SyncNotice.make([before, one, trashed, imported], storedSince: start)
        #expect(single == SyncNotice(count: 1, recordingId: one.id))
        #expect(single?.title == "录音已同步")
        #expect(single?.body == "1 条新录音已存入手机")

        let two = card("newer.opus", createdAt: start.addingTimeInterval(9))
        let several = SyncNotice.make([one, two], storedSince: start)
        #expect(several?.count == 2)
        #expect(several?.recordingId == nil)
    }
}
