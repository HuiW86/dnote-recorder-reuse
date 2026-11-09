import CardLink
import CardProtocol
import CardService
import CardTestSupport
import Foundation
import Testing

// CardService against the fake card (prd.md §2.3, §3; test-spec.md T-M1-10…15).

/// Room for the slow start of a parallel run on CI (every request timed out at 100 ms there).
/// The two tests that wait for a timeout shorten only the timeout they wait for.
private let fastTiming = CardService.Timing(request: .seconds(2), listFiles: .seconds(2),
                                            downloadBytesPerSecond: 1_000_000, downloadSlack: .seconds(2))

@MainActor
private final class EventReader {
    private var buffer: [CardEvent] = []
    private var waiter: CheckedContinuation<CardEvent, Never>?

    init(_ service: CardService) {
        let events = service.events
        Task { [weak self] in
            for await e in events { self?.deliver(e) }
        }
    }

    private func deliver(_ e: CardEvent) {
        if let w = waiter {
            waiter = nil
            w.resume(returning: e)
        } else {
            buffer.append(e)
        }
    }

    func next() async -> CardEvent {
        if !buffer.isEmpty { return buffer.removeFirst() }
        return await withCheckedContinuation { waiter = $0 }
    }

    /// Events up to and including the first one matching `stop`.
    func until(_ stop: (CardEvent) -> Bool) async -> [CardEvent] {
        var out: [CardEvent] = []
        while true {
            let e = await next()
            out.append(e)
            if stop(e) { return out }
        }
    }
}

@MainActor
private func connected(_ card: FakeCard, store: InMemoryBondStore = InMemoryBondStore(),
                       timing: CardService.Timing = fastTiming) async throws -> CardService {
    let service = CardService(link: card, bondStore: store, timing: timing)
    try await service.connect(card.id)
    return service
}

/// CMD bytes written since index `from`.
@MainActor
private func commands(_ card: FakeCard, from: Int = 0) -> [UInt8] {
    card.writtenFrames.dropFirst(from).map { $0[$0.startIndex + 1] }
}

private func isDeviceInfo(_ e: CardEvent) -> Bool {
    if case .deviceInfo = e { true } else { false }
}

@MainActor
struct CardServiceTests {
    // MARK: Connect

    @Test func connectReadsInfoAndSyncsTime() async throws {
        let card = FakeCard()
        let service = try await connected(card)
        #expect(commands(card) == [0x80, 0x87])
        #expect(service.lastInfo?.serial == card.serial)
    }

    @Test func unverifiedFirmwareWarnsButConnects() async throws {
        let card = FakeCard(firmware: "1.60")
        let service = CardService(link: card, bondStore: InMemoryBondStore(), timing: fastTiming)
        let events = EventReader(service)
        let info = try await service.connect(card.id)
        #expect(info.firmware == "1.60")
        let seen = await events.until { if case .firmwareUnverified = $0 { true } else { false } }
        #expect(seen.last == .firmwareUnverified(version: "1.60"))
    }

    @Test func reconnectRunsAfterConnectRoutine() async throws {
        let card = FakeCard()
        let service = try await connected(card)
        let events = EventReader(service)
        card.dropLink()
        _ = await events.until { $0 == .disconnected(.lost) }
        let before = card.writtenFrames.count
        card.advertise()
        _ = await events.until(isDeviceInfo)
        #expect(commands(card, from: before).first == 0x80)
        #expect(service.linkState == .connected)
    }

    // MARK: Requests

    @Test func noResponseIsRequestTimeout() async throws {
        let card = FakeCard()
        let service = try await connected(card, timing: .init(request: .milliseconds(500), listFiles: .seconds(2)))
        card.faults = [.noResponse(.switches)]
        await #expect(throws: CardServiceError.requestTimeout(.switches)) { try await service.switches() }
    }

    @Test func requestWithoutLinkIsDisconnected() async throws {
        let card = FakeCard()
        let service = CardService(link: card, bondStore: InMemoryBondStore(), timing: fastTiming)
        await #expect(throws: CardServiceError.disconnected) { try await service.info() }
    }

    @Test func sameCommandRequestsAreQueued() async throws {
        let card = FakeCard()
        let service = try await connected(card)
        let before = card.writtenFrames.count
        async let a = service.info()
        async let b = service.info()
        async let s = service.switches()
        let (ia, ib, sw) = try await (a, b, s)
        #expect(ia.serial == card.serial && ib.serial == card.serial)
        #expect(sw.gain == card.switches.gain)
        #expect(commands(card, from: before).filter { $0 == 0x80 }.count == 2)
    }

    @Test func setWritesAndReadsBack() async throws {
        let card = FakeCard()
        let service = try await connected(card)
        try await service.set(.gain(7))
        #expect(card.switches.gain == 7)
        #expect(commands(card).suffix(2) == [0x8C, 0x81])
    }

    @Test func setOutOfRangeIsRejectedBeforeSending() async throws {
        let card = FakeCard()
        let service = try await connected(card)
        let before = card.writtenFrames.count
        await #expect(throws: CardServiceError.invalidArgument("level 10")) { try await service.set(.gain(10)) }
        #expect(card.writtenFrames.count == before)
    }

    // MARK: Recording

    @Test func startRecordingOnUnpairedCardIsNotPaired() async throws {
        let card = FakeCard(paired: false)
        let service = try await connected(card)
        await #expect(throws: CardServiceError.notPaired) { try await service.startRecording() }
    }

    @Test func recordingControlRoundTrip() async throws {
        let card = FakeCard()
        let service = try await connected(card)
        let name = try await service.startRecording()
        #expect(name.hasSuffix(".opus"))
        try await service.pause()
        #expect(try await service.recordingStatus().state == .paused)
        try await service.resume()
        #expect(try await service.recordingStatus().state == .recording)
        try await service.stopRecording()
        #expect(try await service.listFiles().map(\.name) == [name])
    }

    // MARK: Events

    @Test func buttonRecordingPushesEvents() async throws {
        let card = FakeCard()
        let service = try await connected(card)
        let events = EventReader(service)
        card.pressButtonToRecord()
        let started = await events.until { if case .recordingStarted = $0 { true } else { false } }
        guard case .recordingStarted(let name) = started.last else { Issue.record("no start"); return }
        card.pressButtonToStop()
        card.pushDeviceInfo()
        let rest = await events.until(isDeviceInfo)
        // 0x56 {rec:0} and 0x55 both arrive; the stop is reported once.
        #expect(rest.filter { $0 == .recordingStopped }.count == 1)
        #expect(card.files.map(\.name) == [name])
    }

    @Test func linkLossIsDisconnectedEvent() async throws {
        let card = FakeCard()
        let service = try await connected(card)
        let events = EventReader(service)
        card.dropLink()
        let seen = await events.until { if case .disconnected = $0 { true } else { false } }
        #expect(seen.last == .disconnected(.lost))
    }

    // MARK: Files

    /// #38 E: an unpaired card still lists files, so the list says nothing about pairing.
    @Test func listFilesOnUnpairedCardStillLists() async throws {
        let card = FakeCard(files: [.init(name: "a.opus", content: Data(count: 10))], paired: false)
        let service = try await connected(card)
        #expect(try await service.listFiles().map(\.name) == ["a.opus"])
        #expect(try await !service.isPairedWithThisPhone())
    }

    /// A list that never ends is a timeout, not "not paired".
    @Test func listTimeoutIsRequestTimeout() async throws {
        let card = FakeCard(files: [.init(name: "a.opus", content: Data(count: 10))])
        let service = try await connected(card, timing: .init(request: .seconds(2), listFiles: .milliseconds(100)))
        card.faults = [.noResponse(.listFiles)]
        await #expect(throws: CardServiceError.requestTimeout(.listFiles)) { try await service.listFiles() }
    }

    /// #38: a bare 0x40 reply to 0x70.
    @Test func refusedDownloadIsCardBusy() async throws {
        let card = FakeCard(files: [.init(name: "a.opus", content: Data(count: 500))])
        let service = try await connected(card)
        card.faults = [.refuseDownloads]
        await #expect(throws: CardServiceError.cardBusy) {
            _ = try await service.download(CardFile(name: "a.opus", size: 500))
        }
    }

    @Test func listFilesWhileRecordingIsBusy() async throws {
        let card = FakeCard(files: [.init(name: "a.opus", content: Data(count: 10))])
        let service = try await connected(card)
        _ = try await service.startRecording()
        await #expect(throws: CardServiceError.cardBusyRecording) { try await service.listFiles() }
    }

    @Test func emptyIdleCardListsNothing() async throws {
        let service = try await connected(FakeCard())
        #expect(try await service.listFiles().isEmpty)
    }

    @Test func downloadWholeAndFromOffset() async throws {
        let content = Data((0..<1234).map { UInt8($0 % 251) })
        let card = FakeCard(files: [.init(name: "a.opus", content: content)])
        let service = try await connected(card)
        let file = try #require(try await service.listFiles().first)
        #expect(file.size == content.count)
        #expect(try await service.download(file) == content)
        #expect(try await service.download(file, from: 777) == content.dropFirst(777))
        #expect(try await service.download(file, from: content.count).isEmpty)
    }

    @Test func downloadResumesAfterDrop() async throws {
        let content = Data((0..<2000).map { UInt8($0 % 241) })
        let card = FakeCard(files: [.init(name: "a.opus", content: content)])
        let service = try await connected(card)
        let file = CardFile(name: "a.opus", size: content.count)
        card.faults = [.disconnectAfterChunks(4)]
        var partial = Data()
        await #expect(throws: CardServiceError.disconnected) {
            try await service.download(file) { partial.append($0) }
        }
        #expect(partial == content.prefix(4 * card.chunkSize))

        let events = EventReader(service)
        card.advertise()
        _ = await events.until(isDeviceInfo)
        let rest = try await service.download(file, from: partial.count)
        #expect(partial + rest == content)
    }

    @Test(arguments: [(UInt8(0x40), CardServiceError.transferFailed), (0x30, .transferFailed)])
    func downloadErrorStatus(status: UInt8, expected: CardServiceError) async throws {
        let card = FakeCard(files: [.init(name: "a.opus", content: Data(count: 1000))])
        let service = try await connected(card)
        card.faults = [.chunkStatus(index: 2, status: status)]
        await #expect(throws: expected) { _ = try await service.download(CardFile(name: "a.opus", size: 1000)) }
    }

    @Test func downloadMissingFileIsNotFound() async throws {
        let service = try await connected(FakeCard())
        await #expect(throws: CardServiceError.fileNotFound) {
            _ = try await service.download(CardFile(name: "gone.opus", size: 10))
        }
    }

    @Test func downloadTruncatedChunkFails() async throws {
        let card = FakeCard(files: [.init(name: "a.opus", content: Data(count: 1000))])
        let service = try await connected(card)
        card.faults = [.truncatedChunk(index: 1)]
        await #expect(throws: CardServiceError.transferFailed) {
            _ = try await service.download(CardFile(name: "a.opus", size: 1000))
        }
    }

    @Test func downloadOutOfOrderChunksFail() async throws {
        let card = FakeCard(files: [.init(name: "a.opus", content: Data(count: 1000))])
        let service = try await connected(card)
        card.faults = [.reorderNotifications]
        await #expect(throws: CardServiceError.transferFailed) {
            _ = try await service.download(CardFile(name: "a.opus", size: 1000))
        }
    }

    @Test func downloadSizeMismatchFails() async throws {
        let card = FakeCard(files: [.init(name: "a.opus", content: Data(count: 1000))])
        let service = try await connected(card)
        await #expect(throws: CardServiceError.transferFailed) {
            _ = try await service.download(CardFile(name: "a.opus", size: 1200))
        }
    }

    @Test func deleteRemovesFile() async throws {
        let card = FakeCard(files: [.init(name: "a.opus", content: Data(count: 10))])
        let service = try await connected(card)
        try await service.delete("a.opus")
        #expect(try await service.listFiles().isEmpty)
    }
}

// MARK: - Pairing (test-spec.md T-M1-10…15)

@MainActor
struct PairingTests {
    static let forbidden: Set<UInt8> = [0x93, 0x94, 0xB0, 0xB1, 0x89]

    /// T-M1-10
    @Test func newCardPairsInOrder() async throws {
        let card = FakeCard(paired: false)
        let store = InMemoryBondStore()
        let service = try await connected(card, store: store)
        let before = card.writtenFrames.count
        let bondId = try await service.pair { Issue.record("no prompt for a new card"); return false }
        #expect(commands(card, from: before) == [0x80, 0xA1, 0x87, 0xA2, 0xA0, 0xA1])
        #expect(bondId.count == 16)
        #expect(card.bondId == bondId)
        #expect(store.bonds[card.serial] == bondId)
        #expect(card.encryptionKey == AudioCrypto.deviceKey(serial: card.serial))
        #expect(try await service.isPairedWithThisPhone())
    }

    /// #38 D: 0xA2 must be acked; a refusal stops before any bond write.
    @Test func rejectedEncryptionKeyFailsBeforeBonding() async throws {
        let card = FakeCard(paired: false)
        let store = InMemoryBondStore()
        let service = try await connected(card, store: store)
        card.faults = [.rejectEncryptionKey]
        let before = card.writtenFrames.count
        await #expect(throws: CardServiceError.unexpectedReply(.setEncryptionKey)) {
            _ = try await service.pair { true }
        }
        #expect(commands(card, from: before) == [0x80, 0xA1, 0x87, 0xA2])
        #expect(card.bondId == nil)
        #expect(store.bonds.isEmpty)
    }

    /// T-M1-11
    @Test func alreadyPairedCardIsLeftAlone() async throws {
        let card = FakeCard()
        let store = InMemoryBondStore([card.serial: card.bondId!])
        let service = try await connected(card, store: store)
        let before = card.writtenFrames.count
        let bondId = try await service.pair { Issue.record("no prompt for our own card"); return false }
        #expect(bondId == card.bondId)
        #expect(commands(card, from: before) == [0x80, 0xA1])
    }

    /// T-M1-12, declined: only queries go out.
    @Test func foreignBondDeclinedWritesNothing() async throws {
        let card = FakeCard()
        let foreign = card.bondId
        let store = InMemoryBondStore()
        let service = try await connected(card, store: store)
        let before = card.writtenFrames.count
        var asked = false
        await #expect(throws: CardServiceError.pairCancelled) {
            _ = try await service.pair { asked = true; return false }
        }
        #expect(asked)
        #expect(commands(card, from: before) == [0x80, 0xA1])
        #expect(card.bondId == foreign)
        #expect(store.bonds.isEmpty)
    }

    /// T-M1-12, confirmed: unbond before bond; recordings survive.
    @Test func foreignBondConfirmedRebinds() async throws {
        let card = FakeCard(files: [.init(name: "a.opus", content: Data(count: 10))])
        let foreign = card.bondId
        let store = InMemoryBondStore()
        let service = try await connected(card, store: store)
        let before = card.writtenFrames.count
        let bondId = try await service.pair { true }
        #expect(commands(card, from: before) == [0x80, 0xA1, 0x87, 0xA2, 0xA0, 0xA0, 0xA1])
        let bondWrites = card.sentRequests.filter { $0.command == .bond }
        #expect(bondWrites == [.unbond, .bond(bondId: bondId)])
        #expect(bondId != foreign && card.bondId == bondId && store.bonds[card.serial] == bondId)
        #expect(card.files.count == 1)
    }

    /// T-M1-13
    @Test func mismatchedBondStatusIsVerifyFailed() async throws {
        let card = FakeCard(paired: false)
        let store = InMemoryBondStore()
        let service = try await connected(card, store: store)
        card.faults = [.ignoreBondWrites]
        await #expect(throws: CardServiceError.pairVerifyFailed) { _ = try await service.pair { true } }
        #expect(store.bonds.isEmpty)
    }

    /// T-M1-14: no forbidden command in any pairing path above or here.
    @Test func pairingNeverSendsForbiddenCommands() async throws {
        let card = FakeCard()
        let store = InMemoryBondStore()
        let service = try await connected(card, store: store)
        _ = try await service.pair { true }
        try await service.unpair()
        _ = try await service.pair { true }
        #expect(card.wroteOnlyWhitelistedCommands)
        #expect(Set(commands(card)).isDisjoint(with: Self.forbidden))
    }

    /// T-M1-15
    @Test func unpairClearsBondKeepsFiles() async throws {
        let card = FakeCard(files: [.init(name: "a.opus", content: Data(count: 10))])
        let store = InMemoryBondStore([card.serial: card.bondId!])
        let service = try await connected(card, store: store)
        let before = card.writtenFrames.count
        try await service.unpair()
        #expect(card.sentRequests.dropFirst(before).filter { $0.command == .bond } == [.unbond])
        #expect(commands(card, from: before) == [0xA0, 0xA1])
        #expect(card.bondId == nil)
        #expect(store.bonds.isEmpty)
        #expect(card.files.count == 1)
    }

    @Test func unpairNotTakingEffectIsVerifyFailed() async throws {
        let card = FakeCard()
        let store = InMemoryBondStore([card.serial: card.bondId!])
        let service = try await connected(card, store: store)
        card.faults = [.ignoreBondWrites]
        await #expect(throws: CardServiceError.pairVerifyFailed) { try await service.unpair() }
        #expect(store.bonds[card.serial] != nil)
    }
}
