import Testing
@testable import AIRoute

// Which path transcription and summaries take, and what is asked first (test-spec.md T-M2-52,
// product-spec.md §7.3b).

private let all: [AIPathOption] = [.init(.onDevice), .init(.ownService), .init(.account)]

struct AIRouteTests {
    // MARK: 第一次使用

    @Test func theFirstTranscriptionUsesThisPhone() {
        #expect(AIRoute.decide(.transcribe, in: AISituation(options: all)) == .run(.onDevice))
    }

    @Test func whenThisPhoneCannotTheOtherWaysAreListed() {
        let options: [AIPathOption] = [.init(.onDevice, problem: .unsupported), .init(.account, problem: .signedOut)]
        #expect(AIRoute.decide(.transcribe, in: AISituation(options: options)) == .choose(options, because: .unsupported))
    }

    @Test func theFirstSummaryAsksWhichWayAndListsOnlyWaysThatWriteSummaries() {
        let decision = AIRoute.decide(.summarize, in: AISituation(options: all, hasTranscript: true))
        #expect(decision == .choose([.init(.ownService), .init(.account)], because: nil))
        // A build without a server lists no account.
        let noServer = AIRoute.decide(.summarize, in: AISituation(options: [.init(.ownService, problem: .notConfigured)]))
        #expect(noServer == .choose([.init(.ownService, problem: .notConfigured)], because: nil))
    }

    @Test func pickingTheAccountSignsInFirstAndPickingAnUnsetServiceOpensItsSettings() {
        let options: [AIPathOption] = [.init(.ownService, problem: .notConfigured), .init(.account, problem: .signedOut)]
        let situation = AISituation(options: options, hasTranscript: true)
        #expect(AIRoute.pick(.account, for: .summarize, in: situation) == .signIn)
        #expect(AIRoute.pick(.ownService, for: .summarize, in: situation) == .setUp(.ownService))
        // The phone writes no summaries.
        #expect(AIRoute.pick(.onDevice, for: .summarize, in: situation) == .choose(options, because: .notConfigured))
    }

    // MARK: 默认方式和切换

    @Test func theDefaultIsUsedAndAOneRecordingChoiceWins() {
        let situation = AISituation(options: all, defaultPath: .ownService)
        #expect(AIRoute.decide(.transcribe, in: situation) == .run(.ownService))
        #expect(AIRoute.decide(.transcribe, in: situation, override: .onDevice) == .run(.onDevice))
        #expect(AIRoute.decide(.summarize, in: AISituation(options: all, defaultPath: .ownService, hasTranscript: true))
            == .run(.ownService))
    }

    @Test func aDefaultThatCannotBeUsedNowSaysWhyAndListsTheWays() {
        let offline: [AIPathOption] = [.init(.onDevice), .init(.ownService, problem: .offline), .init(.account, problem: .offline)]
        #expect(AIRoute.decide(.transcribe, in: AISituation(options: offline, defaultPath: .ownService))
            == .choose(offline, because: .offline))
        let signedOut: [AIPathOption] = [.init(.onDevice), .init(.account, problem: .signedOut)]
        #expect(AIRoute.decide(.transcribe, in: AISituation(options: signedOut, defaultPath: .account))
            == .choose(signedOut, because: .signedOut))
        // The user's service lost its transcription model, so it is no longer listed.
        let unlisted: [AIPathOption] = [.init(.onDevice)]
        #expect(AIRoute.decide(.transcribe, in: AISituation(options: unlisted, defaultPath: .ownService))
            == .choose(unlisted, because: .notConfigured))
    }

    @Test func afterAFailureTheOtherWaysAreOffered() {
        let decision = AIRoute.alternatives(to: .onDevice, for: .transcribe, in: AISituation(options: all))
        #expect(decision == .choose([.init(.ownService), .init(.account)], because: nil))
    }

    // MARK: 上传前的确认

    @Test func theAccountAsksOnceBeforeUploadingAudio() {
        let first = AISituation(options: all, defaultPath: .account)
        #expect(AIRoute.decide(.transcribe, in: first) == .confirm(.account, .uploadAudio))
        var agreed = first
        agreed.consents = [.uploadAudio]
        #expect(AIRoute.decide(.transcribe, in: agreed) == .run(.account))
        // Agreeing to send text does not cover the audio.
        agreed.consents = [.sendText]
        #expect(AIRoute.decide(.transcribe, in: agreed) == .confirm(.account, .uploadAudio))
        // The user's service is not asked (the page says where the audio goes, §7.3a).
        #expect(AIRoute.pick(.ownService, for: .transcribe, in: first) == .run(.ownService))
    }

    @Test func aSummaryOfATranscriptAsksOnlyAboutTheText() {
        var situation = AISituation(options: all, defaultPath: .account, hasTranscript: true)
        #expect(AIRoute.decide(.summarize, in: situation) == .confirm(.account, .sendText))
        situation.consents = [.sendText]
        #expect(AIRoute.decide(.summarize, in: situation) == .run(.account))
        // Agreeing to upload the audio named the transcript and summary too.
        situation.consents = [.uploadAudio]
        #expect(AIRoute.decide(.summarize, in: situation) == .run(.account))
        // No transcript yet: the audio would go.
        situation.consents = [.sendText]
        situation.hasTranscript = false
        #expect(AIRoute.decide(.summarize, in: situation) == .confirm(.account, .uploadAudio))
    }

    // MARK: 录完自动整理

    @Test func autoProcessingNeverAsksAndUsesTheAccountOnlyWithItsConsent() {
        #expect(AIRoute.automatic(.transcribe, in: AISituation(options: all)) == .onDevice)
        #expect(AIRoute.automatic(.summarize, in: AISituation(options: all, hasTranscript: true)) == nil)
        let account = AISituation(options: all, defaultPath: .account, consents: [.uploadAudio, .sendText])
        #expect(AIRoute.automatic(.transcribe, in: account) == nil)
        var agreed = account
        agreed.consents = [.autoProcess]
        #expect(AIRoute.automatic(.transcribe, in: agreed) == .account)
        #expect(AIRoute.automatic(.summarize, in: agreed) == .account)
        let unsupported = AISituation(options: [.init(.onDevice, problem: .unsupported), .init(.ownService)])
        #expect(AIRoute.automatic(.transcribe, in: unsupported) == nil)
    }

    @Test func turningAutoProcessingOnAsksOnlyWhenTheAccountIsUsed() {
        #expect(AIRoute.autoProcessNeedsConsent(transcribeDefault: .account, summarizeDefault: .ownService, consents: []))
        #expect(AIRoute.autoProcessNeedsConsent(transcribeDefault: nil, summarizeDefault: .account, consents: [.sendText]))
        #expect(!AIRoute.autoProcessNeedsConsent(transcribeDefault: .account, summarizeDefault: nil, consents: [.autoProcess]))
        #expect(!AIRoute.autoProcessNeedsConsent(transcribeDefault: nil, summarizeDefault: .ownService, consents: []))
    }

    // MARK: 升级

    @Test func anEarlierPhoneKeepsWhatItUsed() {
        #expect(AIRoute.earlierDefaults(onDeviceSwitch: true, ownTranscription: true, ownService: true)
            == (.onDevice, .ownService))
        #expect(AIRoute.earlierDefaults(onDeviceSwitch: false, ownTranscription: true, ownService: true)
            == (.ownService, .ownService))
        #expect(AIRoute.earlierDefaults(onDeviceSwitch: false, ownTranscription: false, ownService: false) == (nil, nil))
    }
}
