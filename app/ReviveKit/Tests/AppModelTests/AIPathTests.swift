import Account
import AIRoute
import Foundation
import Library
import Testing
@testable import AppModel

// The app's side of the three AI paths (test-spec.md T-M2-52, product-spec.md §7.3b): the two
// defaults and three confirmations in settings, what each path can do now, and the 闻笺 account's
// answers in the library's shapes.

@MainActor
struct AIPathTests {
    private func preferences() -> Preferences {
        let suite = "AIPathTests.\(UUID().uuidString)"
        return Preferences(defaults: UserDefaults(suiteName: suite)!)
    }

    @Test func defaultsAndConsentsAreKeptApart() {
        let preferences = preferences()
        #expect(preferences.defaultTranscriptionPath == nil && preferences.defaultSummaryPath == nil)
        preferences.defaultTranscriptionPath = .account
        preferences.defaultSummaryPath = .ownService
        #expect(preferences.defaultTranscriptionPath == .account && preferences.defaultSummaryPath == .ownService)
        // The phone writes no summaries.
        preferences.defaultSummaryPath = .onDevice
        #expect(preferences.defaultSummaryPath == nil)

        preferences.grant(.sendText)
        #expect(preferences.aiConsents == [.sendText])
        preferences.grant(.uploadAudio)
        #expect(preferences.aiConsents == [.sendText, .uploadAudio])
        preferences.forgetAIConsents()
        #expect(preferences.aiConsents.isEmpty)
        // The defaults stay: they are not about the account.
        #expect(preferences.defaultTranscriptionPath == .account)
    }

    /// §7.3b: a consent holds for the sign-in it was given in; another account, or a sign-in
    /// that ran out without 退出登录, asks again.
    @Test func consentsBelongToOneAccount() {
        let preferences = preferences()
        let a = UUID(), b = UUID()
        preferences.keepAIConsents(for: a)
        preferences.grant(.uploadAudio)
        preferences.keepAIConsents(for: a)
        #expect(preferences.aiConsents == [.uploadAudio])
        preferences.keepAIConsents(for: b)
        #expect(preferences.aiConsents.isEmpty)
        preferences.grant(.sendText)
        preferences.keepAIConsents(for: nil)
        #expect(preferences.aiConsents.isEmpty)
    }

    @Test func anEarlierPhoneKeepsItsWaysOnce() {
        let earlier = preferences()
        earlier.adoptEarlierAIDefaults(ownTranscription: true, ownService: true)
        #expect(earlier.defaultTranscriptionPath == .ownService && earlier.defaultSummaryPath == .ownService)

        let switchOn = preferences()
        switchOn.onDeviceTranscriptEnabled = true
        switchOn.adoptEarlierAIDefaults(ownTranscription: true, ownService: false)
        #expect(switchOn.defaultTranscriptionPath == .onDevice && switchOn.defaultSummaryPath == nil)

        // A new phone keeps no default, and setting up a service later does not make one.
        let new = preferences()
        new.adoptEarlierAIDefaults(ownTranscription: false, ownService: false)
        new.adoptEarlierAIDefaults(ownTranscription: true, ownService: true)
        #expect(new.defaultTranscriptionPath == nil && new.defaultSummaryPath == nil)
    }

    @Test func eachPathSaysWhatStopsIt() {
        let preferences = preferences()
        let transcribe = AccountAI.situation(for: .transcribe, preferences: preferences, onDeviceSupported: false,
                                             ownTranscription: false, ownService: true, accountSignedIn: false,
                                             hasTranscript: false)
        #expect(transcribe.options == [AIPathOption(.onDevice, problem: .unsupported), AIPathOption(.account, problem: .signedOut)])
        let summarize = AccountAI.situation(for: .summarize, preferences: preferences, onDeviceSupported: true,
                                            ownTranscription: false, ownService: false, accountSignedIn: nil,
                                            hasTranscript: true)
        #expect(summarize.options == [AIPathOption(.ownService, problem: .notConfigured)] && summarize.hasTranscript)

        preferences.defaultSummaryPath = .account
        preferences.grant(.sendText)
        let ready = AccountAI.situation(for: .summarize, preferences: preferences, onDeviceSupported: true,
                                        ownTranscription: true, ownService: true, accountSignedIn: true,
                                        hasTranscript: true)
        #expect(ready.options == [AIPathOption(.ownService), AIPathOption(.account)])
        #expect(ready.defaultPath == .account && ready.consents == [.sendText])
        #expect(AIRoute.decide(.summarize, in: ready) == .run(.account))
    }

    @Test func theAccountsAnswersTakeTheLibrarysShapes() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let remote = try decoder.decode(RemoteSummary.self, from: Data(#"{"id":"0c1d2e3f-0000-4000-8000-0000000000cc","recording_id":"0c1d2e3f-0000-4000-8000-0000000000aa","scene":"meeting","title":"周会","summary":"定了上线时间","sections":[{"heading":"决定","items":["周五上线"]}],"todos":["写发布说明"],"tags":["发布"],"people":["王老师"],"outline":[{"title":"上线","points":["周五"]}],"quotes":["先上再说"],"model":"stand-in","created_at":"2026-11-27T15:00:00+00:00"}"#.utf8))
        let id = UUID()
        let created = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(AccountAI.summary(remote, recordingId: id, now: created) == Summary(
            recordingId: id, scene: "meeting", title: "周会", summary: "定了上线时间",
            sections: [SummarySection(heading: "决定", items: ["周五上线"])], todos: [SummaryTodo(text: "写发布说明")],
            tags: ["发布"], people: ["王老师"], outline: [OutlineItem(title: "上线", points: ["周五"])],
            quotes: ["先上再说"], model: "stand-in", createdAt: created))

        let transcript = try decoder.decode(RemoteTranscript.self, from: Data(#"{"recording_id":"0c1d2e3f-0000-4000-8000-0000000000aa","language":"zh","segments":[{"start_ms":1500,"end_ms":3000,"speaker":null,"text":"开始吧"},{"start_ms":0,"end_ms":1500,"speaker":"S1","text":"大家好"}],"speakers":{},"asr_provider":"stand-in","created_at":"2026-11-27T15:00:00+00:00","updated_at":"2026-11-27T15:00:00+00:00"}"#.utf8))
        #expect(AccountAI.segments(transcript) == [TranscriptSegment(startMs: 0, text: "大家好"),
                                                   TranscriptSegment(startMs: 1_500, text: "开始吧")])

        #expect(AccountAI.contentType(audioPath: "audio/x.ogg") == "audio/ogg")
        #expect(AccountAI.contentType(audioPath: "audio/x.M4A") == "audio/mp4")
        #expect(AccountAI.sha256(Data("abc".utf8)) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(AccountAI.source(.realtime) == .card && AccountAI.source(.phone) == .phone)
    }

    /// The account flows keep server ids in the library's table.
    @Test func serverIdsLiveInTheLibrary() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ids-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let library = RecordingLibrary(database: try AppDatabase.inMemory(), store: try AudioStore(root: root))
        let recording = try #require(try library.addTextRecording(text: "周会\n定了上线时间", title: "周会", startedAt: Date()))
        let ids = LibraryServerIds(library: library)
        let account = UUID()
        let server = ServerRecordingId(id: UUID(), hasAudio: false)
        #expect(try await ids.serverId(local: recording.id, account: account) == nil)
        try await ids.keep(server, local: recording.id, account: account)
        #expect(try await ids.serverId(local: recording.id, account: account) == server)
        try await ids.forget(local: recording.id, account: account)
        #expect(try await ids.serverId(local: recording.id, account: account) == nil)
    }

    /// Signing out forgets the confirmations; deleting the account also its server ids.
    @Test func leavingTheAccountForgetsWhatWasKeptForIt() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("leave-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let library = RecordingLibrary(database: try AppDatabase.inMemory(), store: try AudioStore(root: root))
        let recording = try #require(try library.addTextRecording(text: "周会", title: "周会", startedAt: Date()))
        let account = UUID()
        try library.saveServerRecordingLink(ServerRecordingLink(accountId: account, recordingId: recording.id,
                                                                serverId: UUID(), hasAudio: false))
        let preferences = preferences()
        preferences.defaultSummaryPath = .account
        preferences.grant(.uploadAudio)
        preferences.grant(.autoProcess)

        AccountAI.leave(account, deleted: false, preferences: preferences, library: library)
        #expect(preferences.aiConsents.isEmpty && preferences.defaultSummaryPath == .account)
        #expect(try library.serverRecordingLink(recordingId: recording.id, accountId: account) != nil)

        preferences.grant(.sendText)
        AccountAI.leave(account, deleted: true, preferences: preferences, library: library)
        #expect(preferences.aiConsents.isEmpty)
        #expect(try library.serverRecordingLink(recordingId: recording.id, accountId: account) == nil)
    }
}
