import Foundation
import Testing
import CardLink
import CardProtocol
import CardTestSupport

// The fake card must behave like the v1.50 card as recorded in evidence/ (test-spec.md §2).
// Every test ends by checking that only whitelisted commands were written (§3.5 gate 2).
@MainActor
struct FakeCardTests {
    let file = FakeCard.StoredFile(name: "20261106080407.opus", content: Data((0..<1050).map { UInt8($0 % 251) }))

    private func connected(_ card: FakeCard) async throws -> LinkEventReader {
        let reader = LinkEventReader(card)
        try await card.connect(card.id)
        #expect(await reader.nextState() == .connecting)
        #expect(await reader.nextState() == .connected)
        return reader
    }

    /// Sends a sentinel `0x80` push and returns the frames that arrived before it.
    private func framesUntilSentinel(_ card: FakeCard, _ reader: LinkEventReader) async -> [Frame] {
        card.pushDeviceInfo()
        var frames: [Frame] = []
        while let f = await reader.nextFrame(), f.command != .deviceInfo { frames.append(f) }
        return frames
    }

    @Test func scanFindsCardWithAdvertisement() async throws {
        let card = FakeCard(firmware: "1.51")
        let reader = LinkEventReader(card)
        card.startScan()
        guard case .discovered(let found) = await reader.next() else { Issue.record("no discovery"); return }
        #expect(found.id == card.id)
        #expect(found.advertisement.firmware == "1.51")
        #expect(Firmware.check(found.advertisement.firmware) == .unverified(version: "1.51"))
    }

    @Test func sendFailsWhenNotConnected() async {
        let card = FakeCard()
        await #expect(throws: LinkError.notConnected) { try await card.send(.deviceInfo) }
        await #expect(throws: LinkError.unknownPeripheral) { try await card.connect(UUID()) }
    }

    @Test func queriesAndSettings() async throws {
        let card = FakeCard()
        let reader = try await connected(card)

        try await card.send(.deviceInfo)
        let info = try #require(DeviceInfo.parse(try await reader.frame()))
        #expect(info.serial == card.serial && info.firmware == "1.50" && info.recordingState == .idle)

        try await card.send(.set(.gain(7)))
        #expect(await reader.nextFrame()?.isAck == true)
        try await card.send(.switches)
        let switches = try #require(DeviceSwitches.parse(try await reader.frame()))
        #expect(switches.reflects(.gain(7)))
        #expect(card.wroteOnlyWhitelistedCommands)
    }

    @Test func pairingInTheSameConnection() async throws {
        let card = FakeCard(paired: false)
        let reader = try await connected(card)
        let bondId = Data(repeating: 0x5A, count: 16)

        try await card.send(.setEncryptionKey(enabled: true, key: AudioCrypto.deviceKey(serial: card.serial)))
        #expect(await reader.nextFrame()?.isAck == true)
        try await card.send(.bond(bondId: bondId))
        #expect(await reader.nextFrame()?.isAck == true)
        try await card.send(.bondStatus)
        #expect(BondStatus.parse(try await reader.frame()) == BondStatus(isBonded: true, bondId: bondId))
        #expect(card.wroteOnlyWhitelistedCommands)
    }

    @Test func unpairedCardRefusesRecordingAndIgnoresList() async throws {
        let card = FakeCard(files: [file], paired: false)
        let reader = try await connected(card)

        try await card.send(.startRecording)
        #expect(StartRecordingReply.parse(try await reader.frame()) == .notPaired)
        try await card.send(.listFiles)
        #expect(await framesUntilSentinel(card, reader).isEmpty, "0x90 gets no response when unpaired")
        #expect(card.wroteOnlyWhitelistedCommands)
    }

    @Test func listIsEmptyWhileRecording() async throws {
        let card = FakeCard(files: [file])
        let reader = try await connected(card)

        try await card.send(.listFiles)
        let idle = await framesUntilSentinel(card, reader).compactMap(FileListMessage.parse)
        #expect(idle == [.file(CardFile(name: file.name, size: 1050)), .end])

        try await card.send(.startRecording)
        guard case .started(let name) = StartRecordingReply.parse(try await reader.frame()) else {
            Issue.record("recording did not start"); return
        }
        try await card.send(.listFiles)
        #expect(await framesUntilSentinel(card, reader).compactMap(FileListMessage.parse) == [.end])

        try await card.send(.pauseRecording)
        #expect(await reader.nextFrame()?.isAck == true)
        try await card.send(.recordingStatus)
        #expect(RecordingStatus.parse(try await reader.frame())?.state == .paused)

        // Stop: ack, then 0x56 {rec:0} and an empty 0x55 (PROTOCOL.md §4.3).
        try await card.send(.stopRecording)
        let stop = await framesUntilSentinel(card, reader)
        #expect(stop.map(\.cmd) == [0x50, 0x56, 0x55])
        #expect(RecordingStatus.parse(stop[1])?.state == .idle)
        #expect(card.files.map(\.name).contains(name))
        #expect(card.wroteOnlyWhitelistedCommands)
    }

    @Test func buttonPushes() async throws {
        let card = FakeCard()
        let reader = try await connected(card)
        card.pressButtonToRecord()
        let started = try await reader.frame()
        #expect(started.push == .recordingStarted && recordingStartedName(started) != nil)
        card.pressButtonToStop()
        #expect(await reader.nextFrame()?.command == .recordingStatus)
        #expect(await reader.nextFrame()?.push == .recordingStopped)
    }

    @Test func downloadAndResumeFromAnyOffset() async throws {
        let card = FakeCard(files: [file])
        let reader = try await connected(card)

        try await card.send(.download(name: file.name, offset: 0))
        let full = await reader.chunks().compactMap { $0 }
        #expect(full.map(\.offset) == [0, 200, 400, 600, 800, 1000])
        #expect(full.last?.status == .eof)
        #expect(full.reduce(Data()) { $0 + $1.data } == file.content)

        try await card.send(.download(name: file.name, offset: 333))
        let tail = await reader.chunks().compactMap { $0 }
        #expect(tail.first?.offset == 333)
        #expect(tail.reduce(Data()) { $0 + $1.data } == file.content.dropFirst(333))
        #expect(card.wroteOnlyWhitelistedCommands)
    }

    @Test func missingFileReportsNotFound() async throws {
        let card = FakeCard()
        let reader = try await connected(card)
        try await card.send(.download(name: "nope.opus", offset: 0))
        #expect(await reader.chunks().map { $0?.status } == [.notFound])
    }

    @Test func disconnectMidDownloadThenPendingReconnectAndResume() async throws {
        let card = FakeCard(files: [file])
        let reader = try await connected(card)
        card.faults = [.disconnectAfterChunks(3)]

        try await card.send(.download(name: file.name, offset: 0))
        var received = Data()
        while let event = await reader.next() {
            if case .notification(let d) = event, let f = Frame.parse(d), let c = FileChunk.parse(f) {
                received += c.data
            }
            if case .state(.disconnected(.lost)) = event { break }
        }
        #expect(received.count == 600)
        #expect(await reader.nextState() == .connecting, "pending connect registered")
        await #expect(throws: LinkError.notConnected) { try await card.send(.listFiles) }

        card.advertise()
        #expect(await reader.nextState() == .connected)
        try await card.send(.download(name: file.name, offset: received.count))
        received += await reader.chunks().compactMap { $0 }.reduce(Data()) { $0 + $1.data }
        #expect(received == file.content)
        #expect(card.wroteOnlyWhitelistedCommands)
    }

    @Test func requestedDisconnectDoesNotReconnect() async throws {
        let card = FakeCard()
        let reader = try await connected(card)
        card.disconnect()
        #expect(await reader.nextState() == .disconnected(.requested))
        card.advertise()
        #expect(card.state == .disconnected(.requested))
    }

    @Test(arguments: [(0x40 as UInt8, FileChunk.Status.error), (0xF0, .notFound), (0x30, .cancelled)])
    func chunkStatusFaults(status: UInt8, expected: FileChunk.Status) async throws {
        let card = FakeCard(files: [file])
        let reader = try await connected(card)
        card.faults = [.chunkStatus(index: 2, status: status)]
        try await card.send(.download(name: file.name, offset: 0))
        #expect(await reader.chunks().map { $0?.status } == [.data, .data, expected])
    }

    @Test func truncatedChunkFault() async throws {
        let card = FakeCard(files: [file])
        let reader = try await connected(card)
        card.faults = [.truncatedChunk(index: 1)]
        try await card.send(.download(name: file.name, offset: 0))
        let chunks = await reader.chunks()
        #expect(chunks.count == 2 && chunks[0]?.status == .data && chunks[1] == nil)
    }

    @Test func noResponseFault() async throws {
        let card = FakeCard()
        let reader = try await connected(card)
        card.faults = [.noResponse(.bondStatus)]
        try await card.send(.bondStatus)
        #expect(await framesUntilSentinel(card, reader).isEmpty)
    }

    @Test func reorderFault() async throws {
        let card = FakeCard(files: [file])
        let reader = try await connected(card)
        card.faults = [.reorderNotifications]
        try await card.send(.download(name: file.name, offset: 0))
        var offsets: [UInt32] = []
        for _ in 0..<6 {
            let chunk = FileChunk.parse(try await reader.frame())
            offsets.append(try #require(chunk).offset)
        }
        #expect(offsets == [200, 0, 600, 400, 1000, 800])
    }
}

// Replays real-card logs and checks the protocol layer decodes them (test-spec.md §2).
@MainActor
struct EvidenceReplayTests {
    private func replayed(_ path: String) async throws -> [Frame] {
        let url = EvidenceLog.repositoryRoot.appendingPathComponent(path)
        let notifications = try EvidenceLog.notifications(at: url)
        #expect(!notifications.isEmpty)
        let card = FakeCard()
        let reader = LinkEventReader(card)
        card.replay(notifications)
        var frames: [Frame] = []
        for _ in notifications { frames.append(try await reader.frame()) }
        return frames
    }

    @Test func liveSessionDeviceInfo() async throws {
        let frames = try await replayed("evidence/v1-live/20261106-034450-51-10s-run1/notify.jsonl")
        let info = try #require(frames.lazy.compactMap(DeviceInfo.parse).first)
        #expect(info.firmware == "1.50")
        #expect(Firmware.check(info.firmware) == .verified)
    }

    @Test func pauseResumeSession() async throws {
        let frames = try await replayed("evidence/v34-device-check/pause.jsonl")
        let states = frames.compactMap(RecordingStatus.parse).map(\.state)
        #expect(states.contains(.recording) && states.contains(.paused) && states.contains(.idle))
        let started = frames.compactMap(StartRecordingReply.parse)
        #expect(!started.isEmpty)
        let controlAcks = frames.filter { [0x50, 0x52, 0x53].contains($0.cmd) }
        #expect(!controlAcks.isEmpty && controlAcks.allSatisfy(\.isAck))
    }

    @Test func switchesSession() async throws {
        let frames = try await replayed("evidence/v34-device-check/switches.jsonl")
        #expect(!frames.compactMap(DeviceSwitches.parse).isEmpty)
        let setAcks = frames.filter { (0x83...0x8F).contains($0.cmd) }
        #expect(!setAcks.isEmpty && setAcks.allSatisfy(\.isAck))
    }
}
