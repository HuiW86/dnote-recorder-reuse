import CardLink
import CardProtocol
@testable import CardService
import CardTestSupport
import DeviceSource
import Foundation
import Testing

// The D·NOTE card as SyncEngine's device (ADR-010): what CardSyncSource hands over, and how card
// errors and events reach SyncEngine. SyncEngineTests run every sync case through it end to end.

private let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("CardProtocolTests/Fixtures")

private func fixture(_ name: String) throws -> Data {
    try Data(contentsOf: fixtures.appendingPathComponent(name))
}

/// See CardServiceTests: patient, since a reply that arrives returns at once.
private let patientTiming = CardService.Timing(request: .seconds(30), listFiles: .seconds(30),
                                               downloadBytesPerSecond: 1_000_000, downloadSlack: .seconds(30))

@MainActor
private func connectedSource(_ card: FakeCard) async throws -> CardSyncSource {
    let service = CardService(link: card, bondStore: InMemoryBondStore([card.serial: card.bondId!]),
                              timing: patientTiming)
    try await service.connect(card.id)
    return CardSyncSource(service)
}

@MainActor
struct CardSyncSourceTests {
    /// Each card error lands on the SourceError that keeps its old sync failure code (prd.md §6).
    @Test func cardErrorsMapToSourceErrors() {
        let expected: [(CardServiceError, SourceError)] = [
            (.notPaired, .notPaired),
            (.cardBusyRecording, .busyRecording),
            (.cardBusy, .busy),
            (.fileNotFound, .fileNotFound),
            (.transferFailed, .transferFailed),
            (.requestTimeout(.fileData), .requestTimeout),
            (.unexpectedReply(.listFiles), .unexpectedReply),
            (.disconnected, .disconnected),
            (.bluetoothOff, .disconnected),
            (.bluetoothUnauthorized, .disconnected),
            (.bluetoothUnsupported, .disconnected),
            (.connectTimeout, .disconnected),
            (.connectFailed, .disconnected),
            (.unknownCard, .disconnected),
            (.pairVerifyFailed, .other),
            (.pairCancelled, .other),
            (.invalidArgument("x"), .other),
            (.bondStorageFailed, .other),
        ]
        for (card, source) in expected {
            #expect(SourceError(card) == source, "\(card)")
        }
    }

    @Test func onlyConnectAndStopStartASync() {
        #expect(CardEvent.stateChanged(.connected).sourceEvent == .connected)
        #expect(CardEvent.recordingStopped.sourceEvent == .recordingStopped)
        #expect(CardEvent.stateChanged(.connecting).sourceEvent == nil)
        #expect(CardEvent.disconnected(.lost).sourceEvent == nil)
        #expect(CardEvent.recordingStarted(name: "20261107140211.opus").sourceEvent == nil)
        #expect(CardEvent.firmwareUnverified(version: "1.60").sourceEvent == nil)
    }

    /// Same bytes as before the converter moved out of SyncEngine (make_fixtures.py).
    @Test func converterDecryptsAndWrapsInOgg() throws {
        let plain = try fixture("plain.bin")
        let expected = try fixture("expected_ogg.bin")
        let audio = try CardAudioConverter().convert(try fixture("encrypted.bin"))
        #expect(audio.ogg == expected)
        #expect(audio.durationMs == plain.count / 40 * 20)
        #expect(try CardAudioConverter().convert(plain).ogg == audio.ogg)
    }

    @Test func startDateComesFromTheFileName() {
        let source = CardSyncSource(CardService(link: FakeCard(), bondStore: InMemoryBondStore()))
        let date = source.startDate(of: SourceFile(name: "20261107140211.opus", size: 1))
        #expect(date == CardFile.startDate(fileName: "20261107140211.opus"))
        #expect(date != nil)
        #expect(source.startDate(of: SourceFile(name: "notes.opus", size: 1)) == nil)
        #expect(source.defaultDeviceName == "录音卡")
    }

    @Test func handsOverTheCardsFilesAndState() async throws {
        let content = Data((0..<500).map { UInt8($0 % 251) })
        let card = FakeCard(files: [.init(name: "20261107140211.opus", content: content)])
        let source = try await connectedSource(card)
        #expect(source.isConnected)
        #expect(source.connectionId == card.id)

        let info = try await source.deviceInfo()
        #expect(info.serial == card.serial)
        #expect(info.firmware == card.firmware)
        #expect(try await source.isPairedWithThisPhone())
        #expect(try await !source.isRecording())

        let files = try await source.listFiles()
        #expect(files == [SourceFile(name: "20261107140211.opus", size: content.count)])
        var received = Data()
        try await source.download(files[0], from: 100) { received.append($0) }
        #expect(received == content.dropFirst(100))

        card.pressButtonToRecord()
        #expect(try await source.isRecording())
        await #expect(throws: SourceError.busyRecording) { try await source.listFiles() }

        card.dropLink()
        #expect(!source.isConnected)
    }

    @Test func missingFileIsASourceError() async throws {
        let source = try await connectedSource(FakeCard())
        await #expect(throws: SourceError.fileNotFound) {
            try await source.download(SourceFile(name: "gone.opus", size: 10), from: 0) { _ in }
        }
    }
}
