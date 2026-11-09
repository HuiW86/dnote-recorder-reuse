import AppModel
import CardLink
import CardProtocol
import CardService
import CardTestSupport
import Foundation
import Library
import SyncEngine
import Testing

// First-use flow against the fake card (product-spec.md §3.1, P01–P03).

// No test here waits for a request to time out; the margin keeps tests that briefly hold the
// main actor (player setup) from failing unrelated requests when suites run in parallel.
let fastTiming = CardService.Timing(request: .seconds(2), listFiles: .seconds(2),
                                            downloadBytesPerSecond: 1_000_000, downloadSlack: .milliseconds(500))
let syncOptions = SyncEngine.Options(retryDelays: [.seconds(60), .seconds(60), .seconds(60)],
                                             recordingStoppedDelay: .milliseconds(10), spaceMargin: 0)

@MainActor
func waitUntil(_ what: String, timeout: Duration = .seconds(3),
                       _ condition: () throws -> Bool) async rethrows {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if try condition() { return }
        try? await Task.sleep(for: .milliseconds(5))
    }
    Issue.record("timed out waiting for \(what)")
}

@MainActor
final class Harness {
    let card: FakeCard
    let bonds: InMemoryBondStore
    let library: RecordingLibrary
    let session: CardSession
    let preferences = Preferences(defaults: UserDefaults(suiteName: "test-\(UUID().uuidString)")!)
    let pairing: PairingModel
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("appmodel-\(UUID().uuidString)")

    init(card: FakeCard = FakeCard(paired: false), bonds: InMemoryBondStore = InMemoryBondStore(),
         scanTimeout: Duration = .seconds(5), diagnostics: DiagnosticLog? = nil,
         bondStore: (any BondStore)? = nil) throws {
        self.card = card
        self.bonds = bonds
        library = RecordingLibrary(database: try AppDatabase.inMemory(), store: try AudioStore(root: root))
        session = try CardSession(link: card, bondStore: bondStore ?? bonds, library: library, timing: fastTiming,
                                  syncOptions: syncOptions, diagnostics: diagnostics)
        pairing = PairingModel(session: session, preferences: preferences, scanTimeout: scanTimeout)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    func sent(_ command: Command) -> Int { card.sentRequests.filter { $0.command == command }.count }

    func checkNoForbiddenWrites() {
        #expect(card.wroteOnlyWhitelistedCommands)
        let cmds = Set(card.writtenFrames.map { $0[$0.startIndex + 1] })
        #expect(cmds.isDisjoint(with: [0x93, 0x94, 0xB0, 0xB1]))
    }

    func scanAndSelect() async throws {
        pairing.start()
        await waitUntil("card listed") { !pairing.candidates.isEmpty }
        pairing.select(try #require(pairing.candidates.first))
    }

    /// The first pass after pairing has listed the card and finished. The session shows the card
    /// as idle from its 0x80 before that pass starts, so waiting for idle is not enough.
    func firstSyncDone() async {
        await waitUntil("first sync") { sent(.listFiles) >= 1 && !session.syncEngine.isRunning }
    }

    var isDone: Bool {
        if case .done = pairing.phase { true } else { false }
    }
}

@MainActor
struct PairingModelTests {
    @Test func listsCardsWithSuffixAndFirmwareWarning() async throws {
        let card = FakeCard(firmware: "1.62", paired: false)
        let h = try Harness(card: card)
        h.pairing.start()
        await waitUntil("card listed") { !h.pairing.candidates.isEmpty }
        let c = try #require(h.pairing.candidates.first)
        #expect(c.displayName == "录音卡 ·· 0001")
        #expect(c.firmware == "1.62" && c.firmwareUnverified)
        #expect(c.battery == 80)
        #expect(!c.displayName.contains("D·NOTE"))
        #expect(h.pairing.phase == .scanning)
    }

    @Test func nothingFoundAfterTimeoutThenRetryFinds() async throws {
        let h = try Harness(scanTimeout: .milliseconds(50))
        h.card.advertising = false
        h.pairing.start()
        await waitUntil("not found") { h.pairing.phase == .notFound }
        h.card.advertising = true
        h.pairing.scan()
        await waitUntil("card listed") { !h.pairing.candidates.isEmpty }
        #expect(h.pairing.phase == .scanning)
    }

    /// A new card: connect → read → pair → saved as current device → first sync.
    @Test func pairsNewCardThenSyncs() async throws {
        let card = FakeCard(files: [.init(name: "20261101090000.opus", content: Data(repeating: 0x08, count: 400))],
                            paired: false)
        let h = try Harness(card: card)
        try await h.scanAndSelect()
        await waitUntil("paired") { h.isDone }
        guard case .done(let deviceId) = h.pairing.phase else { return }

        #expect(card.bondId != nil && h.bonds.bonds[card.serial] == card.bondId)
        let devices = try h.library.pairedDevices()
        #expect(devices.map(\.id) == [deviceId])
        #expect(devices.first?.name == "录音卡 ·· 0001")
        #expect(devices.first?.peripheralId == card.id.uuidString)
        #expect(h.preferences.currentDeviceId == deviceId)

        await waitUntil("first recording stored") { (try? h.library.recordings().count) == 1 }
        #expect(h.session.linkState == .connected)
        h.checkNoForbiddenWrites()
    }

    @Test func cardPairedWithThisPhoneIsNotPairedAgain() async throws {
        let card = FakeCard(paired: true)
        let h = try Harness(card: card, bonds: InMemoryBondStore([card.serial: card.bondId!]))
        try await h.scanAndSelect()
        await waitUntil("done") { h.isDone }
        #expect(h.sent(.bond) == 0 && h.sent(.setEncryptionKey) == 0)
        #expect(try h.library.pairedDevices().count == 1)
        h.checkNoForbiddenWrites()
    }

    /// Bonded to another phone: nothing is written until the user agrees.
    @Test func rebindDeclinedLeavesCardAlone() async throws {
        let card = FakeCard(paired: true)
        let other = card.bondId
        let h = try Harness(card: card)
        try await h.scanAndSelect()
        await waitUntil("asked") { h.pairing.rebindPending }
        h.pairing.answerRebind(false)
        await waitUntil("back to list") { h.pairing.phase == .scanning }
        #expect(card.bondId == other)
        #expect(h.sent(.bond) == 0)
        #expect(try h.library.pairedDevices().isEmpty)
        #expect(h.preferences.currentDeviceId == nil)
        h.checkNoForbiddenWrites()
    }

    @Test func rebindAcceptedPairs() async throws {
        let card = FakeCard(paired: true)
        let other = card.bondId
        let h = try Harness(card: card)
        try await h.scanAndSelect()
        await waitUntil("asked") { h.pairing.rebindPending }
        h.pairing.answerRebind(true)
        await waitUntil("done") { h.isDone }
        #expect(card.bondId != other && h.bonds.bonds[card.serial] == card.bondId)
        h.checkNoForbiddenWrites()
    }

    @Test func connectTimeoutShowsStepErrorAndRetryWorks() async throws {
        let h = try Harness()
        h.pairing.start()
        await waitUntil("card listed") { !h.pairing.candidates.isEmpty }
        h.card.advertising = false  // the card went back to sleep
        h.pairing.select(try #require(h.pairing.candidates.first))
        await waitUntil("failed") { h.pairing.phase == .failed(.connecting, .connectTimeout) }
        #expect(CardServiceError.connectTimeout.userText == "连接超时。按住卡上的录音键，白灯闪烁后重试")

        h.card.advertising = true
        h.pairing.retry()
        await waitUntil("done") { h.isDone }
        h.checkNoForbiddenWrites()
    }

    @Test func pairVerifyFailureIsReportedOnPairingStep() async throws {
        let h = try Harness()
        h.card.faults = [.ignoreBondWrites]
        try await h.scanAndSelect()
        await waitUntil("failed") { h.pairing.phase == .failed(.pairing, .pairVerifyFailed) }
        #expect(try h.library.pairedDevices().isEmpty)
        await waitUntil("link dropped") { h.session.linkState != .connected }
        h.checkNoForbiddenWrites()
    }

    @Test func bluetoothOffThenOnResumesScan() async throws {
        let h = try Harness()
        h.card.advertising = false
        h.pairing.start()
        h.card.setPhoneBluetooth(.poweredOff)
        await waitUntil("problem shown") { h.pairing.bluetoothProblem == .bluetoothOff }
        h.card.advertising = true
        h.card.setPhoneBluetooth(.idle)
        await waitUntil("card listed") { !h.pairing.candidates.isEmpty }
        #expect(h.pairing.bluetoothProblem == nil)
    }

    /// A double tap (or tapping 重试 twice) must not run two pairings that write two bondIds.
    @Test func secondTapWhilePairingIsIgnored() async throws {
        let h = try Harness()
        h.pairing.start()
        await waitUntil("card listed") { !h.pairing.candidates.isEmpty }
        let card = try #require(h.pairing.candidates.first)
        h.pairing.select(card)
        #expect(h.pairing.phase == .working(.connecting))
        h.pairing.select(card)
        h.pairing.retry()
        h.pairing.scan()
        await waitUntil("done") { h.isDone }
        #expect(h.sent(.bond) == 1)
        #expect(h.bonds.bonds[h.card.serial] == h.card.bondId)
        h.checkNoForbiddenWrites()
    }

    @Test func leavingThePageDropsAnUnfinishedLink() async throws {
        let card = FakeCard(paired: true)
        let h = try Harness(card: card)
        try await h.scanAndSelect()
        await waitUntil("asked") { h.pairing.rebindPending }
        h.pairing.stop()
        await waitUntil("disconnected") { h.session.linkState == .disconnected(.requested) }
        #expect(h.sent(.bond) == 0)
    }
}

@MainActor
struct CardSessionTests {
    /// An unpaired card must not be synced on connect: its 0x90 would only time out.
    @Test func doesNotSyncUnknownCardOnConnect() async throws {
        let h = try Harness()
        try await h.session.service.connect(h.card.id)
        try await Task.sleep(for: .milliseconds(100))
        #expect(h.sent(.listFiles) == 0)
    }

    @Test func syncsPairedCardOnReconnect() async throws {
        let card = FakeCard(files: [.init(name: "a.opus", content: Data(repeating: 0x08, count: 400))], paired: true)
        let h = try Harness(card: card, bonds: InMemoryBondStore([card.serial: card.bondId!]))
        try await h.scanAndSelect()
        await waitUntil("done") { h.isDone }
        await waitUntil("stored") { (try? h.library.recordings().count) == 1 }
        card.files.append(.init(name: "b.opus", content: Data(repeating: 0x08, count: 400)))
        card.dropLink()
        card.advertise()
        await waitUntil("second stored") { (try? h.library.recordings().count) == 2 }
        h.checkNoForbiddenWrites()
    }
}

extension CardSessionTests {
    /// The DEBUG card screen turns auto-sync off so its evidence logs stay clean.
    @Test func autoSyncOffSkipsReconnectSync() async throws {
        let card = FakeCard(files: [.init(name: "a.opus", content: Data(repeating: 0x08, count: 400))], paired: true)
        let h = try Harness(card: card, bonds: InMemoryBondStore([card.serial: card.bondId!]))
        try await h.scanAndSelect()
        await waitUntil("done") { h.isDone }
        await waitUntil("stored") { (try? h.library.recordings().count) == 1 }
        await h.session.syncEngine.idle()
        h.session.autoSyncEnabled = false
        let lists = h.sent(.listFiles)
        card.dropLink()
        card.advertise()
        await waitUntil("reconnected") { h.session.linkState == .connected }
        try await Task.sleep(for: .milliseconds(100))
        #expect(h.sent(.listFiles) == lists)
    }
}

@MainActor
struct OnboardingModelTests {
    /// Bluetooth already on: answering the prompt need not change the link state at all.
    @Test func proceedsWithoutAnyStateEvent() async throws {
        let h = try Harness()
        var auth = BluetoothAuthorization.notDetermined
        let model = OnboardingModel(authorization: { auth }, startBluetooth: { h.session })
        model.continueTapped()
        #expect(model.phase == .requesting)
        auth = .allowed
        await waitUntil("proceed") { model.phase == .proceed }
    }

    @Test func asksOnlyAfterContinueThenProceeds() async throws {
        let h = try Harness()
        var auth = BluetoothAuthorization.notDetermined
        var started = 0
        let model = OnboardingModel(authorization: { auth }, startBluetooth: { started += 1; return h.session })
        #expect(model.phase == .intro && started == 0)
        model.continueTapped()
        #expect(model.phase == .requesting && started == 1)
        auth = .allowed
        h.card.setPhoneBluetooth(.connecting)  // any state report after the prompt is answered
        await waitUntil("proceed") { model.phase == .proceed }
    }

    @Test func deniedShowsErrorUntilAllowedInSettings() async throws {
        let h = try Harness()
        var auth = BluetoothAuthorization.notDetermined
        let model = OnboardingModel(authorization: { auth }, startBluetooth: { h.session })
        model.continueTapped()
        auth = .denied
        h.card.setPhoneBluetooth(.unauthorized)
        await waitUntil("denied") { model.phase == .denied }
        #expect(CardServiceError.bluetoothUnauthorized.userText == "需要蓝牙权限才能连接录音卡")
        auth = .allowed
        model.refresh()  // back from Settings
        #expect(model.phase == .proceed)
    }

    @Test func alreadyAllowedGoesStraightOn() throws {
        let h = try Harness()
        let model = OnboardingModel(authorization: { .allowed }, startBluetooth: { h.session })
        model.continueTapped()
        #expect(model.phase == .proceed)
    }
}
