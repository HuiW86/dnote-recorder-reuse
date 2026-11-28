import AIRoute
import AppModel
import CardProtocol
import CardTestSupport
import Foundation
import Library
import Player
import SyncEngine
import Testing
import Transcription

// P06 with the three AI paths (product-spec.md §7.3b, test-spec.md T-M2-52): the main buttons go
// the way AIRoute decides, ask first where it says so, and the phone's failure offers the others.

@MainActor
private final class PathFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("paths-\(UUID().uuidString)")
    let library: RecordingLibrary
    let player: RecordingPlayer
    let recording: Recording
    let preferences = Preferences(defaults: UserDefaults(suiteName: "paths-\(UUID().uuidString)")!)
    /// Which paths were asked to transcribe.
    var used: [AIPath] = []
    var onDevice: Result<[TranscriptSegment], TranscriptionError> = .success([TranscriptSegment(startMs: 0, text: "本机")])
    var signedIn = true
    var supported = true

    init() async throws {
        library = RecordingLibrary(database: try AppDatabase.inMemory(), store: try AudioStore(root: root))
        player = RecordingPlayer(library: library)
        let frames = try SyntheticOpus.sine(seconds: 1)
        let data = OggOpus.wrap(frames)
        let id = UUID()
        let path = try library.store.storeAudio(data, id: id)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let r = Recording(id: id, deviceId: nil, source: .card, cardFileName: "20261107140211.opus",
                          cardFileSize: data.count, startedAt: start, durationMs: frames.count * 20,
                          audioPath: path, audioSha256: "", title: "t", createdAt: start, updatedAt: start)
        try await library.database.writer.write { try r.insert($0) }
        recording = r
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    func model() -> RecordingDetailModel {
        let paths = AIPaths(
            situation: { [unowned self] work, hasTranscript in
                AccountAI.situation(for: work, preferences: preferences, onDeviceSupported: supported,
                                    ownTranscription: false, ownService: false, accountSignedIn: signedIn,
                                    hasTranscript: hasTranscript)
            },
            transcriber: { [unowned self] path in
                PathTranscriber(path: path, result: path == .onDevice ? onDevice
                                    : .success([TranscriptSegment(startMs: 0, text: path.rawValue)])) { [unowned self] in
                    used.append($0)
                }
            },
            preferences: preferences)
        return RecordingDetailModel(recordingId: recording.id, library: library, player: player, paths: paths)
    }
}

private struct PathTranscriber: SpeechTranscribing {
    let path: AIPath
    let result: Result<[TranscriptSegment], TranscriptionError>
    let called: @Sendable @MainActor (AIPath) -> Void
    var engineName: String { path.rawValue }
    var usesNetwork: Bool { path != .onDevice }

    func transcribe(_ recording: Recording, language: String) async throws -> [TranscriptSegment] {
        await called(path)
        return try result.get()
    }
}

@MainActor
struct AIPathPageTests {
    @Test func firstTranscriptionUsesThePhoneWithoutASwitch() async throws {
        let f = try await PathFixture()
        let model = f.model()
        #expect(model.canTranscribe && model.choosesPaths)
        model.transcribe()
        await waitUntil("transcribed") { model.transcript != nil && !model.isTranscribing }
        #expect(f.used == [.onDevice] && model.aiPrompt == nil)
    }

    @Test func thePhonesFailureOffersTheOtherWays() async throws {
        let f = try await PathFixture()
        f.onDevice = .failure(.unsupportedLanguage)
        let model = f.model()
        model.transcribe()
        await waitUntil("prompt") { model.aiPrompt != nil }
        #expect(model.aiPrompt == .choose(.transcribe, [AIPathOption(.account)], because: .unsupported, remember: false))

        // The account asks before the audio goes up; agreeing keeps it and goes ahead.
        model.pick(.account)
        await waitUntil("confirm") { model.aiPrompt != nil }
        #expect(model.aiPrompt == .confirm(.transcribe, .account, .uploadAudio))
        model.agree()
        await waitUntil("transcribed") { model.transcript != nil && !model.isTranscribing }
        #expect(f.used == [.onDevice, .account] && f.preferences.aiConsents == [.uploadAudio])
        #expect(model.transcript?.segments.first?.text == "account")
    }

    @Test func aPickForOneRecordingIsNotTheDefault() async throws {
        let f = try await PathFixture()
        f.preferences.grant(.uploadAudio)
        let model = f.model()
        model.chooseTranscriptionPath()
        await waitUntil("list") { model.aiPrompt != nil }
        model.pick(.account)
        await waitUntil("transcribed") { model.transcript != nil && !model.isTranscribing }
        #expect(f.used == [.account] && f.preferences.defaultTranscriptionPath == nil)
        // The main button on this page keeps the pick.
        model.transcribe()
        await waitUntil("again") { f.used.count == 2 && !model.isTranscribing }
        #expect(f.used == [.account, .account])
    }

    @Test func signedOutAccountPointsToSignIn() async throws {
        let f = try await PathFixture()
        f.signedIn = false
        f.preferences.defaultTranscriptionPath = .account
        let model = f.model()
        model.transcribe()
        await waitUntil("prompt") { model.aiPrompt != nil }
        // The default cannot be used now: the list says why.
        #expect(model.aiPrompt == .choose(.transcribe, [AIPathOption(.onDevice), AIPathOption(.account, problem: .signedOut)],
                                          because: .signedOut, remember: false))
        model.pick(.account)
        await waitUntil("sign in") { model.aiPrompt == .signIn }
        #expect(f.used.isEmpty)
    }

    @Test func firstSummaryAsksAndRemembersTheWay() async throws {
        let f = try await PathFixture()
        let model = f.model()
        model.transcribe()
        await waitUntil("transcribed") { model.transcript != nil && !model.isTranscribing }
        #expect(model.canSummarize && model.summaryHint == nil)
        model.summarize()
        await waitUntil("list") { model.aiPrompt != nil }
        #expect(model.aiPrompt == .choose(.summarize, [AIPathOption(.ownService, problem: .notConfigured), AIPathOption(.account)],
                                          because: nil, remember: true))
        model.pick(.account)
        #expect(f.preferences.defaultSummaryPath == .account)
        // Only text goes: the text confirmation, not the upload one.
        await waitUntil("confirm") { model.aiPrompt != nil }
        #expect(model.aiPrompt == .confirm(.summarize, .account, .sendText))
    }
}
