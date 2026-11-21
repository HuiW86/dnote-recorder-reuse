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
                                         failures: .init(retryable: 2, undecryptable: 1, autoRetrying: 1)))
        #expect(failed == .failed(count: 2, retrying: true))
        #expect(failed?.title == "2 条录音同步失败，稍后自动重试")
        #expect(failed?.action == .retry)
        // product-spec.md §7.1: no automatic retries left, so the text points to pull-to-refresh.
        let exhausted = SyncCard.make(.init(connected: true, status: .idle,
                                            failures: .init(retryable: 2, undecryptable: 0)))
        #expect(exhausted?.title == "2 条录音同步失败，下拉可重试")
        #expect(exhausted?.action == .retry)
        let undecryptable = SyncCard.make(.init(connected: true, status: .idle,
                                                failures: .init(retryable: 0, undecryptable: 1)))
        #expect(undecryptable == .undecryptable(count: 1))
        #expect(undecryptable?.action == .exportDiagnostics)
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
        let start = try #require(CardFile.startDate(fileName: "20261107140211.opus"))
        let r = recording(file: "20261107140211.opus", startedAt: start, ms: 23 * 60_000 + 5_000)
        #expect(RecordingText.title(r, calendar: calendar) == "11月7日 14:02")
        #expect(RecordingText.subtitle(r, deviceName: nil, calendar: calendar) == "14:02 · 23 分钟")
        #expect(RecordingText.subtitle(r, deviceName: "会议室卡", calendar: calendar) == "14:02 · 23 分钟 · 会议室卡")
        #expect(RecordingText.longDuration(ms: r.durationMs) == "23 分钟 5 秒")
    }

    /// Chinese and 24-hour on a phone set to an English region too.
    @Test func dateTimeIgnoresPhoneRegion() throws {
        let evening = try #require(CardFile.startDate(fileName: "20261108234600.opus"))
        #expect(RecordingText.dateTime(evening, calendar: calendar) == "11月8日 23:46")
        #expect(RecordingText.time(evening, calendar: calendar) == "23:46")
    }

    /// D1c: a recording that did not come from a card says where it came from.
    @Test func subtitleNamesTheSourceOfNonCardRecordings() {
        var r = recording(file: "20261107140211.opus", startedAt: Date(), ms: 45_000)
        r.source = .phone
        #expect(RecordingText.subtitle(r, deviceName: nil, calendar: calendar).hasSuffix("45 秒 · 手机录音"))
        r.source = .import
        #expect(RecordingText.subtitle(r, deviceName: nil, calendar: calendar).hasSuffix("· 导入"))
        #expect(RecordingText.sourceName(.card) == "录音卡")
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

    /// E2 文字文件: a .txt or .md picked in Files becomes a recording with no audio; an empty or
    /// unreadable one is counted as failed.
    @Test func importsTextFilesAsRecordingsWithoutAudio() async throws {
        let (h, model) = try await home(FakeCard(paired: true))
        await waitUntil("idle") { model.status == .idle }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("text-in-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let notes = dir.appendingPathComponent("会议记录.txt")
        try Data("周三发布。\n\n测试通过以后上线。".utf8).write(to: notes)
        let empty = dir.appendingPathComponent("空白.md")
        try Data("   \n".utf8).write(to: empty)
        #expect(HomeModel.textExtensions.contains("md"))

        await model.importAudio([notes, empty])
        #expect(model.toast?.text == "已导入 1 个，1 个无法识别")
        let stored = try #require(try h.library.recordings().first { $0.title == "会议记录" })
        #expect(!stored.hasAudio && stored.source == .import)
        #expect(try h.library.transcript(recordingId: stored.id)?.segments.map(\.text) == ["周三发布。", "测试通过以后上线。"])
        await waitUntil("listed") { model.recordings.contains { $0.id == stored.id } }
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

    /// #47: no reply and the card did not start either (0x56 says idle): safe to ask for a retry.
    @Test func unansweredStartThatDidNothingAsksToRetry() async throws {
        let (h, model) = try await home(FakeCard(paired: true))
        await waitUntil("idle") { model.status == .idle }
        await h.session.syncEngine.idle()
        h.preferences.recordingConsentGiven = true
        h.shortenRequestTimeouts()
        h.card.faults = [.noResponse(.startRecording)]
        model.startTapped()
        await waitUntil("toast") { model.toast != nil && model.pendingCommand == nil }
        #expect(model.toast?.text == "录音卡没有响应，请重试")
        #expect(model.status == .idle)
        #expect(model.prompt == nil)
        #expect(h.sent(.startRecording) == 1)
    }

    private func recordingHome() async throws -> (Harness, HomeModel) {
        let (h, model) = try await home(FakeCard(paired: true))
        await waitUntil("idle") { model.status == .idle }
        await h.session.syncEngine.idle()
        h.preferences.recordingConsentGiven = true
        model.startTapped()
        await waitUntil("recording") { model.status == .recording && model.pendingCommand == nil }
        return (h, model)
    }

    /// #47: the pause took effect but its reply was lost; 0x56 settles the state, no Toast.
    @Test func lostPauseReplyFollowsTheCard() async throws {
        let (h, model) = try await recordingHome()
        h.shortenRequestTimeouts()
        h.card.faults = [.dropReply(.pauseRecording)]
        model.pause()
        // Controls stay locked until the card's state is known.
        model.resume()
        model.stopRecording()
        await waitUntil("paused") { model.status == .paused && model.pendingCommand == nil }
        #expect(model.toast == nil)
        #expect(h.sent(.pauseRecording) == 1)
        #expect(h.sent(.resumeRecording) == 0)
        #expect(h.sent(.stopRecording) == 0)
    }

    @Test func lostStartReplyFollowsTheCard() async throws {
        let (h, model) = try await home(FakeCard(paired: true))
        await waitUntil("idle") { model.status == .idle }
        await h.session.syncEngine.idle()
        h.preferences.recordingConsentGiven = true
        h.shortenRequestTimeouts()
        h.card.faults = [.dropReply(.startRecording)]
        model.startTapped()
        await waitUntil("recording") { model.status == .recording && model.pendingCommand == nil }
        #expect(model.toast == nil)
        #expect(model.recordingStartedAt != nil)
        #expect(h.sent(.startRecording) == 1)
    }

    /// #47: neither the reply nor 0x56 comes back: the Toast stays, nothing is sent again, and
    /// the next 0x80 push corrects the state through 0x56.
    @Test func unansweredStatusKeepsToastUntilTheNextDeviceInfo() async throws {
        let (h, model) = try await recordingHome()
        h.shortenRequestTimeouts()
        h.card.faults = [.dropReply(.pauseRecording), .noResponse(.recordingStatus)]
        model.pause()
        await waitUntil("toast") { model.toast != nil && model.pendingCommand == nil }
        #expect(model.toast?.text == "录音卡没有响应，录音状态未确认")
        #expect(model.status == .recording)
        #expect(h.sent(.pauseRecording) == 1)

        h.card.faults = []
        h.card.pushDeviceInfo()
        await waitUntil("paused") { model.status == .paused }
    }

    /// When 0x56 stays silent, the 0x80 state itself is used.
    @Test func deviceInfoStateIsUsedWhenStatusStaysSilent() async throws {
        let (h, model) = try await recordingHome()
        h.shortenRequestTimeouts()
        h.card.faults = [.dropReply(.pauseRecording), .noResponse(.recordingStatus)]
        model.pause()
        await waitUntil("toast") { model.toast != nil && model.pendingCommand == nil }
        h.card.pushDeviceInfo()
        await waitUntil("paused") { model.status == .paused }
    }

    /// An unrecognised `rec` in 0x56 does not settle a timed-out command.
    @Test func unknownStatusCodeKeepsTheCommandUnconfirmed() async throws {
        let (h, model) = try await recordingHome()
        h.shortenRequestTimeouts()
        h.card.faults = [.dropReply(.pauseRecording)]
        h.card.recordingCodeOverride = 7
        model.pause()
        await waitUntil("toast") { model.toast != nil && model.pendingCommand == nil }
        #expect(model.toast?.text == "录音卡没有响应，录音状态未确认")
        #expect(h.sent(.pauseRecording) == 1)
    }

    /// A button press while the 0x56 behind a 0x80 is pending beats that 0x80's state.
    @Test func newerStateBeatsTheDeviceInfoFallback() async throws {
        let (h, model) = try await recordingHome()
        h.shortenRequestTimeouts()
        h.card.faults = [.dropReply(.pauseRecording), .noResponse(.recordingStatus)]
        model.pause()
        await waitUntil("toast") { model.toast != nil && model.pendingCommand == nil }
        #expect(model.status == .recording)

        h.card.pushDeviceInfo()                      // says paused; its 0x56 goes unanswered
        try await Task.sleep(for: .milliseconds(100))
        h.card.pressButtonToRecord()                 // newer: recording again
        await waitUntil("recording") { model.status == .recording && model.recordedSeconds(at: Date()) == 0 }
        try await Task.sleep(for: .seconds(2.5))     // past the 0x56 timeout
        #expect(model.status == .recording)
    }

    /// Same, when the 0x56 answer itself is stale: it was taken before the button press but
    /// is handled after it.
    @Test func newerStateBeatsALateStatusAnswer() async throws {
        let (h, model) = try await recordingHome()
        h.shortenRequestTimeouts()
        h.card.faults = [.dropReply(.pauseRecording), .noResponse(.recordingStatus)]
        model.pause()
        await waitUntil("toast") { model.toast != nil && model.pendingCommand == nil }

        h.card.faults = [.delayReply(.recordingStatus, milliseconds: 300)]
        h.card.pushDeviceInfo()                      // says paused; 0x56 answers paused, late
        try await Task.sleep(for: .milliseconds(100))
        h.card.pressButtonToRecord()                 // newer: recording again
        await waitUntil("recording") { model.status == .recording && model.recordedSeconds(at: Date()) == 0 }
        try await Task.sleep(for: .milliseconds(500)) // past the late answer
        #expect(model.status == .recording)
    }

    /// A button press while the 0x56 after a timeout is pending beats that 0x56's answer.
    @Test func buttonPressBeatsALateReconcileAnswer() async throws {
        let (h, model) = try await home(FakeCard(paired: true))
        await waitUntil("idle") { model.status == .idle }
        await h.session.syncEngine.idle()
        h.preferences.recordingConsentGiven = true
        h.shortenRequestTimeouts()
        h.card.faults = [.noResponse(.startRecording), .delayReply(.recordingStatus, milliseconds: 300)]
        let reads = h.sent(.recordingStatus)
        model.startTapped()
        await waitUntil("0x56 sent") { h.sent(.recordingStatus) > reads }  // answers idle, late
        h.card.pressButtonToRecord()
        await waitUntil("done") { model.pendingCommand == nil }
        #expect(model.status == .recording)
        #expect(model.toast == nil)
    }

    /// A newer 0x80 that agrees with the app supersedes an older one's pending fallback.
    @Test func newerDeviceInfoBeatsAnOlderFallback() async throws {
        let (h, model) = try await recordingHome()
        h.shortenRequestTimeouts()
        h.card.faults = [.dropReply(.pauseRecording), .noResponse(.recordingStatus)]
        model.pause()
        await waitUntil("toast") { model.toast != nil && model.pendingCommand == nil }

        h.card.pushDeviceInfo()                      // says paused; its 0x56 goes unanswered
        try await Task.sleep(for: .milliseconds(100))
        h.card.recordingCodeOverride = 1
        h.card.pushDeviceInfo()                      // newer: says recording, as the app shows
        try await Task.sleep(for: .seconds(2.5))     // past the first 0x56 timeout
        #expect(model.status == .recording)
    }

    /// #53, the case left over from PR #51: a 0x80 that agrees with the app arrives while a 0x56
    /// read is out. It is newer than that read's answer, so the answer is dropped.
    @Test func agreeingDeviceInfoBeatsALateStatusAnswer() async throws {
        let (h, model) = try await recordingHome()
        h.shortenRequestTimeouts()
        h.card.faults = [.dropReply(.pauseRecording), .noResponse(.recordingStatus)]
        model.pause()
        await waitUntil("toast") { model.toast != nil && model.pendingCommand == nil }
        #expect(model.status == .recording)

        h.card.faults = [.delayReply(.recordingStatus, milliseconds: 300)]
        let reads = h.sent(.recordingStatus)
        h.card.pushDeviceInfo()                      // says paused; 0x56 answers paused, late
        await waitUntil("0x56 sent") { h.sent(.recordingStatus) > reads }
        h.card.recordingCodeOverride = 1
        h.card.pushDeviceInfo()                      // newer: says recording, as the app shows
        try await Task.sleep(for: .milliseconds(500)) // past the late answer
        #expect(model.status == .recording)
        #expect(h.sent(.recordingStatus) == reads + 1)  // the agreeing 0x80 reads nothing
    }

    /// #47: a start confirmed by 0x56 after a lost reply still gets its stop reported, which
    /// is what starts the sync after recording.
    @Test func stopAfterARecoveredStartIsReported() async throws {
        let (h, model) = try await recordingHome()
        var stops = 0
        h.session.addListener { if $0 == .recordingStopped { stops += 1 } }
        model.stopRecording()
        await waitUntil("first stop") { stops == 1 && model.pendingCommand == nil }

        h.shortenRequestTimeouts()
        h.card.faults = [.dropReply(.startRecording)]
        model.startTapped()
        await waitUntil("recovered") { model.status == .recording && model.pendingCommand == nil }
        h.card.faults = []
        h.card.pressButtonToStop()
        await waitUntil("second stop") { stops == 2 }
    }

    /// A stop whose pushes were lost, found through 0x80 and 0x56, still syncs the recording.
    @Test func stopFoundWithoutItsPushStillSyncs() async throws {
        let (h, model) = try await recordingHome()
        let before = model.recordings.count
        h.card.stopWithPushesLost()
        h.card.pushDeviceInfo()
        await waitUntil("idle") { model.status == .idle }
        await waitUntil("synced") { model.recordings.count == before + 1 }
    }

    /// The DEBUG card screen (autoSyncEnabled off) sends its own requests only.
    @Test func deviceInfoSendsNothingWhileDebugScreenIsOpen() async throws {
        let (h, model) = try await recordingHome()
        h.shortenRequestTimeouts()
        h.card.faults = [.dropReply(.pauseRecording), .noResponse(.recordingStatus)]
        model.pause()
        await waitUntil("toast") { model.toast != nil && model.pendingCommand == nil }
        h.card.faults = []
        h.session.autoSyncEnabled = false
        let reads = h.sent(.recordingStatus)
        h.card.pushDeviceInfo()
        try await Task.sleep(for: .milliseconds(300))
        #expect(h.sent(.recordingStatus) == reads)
        #expect(model.status == .recording)
    }

    /// product-spec.md §7.1: `notPaired` from a command is a Modal, not a Toast.
    @Test func notPairedCommandAsksToRepair() async throws {
        let (h, model) = try await home(FakeCard(paired: true))
        await waitUntil("idle") { model.status == .idle }
        await h.session.syncEngine.idle()
        h.preferences.recordingConsentGiven = true
        h.card.bondId = nil
        model.startTapped()
        await waitUntil("prompt") { model.prompt != nil }
        #expect(model.prompt == .repair)
        #expect(model.prompt?.title == "这张卡需要重新配对")
        #expect(model.toast == nil)
        #expect(model.status == .idle)
    }

    /// A sync pass finding the card unpaired raises the Modal; "重新配对" drops the link so the
    /// card advertises for P03, and home does not reconnect meanwhile.
    @Test func notPairedSyncAsksToRepairAndDropsLink() async throws {
        let (h, model) = try await home(FakeCard(paired: true))
        await waitUntil("idle") { model.status == .idle }
        await h.session.syncEngine.idle()
        h.card.bondId = nil
        model.retrySync()
        await waitUntil("prompt") { model.prompt == .repair }
        #expect(model.syncCard?.title == "这张卡需要重新配对")

        model.repairTapped()
        #expect(model.prompt == nil)
        await waitUntil("dropped") { model.status == .waiting }
        #expect(h.session.userDisconnected)
        #expect(h.session.linkState == .disconnected(.requested))
    }

    /// product-spec.md §7.1: a card the phone cannot find any more asks to search again.
    @Test func unknownCardAsksToRescan() async throws {
        let (h, model) = try await home(FakeCard(paired: true))
        await waitUntil("idle") { model.status == .idle }
        let device = try #require(model.currentDevice)
        _ = try h.library.upsertDevice(sn: device.sn) { $0.peripheralId = UUID().uuidString }
        h.session.refreshDevices()
        h.session.disconnect()
        await waitUntil("waiting") { model.status == .waiting }
        await model.refresh()
        #expect(model.prompt == .rescan)
        #expect(model.prompt?.actionTitle == "重新搜索")
        #expect(model.toast == nil)
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
        #expect(model.toast?.text == "已移到最近删除" && model.toast?.action == "撤销")
        #expect(h.sent(.deleteFile) == deletes)
        #expect(card.files.count == 1)
        // D1b: the recording waits in 最近删除 with its audio, and "撤销" brings it back.
        let trashed = try #require(try h.library.trashedRecordings().first)
        #expect(FileManager.default.fileExists(atPath: h.library.store.url(forAudioPath: trashed.audioPath).path))
        model.undoDelete()
        await waitUntil("back") { model.recordings.count == 1 }
        #expect(model.toast?.text == "已恢复")
        #expect(try h.library.trashedRecordings().isEmpty)
        #expect(h.sent(.deleteFile) == deletes)
    }

    /// design-spec.md §3 filter chips: 有重点 and 还没转文字 narrow the list.
    @Test func filtersByMarksAndTranscripts() async throws {
        let card = FakeCard(files: [.init(name: "20261101090000.opus", content: Data(repeating: 0x08, count: 400)),
                                    .init(name: "20261102090000.opus", content: Data(repeating: 0x09, count: 400))],
                            paired: true)
        let (h, model) = try await home(card)
        await waitUntil("listed") { model.recordings.count == 2 }
        let marked = try #require(model.recordings.first { $0.cardFileName == "20261101090000.opus" })
        let transcribed = try #require(model.recordings.first { $0.cardFileName == "20261102090000.opus" })
        try h.library.addMark(deviceId: try #require(marked.deviceId), cardFileName: "20261101090000.opus", offsetMs: 0)
        try h.library.saveTranscript(Transcript(recordingId: transcribed.id, engine: "t", language: "zh-CN",
                                                segments: [TranscriptSegment(startMs: 0, text: "x")], createdAt: Date()))
        #expect(model.filteredRecordings.count == 2)
        model.filter = .marked
        #expect(model.filteredRecordings.map(\.id) == [marked.id])
        model.filter = .untranscribed
        #expect(model.filteredRecordings.map(\.id) == [marked.id])
        #expect(model.markCount(for: marked) == 1 && model.markCount(for: transcribed) == 0)

        // #89: 星标 from the list row, and 有待办 for a summary with a todo not yet ticked.
        model.filter = .starred
        #expect(model.filteredRecordings.isEmpty)
        model.toggleStar(transcribed.id)
        await waitUntil("starred") { model.filteredRecordings.map(\.id) == [transcribed.id] }
        model.toggleStar(transcribed.id)
        await waitUntil("unstarred") { model.filteredRecordings.isEmpty }
        try h.library.saveSummary(Summary(recordingId: marked.id, scene: "meeting", title: "T", summary: "S",
                                          sections: [], todos: [SummaryTodo(text: "a")], tags: [], people: [],
                                          model: "m", createdAt: Date()))
        model.filter = .withTodos
        #expect(model.filteredRecordings.map(\.id) == [marked.id])
        try h.library.setTodoDone(recordingId: marked.id, index: 0, done: true)
        #expect(model.filteredRecordings.isEmpty)
        model.filter = .all
        #expect(model.days.map { $0.recordings.count }.reduce(0, +) == 2)
    }

    /// D1c 按来源筛选: chips only when there is more than one source; a source chip narrows the
    /// list on top of the filter.
    @Test func sourceChipNarrowsTheList() async throws {
        let card = FakeCard(files: [.init(name: "20261101090000.opus", content: Data(repeating: 0x08, count: 400))],
                            paired: true)
        let (h, model) = try await home(card)
        await waitUntil("listed") { model.recordings.count == 1 }
        #expect(model.sources.isEmpty)
        let file = h.root.appendingPathComponent("phone.m4a")
        try FileManager.default.createDirectory(at: h.root, withIntermediateDirectories: true)
        try Data("m4a".utf8).write(to: file)
        let phone = try h.library.addPhoneRecording(file: file, startedAt: Date(), durationMs: 1_000)
        await waitUntil("both listed") { model.recordings.count == 2 }
        #expect(model.sources == [.card, .phone])
        model.sourceFilter = .phone
        #expect(model.filteredRecordings.map(\.id) == [phone.id])
        model.filter = .starred
        #expect(model.filteredRecordings.isEmpty)
        model.filter = .all
        model.sourceFilter = .card
        #expect(model.filteredRecordings.allSatisfy { $0.source == .card } && model.filteredRecordings.count == 1)
    }

    /// D1c: a folder chip narrows the list on top of the filter; deleting the folder clears it
    /// and keeps the recordings.
    @Test func folderChipNarrowsTheList() async throws {
        let card = FakeCard(files: [.init(name: "20261101090000.opus", content: Data(repeating: 0x08, count: 400)),
                                    .init(name: "20261102090000.opus", content: Data(repeating: 0x09, count: 400))],
                            paired: true)
        let (h, model) = try await home(card)
        await waitUntil("listed") { model.recordings.count == 2 }
        let inside = try #require(model.recordings.first { $0.cardFileName == "20261101090000.opus" })
        let folder = try #require(try h.library.createFolder(named: "客户"))
        try h.library.moveRecording(id: inside.id, toFolder: folder.id)
        model.refreshFolders()
        #expect(model.folders.map(\.name) == ["客户"])
        await waitUntil("moved") { model.recordings.contains { $0.folderId == folder.id } }

        model.folderFilter = folder.id
        #expect(model.filteredRecordings.map(\.id) == [inside.id])
        model.filter = .starred
        #expect(model.filteredRecordings.isEmpty)
        model.toggleStar(inside.id)
        await waitUntil("starred in folder") { model.filteredRecordings.map(\.id) == [inside.id] }

        model.filter = .all
        model.deleteFolder(folder)
        #expect(model.toast?.text == "已删除文件夹，里面的录音还在")
        #expect(model.folderFilter == nil && model.folders.isEmpty)
        await waitUntil("both listed") { model.filteredRecordings.count == 2 }
    }

    // MARK: - Marks and keep or discard (features.md X7, X10; #85)

    /// X7: a mark needs a running recording; a double tap adds one; the list row of the stored
    /// recording counts it.
    @Test func marksFollowTheRunningRecording() async throws {
        let (h, model) = try await home(FakeCard(paired: true))
        await waitUntil("idle") { model.status == .idle }
        await h.session.syncEngine.idle()
        model.markNow()
        #expect(model.toast?.text == "现在还不能标重点")
        #expect(model.markCount == 0)

        h.preferences.recordingConsentGiven = true
        model.startTapped()
        await waitUntil("recording") { model.status == .recording && model.pendingCommand == nil }
        let name = try #require(h.session.recordingName)
        model.markNow()
        model.markNow()  // within 2 s of the first: a double tap
        #expect(model.markCount == 1)

        model.stopRecording()
        await waitUntil("stored") { model.recordings.contains { $0.cardFileName == name } }
        #expect(model.markCount == 0)
        let stored = try #require(model.recordings.first { $0.cardFileName == name })
        #expect(model.markCount(for: stored) == 1)
        h.checkNoForbiddenWrites()
    }

    /// X10 "不要": the recording is still stored first, then goes to 最近删除 and its card file is
    /// deleted (CLAUDE.md rule 2). "撤销" afterwards brings the phone copy back.
    @Test func discardStoresThenTrashesAndDeletesFromCard() async throws {
        let (h, model) = try await recordingHome()
        model.keepOfferDuration = .seconds(30)
        let name = try #require(h.session.recordingName)
        model.stopRecording()
        await waitUntil("offered") { model.justRecorded != nil }
        #expect(model.justRecorded?.cardFileName == name)

        model.discardJustRecorded()
        #expect(model.justRecorded == nil)
        #expect(model.toast?.text == "这条不会保留" && model.toast?.action == "撤销")
        await waitUntil("deleted from card") { !h.card.files.contains { $0.name == name } }
        let trashed = try h.library.trashedRecordings()
        #expect(trashed.contains { $0.cardFileName == name })
        #expect(!model.recordings.contains { $0.cardFileName == name })

        model.undoDelete()
        #expect(model.toast?.text == "已保留")
        await waitUntil("back in the list") { model.recordings.contains { $0.cardFileName == name } }
        h.checkNoForbiddenWrites()
    }

    /// X10: not answering keeps the recording; nothing goes to 最近删除.
    @Test func unansweredOfferKeepsTheRecording() async throws {
        let (h, model) = try await recordingHome()
        model.keepOfferDuration = .milliseconds(100)
        let name = try #require(h.session.recordingName)
        model.stopRecording()
        await waitUntil("offered") { model.justRecorded != nil }
        await waitUntil("closed") { model.justRecorded == nil }
        await waitUntil("stored") { model.recordings.contains { $0.cardFileName == name } }
        #expect(try h.library.trashedRecordings().isEmpty)
        #expect(h.card.files.contains { $0.name == name })
    }

    /// #85: a recording that ended while the card was away is offered once the card is back,
    /// without a length (the card did not say when it stopped).
    @Test func recordingThatEndedWhileAwayIsOfferedOnReconnect() async throws {
        let (h, model) = try await recordingHome()
        model.keepOfferDuration = .seconds(30)
        let name = try #require(h.session.recordingName)
        h.card.dropLink()
        await waitUntil("waiting") { model.status == .waiting }
        #expect(model.justRecorded == nil)
        h.card.stopWithPushesLost()
        h.card.advertise()
        await waitUntil("offered") { model.justRecorded != nil }
        #expect(model.justRecorded?.cardFileName == name)
        #expect(model.justRecorded?.recordedMs == nil)
        #expect(model.status == .idle)
    }

    /// #85: still recording after the reconnect: nothing is offered until it stops, then once.
    @Test func recordingStillGoingAfterReconnectIsOfferedWhenItStops() async throws {
        let (h, model) = try await recordingHome()
        model.keepOfferDuration = .seconds(30)
        let name = try #require(h.session.recordingName)
        h.card.dropLink()
        await waitUntil("waiting") { model.status == .waiting }
        h.card.advertise()
        await waitUntil("recording again") { model.status == .recording && h.session.recordingName == name }
        #expect(model.justRecorded == nil)
        h.card.pressButtonToStop()
        await waitUntil("offered") { model.justRecorded != nil }
        #expect(model.justRecorded?.cardFileName == name)
        #expect(model.justRecorded?.recordedMs != nil)
    }

    /// A second paired card. `peripheral` nil means one CoreBluetooth no longer knows.
    private func addSecondCard(_ h: Harness, peripheral: UUID?) throws -> UUID {
        let device = try h.library.upsertDevice(sn: "SECONDCARD000002") { d in
            d.name = "第二张卡"
            d.firmware = "1.50"
            d.peripheralId = (peripheral ?? UUID()).uuidString
            d.pairedAt = Date()
        }
        h.session.refreshDevices()
        return device.id
    }

    /// product-spec.md P08: rows from the local database; picking another card makes it current
    /// and drops the card on the link for it.
    @Test func switchingCardsDropsTheLinkAndWaitsForTheOther() async throws {
        let (h, model) = try await home(FakeCard(paired: true))
        await waitUntil("idle") { model.status == .idle }
        await h.session.syncEngine.idle()
        let first = try #require(model.currentDevice).id
        let second = try addSecondCard(h, peripheral: h.card.id)
        #expect(model.deviceRows.map(\.id) == [first, second])
        #expect(model.deviceRows.map(\.isCurrent) == [true, false])
        #expect(model.deviceRows.first?.status == .idle)

        #expect(model.selectDevice(second))
        #expect(model.currentDevice?.id == second)
        #expect(h.preferences.currentDeviceId == second)
        await waitUntil("old card dropped") { h.session.connectedDevice == nil }
        #expect(model.prompt == nil)
        #expect(model.deviceRows.map(\.isCurrent) == [false, true])
        #expect(!h.session.userDisconnected)
    }

    /// product-spec.md P08 "上次连接" follows every pass, one with no new files included, without
    /// a pairing screen re-reading the list (evidence/v46-merge-smoke S4).
    @Test func lastSeenFollowsEachPass() async throws {
        let (h, model) = try await home(FakeCard(paired: true))
        await waitUntil("idle") { model.status == .idle }
        await h.session.syncEngine.idle()
        let before = try #require(model.deviceRows.first?.lastSeenAt)
        try await Task.sleep(for: .milliseconds(20))
        h.session.syncEngine.requestSync()
        await h.session.syncEngine.idle()
        let after = try #require(model.deviceRows.first?.lastSeenAt)
        #expect(after > before)
        // §2.4 上次同步完成时间: stamped when the pass finishes, and what the row shows.
        let synced = try #require(model.deviceRows.first?.lastSyncedAt)
        #expect(synced >= after)
        #expect(model.deviceRows.first?.subtitle == "已连接 · 上次同步 \(RecordingText.dateTime(synced))")
    }

    @Test func switchingToAnUnknownCardAsksToRescan() async throws {
        let (h, model) = try await home(FakeCard(paired: true))
        await waitUntil("idle") { model.status == .idle }
        await h.session.syncEngine.idle()
        let second = try addSecondCard(h, peripheral: nil)
        // P08 stays open with its own Modal; home's would not show under the sheet.
        #expect(!model.selectDevice(second))
        #expect(model.currentDevice?.id == second)
        #expect(model.switcherPrompt == .rescan)
        #expect(model.prompt == nil)
    }

    /// product-spec.md §5.3: switching away from a recording card asks first.
    @Test func switchingWhileRecordingAsksFirst() async throws {
        let (h, model) = try await home(FakeCard(paired: true))
        await waitUntil("idle") { model.status == .idle }
        await h.session.syncEngine.idle()
        let first = try #require(model.currentDevice).id
        let second = try addSecondCard(h, peripheral: h.card.id)
        h.preferences.recordingConsentGiven = true
        model.startTapped()
        await waitUntil("recording") { model.status == .recording && model.pendingCommand == nil }

        #expect(!model.selectDevice(second))
        #expect(model.pendingSwitch?.deviceId == second)
        #expect(model.pendingSwitch?.reason == .recording)
        #expect(model.pendingSwitch?.message == "卡会继续录音，切回来后再同步。")
        #expect(model.currentDevice?.id == first)
        #expect(model.confirmSwitch())
        #expect(model.pendingSwitch == nil)
        #expect(model.currentDevice?.id == second)
    }

    @Test func pickingTheCurrentCardJustCloses() async throws {
        let (h, model) = try await home(FakeCard(paired: true))
        await waitUntil("idle") { model.status == .idle }
        let first = try #require(model.currentDevice).id
        #expect(model.selectDevice(first))
        #expect(h.session.connectedDevice?.id == first)
    }

    @Test func coldLaunchWaitsForBluetoothAndConnectsThePairedCard() async throws {
        let card = FakeCard(paired: true)
        card.setPhoneBluetooth(.initializing)
        let h = try Harness(card: card, bonds: InMemoryBondStore([card.serial: try #require(card.bondId)]))
        let savedCard = try h.library.upsertDevice(sn: card.serial) { device in
            device.name = "录音卡"
            device.firmware = card.firmware
            device.peripheralId = card.id.uuidString
            device.pairedAt = Date()
        }
        h.session.refreshDevices()
        let model = HomeModel(session: h.session, preferences: h.preferences)
        model.start()

        #expect(model.status == .waiting)
        #expect(model.toast == nil)
        #expect(card.peripheralId == nil)

        card.setPhoneBluetooth(.idle)
        await waitUntil("pending connect") { card.state == .connecting }
        card.advertise()
        await waitUntil("paired card connected") { h.session.connectedDevice?.id == savedCard.id }
        #expect(model.toast == nil)
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
