import AppModel
import CardLink
import CardProtocol
import CardService
import CardTestSupport
import Foundation
import Library
import Testing

// P07 device page against the fake card (product-spec.md P07, §5.3).

@MainActor
private func connectedDevice(_ card: FakeCard = FakeCard(paired: true)) async throws -> (Harness, DeviceModel) {
    let h = try Harness(card: card, bonds: InMemoryBondStore([card.serial: card.bondId!]))
    try await h.scanAndSelect()
    await waitUntil("paired") { h.isDone }
    guard case .done(let id) = h.pairing.phase else { throw CancellationError() }
    await h.firstSyncDone()
    let model = DeviceModel(session: h.session, preferences: h.preferences, deviceId: id)
    await waitUntil("connected") { model.isConnected }
    return (h, model)
}

@MainActor
struct DeviceModelTests {
    @Test func showsMaskedSerialAndReadsSettings() async throws {
        let (h, model) = try await connectedDevice()
        #expect(model.maskedSerial == "···0001")
        #expect(!model.firmwareUnverified)
        await model.load()
        #expect(model.switches == h.card.switches)
        #expect(!model.switchesFailed)
    }

    @Test func settingIsSentAndConfirmed() async throws {
        let (h, model) = try await connectedDevice()
        await model.load()
        model.set(.autoOff(seconds: 600))
        #expect(model.pending == [.autoOff])
        #expect(model.switches?.autoOffSeconds == 600)
        await waitUntil("sent") { model.pending.isEmpty }
        #expect(h.card.switches.autoOffSeconds == 600)
        #expect(model.toast == nil)
        h.checkNoForbiddenWrites()
    }

    /// The read-back disagrees twice (one automatic retry): the switch goes back with a Toast.
    @Test func failedSettingGoesBackWithToast() async throws {
        let (h, model) = try await connectedDevice()
        await model.load()
        let before = try #require(model.switches?.vad)
        h.card.faults = [.ignoreSettings]
        model.set(.vad(!before))
        await waitUntil("failed") { model.pending.isEmpty }
        #expect(model.switches?.vad == before)
        #expect(model.toast?.text == "设置失败，请重试")
        #expect(h.sent(.setVAD) == 2)
    }

    @Test func notConnectedHidesSettings() async throws {
        let (h, model) = try await connectedDevice()
        h.card.advertising = false
        h.card.dropLink()
        await waitUntil("waiting") { model.status == .waiting }
        await model.load()
        #expect(model.switches == nil)
        #expect(model.battery == nil && model.freeSpaceMb == nil)
        #expect(model.unpairBlockedReason == "请先连接录音卡")
    }

    /// "断开连接": no pending connect, also when home appears again, until pull to refresh.
    @Test func disconnectStaysUntilPullToRefresh() async throws {
        let (h, model) = try await connectedDevice()
        let home = HomeModel(session: h.session, preferences: h.preferences)
        home.start()
        model.disconnect()
        await waitUntil("waiting") { model.status == .waiting }
        home.start()  // P05 appears again
        h.card.advertise()
        try await Task.sleep(for: .milliseconds(50))
        #expect(model.status == .waiting)
        await home.refresh()
        #expect(home.toast == nil)
        h.card.advertise()
        await waitUntil("connected again") { model.status == .idle }
        home.stop()
    }

    @Test func unpairKeepsRecordingsAndCardAdvertisesAgain() async throws {
        let card = FakeCard(files: [.init(name: "20261101090000.opus", content: Data(repeating: 0x08, count: 400))],
                            paired: true)
        let (h, model) = try await connectedDevice(card)
        await waitUntil("synced") { (try? h.library.recordings().count) == 1 }
        await h.session.syncEngine.idle()
        let id = model.deviceId
        h.preferences.setDeleteAfterSync(true, for: id)
        #expect(model.unpairBlockedReason == nil)
        #expect(await model.unpair())
        #expect(h.card.bondId == nil)
        #expect(h.session.pairedDevices.isEmpty)
        #expect(try h.library.recordings().count == 1)
        #expect(card.files.count == 1)
        #expect(h.preferences.currentDeviceId == nil)
        #expect(!h.preferences.deleteAfterSync(for: id))
        await waitUntil("dropped") { h.session.linkState == .disconnected(.requested) }
        h.checkNoForbiddenWrites()
    }

    @Test func unpairBlockedWhileRecording() async throws {
        let (h, model) = try await connectedDevice()
        try await h.session.startRecording()
        #expect(model.unpairBlockedReason == "请先停止录音")
        #expect(await model.unpair() == false)
        #expect(h.card.bondId != nil)
    }

    @Test func deleteAfterSyncIsPerCard() async throws {
        let (h, model) = try await connectedDevice()
        h.session.deleteAfterSync = { [preferences = h.preferences] in preferences.deleteAfterSync(for: $0) }
        #expect(!model.deleteAfterSync)
        model.setDeleteAfterSync(true)
        #expect(model.deleteAfterSync)
        #expect(h.session.syncEngine.options.deleteAfterSync)
        #expect(!h.preferences.deleteAfterSync(for: UUID()))
        model.setDeleteAfterSync(false)
        #expect(!h.session.syncEngine.options.deleteAfterSync)
    }

    @Test func renameIsLocal() async throws {
        let (h, model) = try await connectedDevice()
        model.rename("  会议室卡 ")
        #expect(model.device?.name == "会议室卡")
        #expect(h.card.sentRequests.allSatisfy { if case .set = $0 { false } else { true } })
    }

    /// A card left on the link unpaired does not advertise: scanning drops it first.
    @Test func scanDropsUnpairedCardOnLink() async throws {
        let (h, model) = try await connectedDevice()
        try h.library.markUnpaired(id: model.deviceId)
        h.session.refreshDevices()
        #expect(h.session.connectedDevice == nil)
        #expect(h.session.linkState == .connected)
        h.pairing.scan()
        await waitUntil("dropped") { h.session.linkState != .connected }
        await waitUntil("listed") { !h.pairing.candidates.isEmpty }
    }
}
