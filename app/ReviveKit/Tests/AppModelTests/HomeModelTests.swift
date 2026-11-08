import AppModel
import CardLink
import CardProtocol
import CardService
import CardTestSupport
import Foundation
import Library
import SyncEngine
import Testing

// Home screen (product-spec.md P05, P04): SyncStatusCard rows, list text, and the model
// against the fake card.

struct SyncCardTests {
    private let t = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func notConnectedShowsNothingUnlessCutOff() {
        #expect(SyncCard.make(.init(connected: false, status: .idle)) == nil)
        #expect(SyncCard.make(.init(connected: false, status: .stopped("disconnected"))) == .disconnected)
        #expect(SyncCard.make(.init(connected: false, status: .idle, pendingCount: 2)) == .disconnected)
    }

    @Test func runningPassChecksThenShowsProgress() {
        #expect(SyncCard.make(.init(connected: true, status: .idle, isRunning: true)) == .checking)
        let syncing = SyncCard.make(.init(connected: true, status: .syncing(file: "a", received: 50, total: 200),
                                          isRunning: true, progress: .init(index: 2, total: 5)))
        #expect(syncing == .syncing(index: 2, total: 5, fraction: 0.25))
        #expect(syncing?.title == "正在同步 第 2 / 5 条")
        #expect(syncing?.detail == "同步完成前，卡上的录音不会被删除")
    }

    /// A pass cut off by a drop must not keep saying "disconnected" once back on the link.
    @Test func reconnectedAfterDropIsChecking() {
        #expect(SyncCard.make(.init(connected: true, status: .stopped("disconnected"), isRunning: true)) == .checking)
        #expect(SyncCard.make(.init(connected: true, status: .stopped("disconnected"), lastCompletedAt: t))
            == .done(at: t))
    }

    @Test func stoppedCodesMapToRows() {
        #expect(SyncCard.make(.init(connected: true, status: .waitingForRecording)) == .waitingForRecording)
        #expect(SyncCard.make(.init(connected: true, status: .stopped("cardBusyRecording"))) == .waitingForRecording)
        #expect(SyncCard.make(.init(connected: true, status: .stopped("phoneStorageFull"))) == .phoneStorageFull)
        let busy = SyncCard.make(.init(connected: true, status: .stopped("cardBusy")))
        #expect(busy?.title == "录音卡暂时无法传输。长按关机再开机后自动继续")
        #expect(SyncCard.make(.init(connected: true, status: .stopped("notPaired")))?.title == "这张卡需要重新配对")
        #expect(SyncCard.make(.init(connected: true, status: .stopped("other")))?.title == "同步中断，下拉可重试")
    }

    @Test func failuresBeforeCardSpaceBeforeDone() {
        let failed = SyncCard.make(.init(connected: true, status: .idle, lastCompletedAt: t,
                                         failures: .init(retryable: 2, undecryptable: 1)))
        #expect(failed == .failed(count: 2))
        #expect(failed?.title == "2 条录音同步失败，稍后自动重试")
        #expect(failed?.action == .retry)
        #expect(SyncCard.make(.init(connected: true, status: .idle, failures: .init(retryable: 0, undecryptable: 1)))
            == .undecryptable(count: 1))
        #expect(SyncCard.make(.init(connected: true, status: .idle, lastCompletedAt: t, cardFree: 700, cardTotal: 7671))
            == .cardSpaceLow)
        #expect(SyncCard.make(.init(connected: true, status: .idle, lastCompletedAt: t, cardFree: 7653, cardTotal: 7671))
            == .done(at: t))
    }

    /// `total_df` 0 means storage not read yet, not a full card; delete-after-sync makes the hint moot.
    @Test func cardSpaceNeedsKnownTotalAndDeleteAfterSyncOff() {
        #expect(SyncCard.make(.init(connected: true, status: .idle, cardFree: 0, cardTotal: 0)) == nil)
        #expect(SyncCard.make(.init(connected: true, status: .idle, cardFree: 10, cardTotal: 7671,
                                    deleteAfterSync: true)) == nil)
    }
}

struct RecordingTextTests {
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = .current
        return c
    }

    private func recording(file: String?, startedAt: Date, ms: Int) -> Recording {
        Recording(deviceId: nil, source: .card, cardFileName: file, cardFileSize: 1, startedAt: startedAt,
                  durationMs: ms, audioPath: "a", audioSha256: "", title: "", createdAt: startedAt, updatedAt: startedAt)
    }

    @Test func titleAndSubtitle() throws {
        let start = try #require(SyncEngine.startDate(fileName: "20261107140211.opus"))
        let r = recording(file: "20261107140211.opus", startedAt: start, ms: 23 * 60_000 + 5_000)
        #expect(RecordingText.title(r, calendar: calendar) == "11月7日 14:02")
        #expect(RecordingText.subtitle(r, deviceName: nil, calendar: calendar) == "14:02 · 23 分钟")
        #expect(RecordingText.subtitle(r, deviceName: "会议室卡", calendar: calendar) == "14:02 · 23 分钟 · 会议室卡")
        #expect(RecordingText.longDuration(ms: r.durationMs) == "23 分钟 5 秒")
    }

    @Test func unparsableFileNameSaysTimeUnknown() {
        let r = recording(file: "garbage.opus", startedAt: Date(), ms: 45_000)
        #expect(RecordingText.title(r) == "时间未知")
        #expect(RecordingText.subtitle(r, deviceName: nil) == "45 秒")
    }

    @Test func durations() {
        #expect(RecordingText.duration(ms: 65 * 60_000) == "1 小时 5 分钟")
        #expect(RecordingText.duration(ms: 2 * 3_600_000) == "2 小时")
        #expect(RecordingText.longDuration(ms: 0) == "0 秒")
        #expect(RecordingText.clock(seconds: 754) == "00:12:34")
    }
}

@MainActor
struct HomeModelTests {
    private func home(_ card: FakeCard) async throws -> (Harness, HomeModel) {
        let h = try Harness(card: card, bonds: InMemoryBondStore([card.serial: card.bondId!]))
        try await h.scanAndSelect()
        await waitUntil("paired") { h.isDone }
        await h.firstSyncDone()
        let model = HomeModel(session: h.session, preferences: h.preferences)
        model.start()
        return (h, model)
    }

    @Test func listFollowsSyncNewestFirst() async throws {
        let card = FakeCard(files: [
            .init(name: "20261101090000.opus", content: Data(repeating: 0x08, count: 400)),
            .init(name: "20261102090000.opus", content: Data(repeating: 0x08, count: 400)),
        ], paired: true)
        let (h, model) = try await home(card)
        await waitUntil("listed") { model.recordings.count == 2 }
        #expect(model.recordings.map(\.cardFileName) == ["20261102090000.opus", "20261101090000.opus"])
        await waitUntil("done") { if case .done = model.syncCard { true } else { false } }
        #expect(model.status == .idle)
        #expect(model.battery == 80)
        h.checkNoForbiddenWrites()
    }

    @Test func firstStartAsksForConsentOnce() async throws {
        let (h, model) = try await home(FakeCard(paired: true))
        await waitUntil("idle") { model.status == .idle }
        await h.session.syncEngine.idle()

        model.startTapped()
        #expect(model.showsConsent)
        #expect(h.sent(.startRecording) == 0)
        model.consentConfirmed()
        await waitUntil("recording") { model.status == .recording && model.pendingCommand == nil }
        #expect(model.recordingStartedAt != nil)
        #expect(model.recordedSeconds(at: Date()) == 0)

        model.stopRecording()
        await waitUntil("idle") { model.status == .idle && model.pendingCommand == nil }
        model.startTapped()
        #expect(!model.showsConsent)
        await waitUntil("recording again") { model.status == .recording }
        #expect(h.sent(.startRecording) == 2)
    }

    @Test func secondTapWhileCommandRunsIsIgnored() async throws {
        let (h, model) = try await home(FakeCard(paired: true))
        await waitUntil("idle") { model.status == .idle }
        await h.session.syncEngine.idle()
        h.preferences.recordingConsentGiven = true
        model.startTapped()
        model.startTapped()
        #expect(model.pendingCommand == .start)
        await waitUntil("recording") { model.status == .recording && model.pendingCommand == nil }
        #expect(h.sent(.startRecording) == 1)
    }

    @Test func failedCommandShowsToast() async throws {
        let (h, model) = try await home(FakeCard(paired: true))
        await waitUntil("idle") { model.status == .idle }
        await h.session.syncEngine.idle()
        h.preferences.recordingConsentGiven = true
        h.card.bondId = nil
        model.startTapped()
        await waitUntil("toast") { model.toast != nil }
        #expect(model.toast?.text == "这张卡需要重新配对")
        #expect(model.status == .idle)
    }

    @Test func pullToRefreshWhenNotConnectedToasts() async throws {
        let (h, model) = try await home(FakeCard(paired: true))
        await waitUntil("idle") { model.status == .idle }
        h.card.dropLink()
        await waitUntil("not connected") { h.session.linkState == .connecting && model.status == .waiting }
        await model.refresh()
        #expect(model.toast?.text == "录音卡未连接")
    }

    @Test func deleteRemovesRowWithoutTouchingTheCard() async throws {
        let card = FakeCard(files: [.init(name: "20261101090000.opus", content: Data(repeating: 0x08, count: 400))],
                            paired: true)
        let (h, model) = try await home(card)
        await waitUntil("listed") { model.recordings.count == 1 }
        await h.session.syncEngine.idle()
        let deletes = h.sent(.deleteFile)
        model.delete(try #require(model.recordings.first).id)
        await waitUntil("gone") { model.recordings.isEmpty }
        #expect(model.toast?.text == "已删除")
        #expect(h.sent(.deleteFile) == deletes)
        #expect(card.files.count == 1)
    }

    /// Bluetooth off drops the pending connect; turning it back on must register it again.
    @Test func bluetoothBackOnReconnects() async throws {
        let (h, model) = try await home(FakeCard(paired: true))
        await waitUntil("idle") { model.status == .idle }
        h.card.setPhoneBluetooth(.poweredOff)
        await waitUntil("unavailable") { model.status == .bluetoothUnavailable }
        h.card.setPhoneBluetooth(.idle)
        await waitUntil("pending connect") { h.session.linkState == .connecting && model.status == .waiting }
        h.card.advertise()
        await waitUntil("idle again") { model.status == .idle }
    }
}
