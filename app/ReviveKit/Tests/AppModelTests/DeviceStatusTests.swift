import AppModel
import CardLink
import CardProtocol
import CardService
import CardTestSupport
import Foundation
import Library
import Testing

// Device state and recording control on the session (product-spec.md §5, P05).

@MainActor
private func pairedHarness(_ card: FakeCard = FakeCard(paired: true)) async throws -> (Harness, UUID) {
    let h = try Harness(card: card, bonds: InMemoryBondStore([card.serial: card.bondId!]))
    try await h.scanAndSelect()
    await waitUntil("paired") { h.isDone }
    guard case .done(let id) = h.pairing.phase else { throw CancellationError() }
    return (h, id)
}

@MainActor
struct DeviceStatusTests {
    @Test func noDeviceUntilPairedThenIdle() async throws {
        let h = try Harness(card: FakeCard(paired: false))
        #expect(h.session.status(of: nil) == .noDevice)
        try await h.scanAndSelect()
        await waitUntil("paired") { h.isDone }
        let id = try #require(h.preferences.currentDeviceId)
        await waitUntil("idle") { h.session.status(of: id) == .idle }
        #expect(h.session.connectedDevice?.id == id)
    }

    @Test func dropWaitsThenReconnectReadsStatusAgain() async throws {
        let (h, id) = try await pairedHarness()
        await waitUntil("idle") { h.session.status(of: id) == .idle }
        h.card.dropLink()
        await waitUntil("connecting") { h.session.status(of: id) == .connecting }
        #expect(h.session.connectedDevice == nil && h.session.recordingState == nil)
        h.card.advertise()
        await waitUntil("idle again") { h.session.status(of: id) == .idle }
    }

    /// Once the link drops, a card whose stored peripheral id is not the one on the link shows
    /// as waiting, not connecting.
    @Test func unknownCardOnLinkLeavesPairedCardWaiting() async throws {
        let (h, id) = try await pairedHarness()
        await waitUntil("idle") { h.session.status(of: id) == .idle }
        try await h.library.database.writer.write { db in
            try db.execute(sql: "UPDATE device SET peripheral_id = ? WHERE id = ?",
                           arguments: [UUID().uuidString, id])
        }
        h.session.refreshDevices()
        #expect(h.session.status(of: id) == .idle)  // still named by serial
        h.card.dropLink()
        await waitUntil("waiting") { h.session.status(of: id) == .waiting }
    }

    /// Matching by serial: a stored peripheral id from another phone or before a Bluetooth reset
    /// must not stop the card from being recognised and synced.
    @Test func recognisesPairedCardBySerialWhenPeripheralIdChanged() async throws {
        let card = FakeCard(files: [.init(name: "a.opus", content: Data(repeating: 0x08, count: 400))], paired: true)
        let (h, id) = try await pairedHarness(card)
        await waitUntil("stored") { (try? h.library.recordings().count) == 1 }
        await h.session.syncEngine.idle()
        try await h.library.database.writer.write { db in
            try db.execute(sql: "UPDATE device SET peripheral_id = ? WHERE id = ?",
                           arguments: [UUID().uuidString, id])
        }
        h.session.refreshDevices()
        card.files.append(.init(name: "b.opus", content: Data(repeating: 0x08, count: 400)))
        card.dropLink()
        card.advertise()
        await waitUntil("second stored") { (try? h.library.recordings().count) == 2 }
        #expect(h.session.connectedDevice?.id == id)
    }

    /// One 0x80 and one 0xA1 per reconnect: sync waits for the connect routine's 0x80 instead of
    /// reading its own. (Pairing sends 0xA1 twice on purpose: the pairing check, then SyncEngine's
    /// guard against syncing a card bonded to another phone.)
    @Test func reconnectSendsInfoAndBondStatusOnce() async throws {
        let (h, id) = try await pairedHarness()
        await waitUntil("idle") { h.session.status(of: id) == .idle }
        await h.session.syncEngine.idle()
        let info = h.sent(.deviceInfo), bond = h.sent(.bondStatus)
        h.card.dropLink()
        h.card.advertise()
        await waitUntil("idle again") { h.session.status(of: id) == .idle }
        await waitUntil("synced") { h.sent(.listFiles) == 2 }
        await h.session.syncEngine.idle()
        #expect(h.sent(.deviceInfo) - info == 1)
        #expect(h.sent(.bondStatus) - bond == 1)
    }

    @Test func bluetoothOffOverridesEverything() async throws {
        let (h, id) = try await pairedHarness()
        await waitUntil("idle") { h.session.status(of: id) == .idle }
        h.card.setPhoneBluetooth(.poweredOff)
        await waitUntil("unavailable") { h.session.status(of: id) == .bluetoothUnavailable }
        h.card.setPhoneBluetooth(.idle)
        await waitUntil("waiting") { h.session.status(of: id) == .waiting }
    }
}

@MainActor
struct RecordingControlTests {
    @Test func startPauseResumeStopFromTheApp() async throws {
        let (h, id) = try await pairedHarness()
        await waitUntil("idle") { h.session.status(of: id) == .idle }
        await h.session.syncEngine.idle()

        try await h.session.startRecording()
        #expect(h.session.status(of: id) == .recording)
        #expect(h.session.recordedMs == 0)

        h.card.recordedMs = 12_000
        try await h.session.pauseRecording()
        #expect(h.session.status(of: id) == .paused)
        #expect(h.session.recordedMs == 12_000)  // corrected from recd
        let at = try #require(h.session.recordedAt)
        #expect(h.session.recordedMs(at: at.addingTimeInterval(5)) == 12_000)  // stopped while paused

        try await h.session.resumeRecording()
        #expect(h.session.status(of: id) == .recording)
        let resumed = try #require(h.session.recordedAt)
        #expect(h.session.recordedMs(at: resumed.addingTimeInterval(3)) == 15_000)

        try await h.session.stopRecording()
        #expect(h.session.status(of: id) == .idle)
        #expect(h.session.recordedMs == nil)
        await waitUntil("synced after stop") { (try? h.library.recordings().count) == 1 }
        h.checkNoForbiddenWrites()
    }

    @Test func cardButtonUpdatesState() async throws {
        let (h, id) = try await pairedHarness()
        await waitUntil("idle") { h.session.status(of: id) == .idle }
        h.card.pressButtonToRecord()
        await waitUntil("recording") { h.session.status(of: id) == .recording }
        #expect(h.session.recordedMs == 0)
        h.card.pressButtonToStop()
        await waitUntil("idle") { h.session.status(of: id) == .idle }
    }

    /// Reconnecting to a card that is recording shows recording with the card's own count.
    @Test func reconnectWhileRecordingRestoresTimer() async throws {
        let (h, id) = try await pairedHarness()
        await waitUntil("idle") { h.session.status(of: id) == .idle }
        await h.session.syncEngine.idle()
        h.card.pressButtonToRecord()
        await waitUntil("recording") { h.session.status(of: id) == .recording }
        h.card.dropLink()
        h.card.recordedMs = 34_000
        h.card.advertise()
        await waitUntil("recording after reconnect") {
            h.session.status(of: id) == .recording && h.session.recordedMs == 34_000
        }
    }

    @Test func unpairedCardRefusesToRecord() async throws {
        let (h, id) = try await pairedHarness()
        await waitUntil("idle") { h.session.status(of: id) == .idle }
        h.card.bondId = nil
        await #expect(throws: CardServiceError.notPaired) { try await h.session.startRecording() }
        #expect(h.session.status(of: id) == .idle)
    }
}
