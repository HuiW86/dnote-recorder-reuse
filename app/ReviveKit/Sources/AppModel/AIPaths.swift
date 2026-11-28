import Account
import AIRoute
import Assistant
import Foundation
import Library
import Transcription

// What the recording page needs to take one of the three AI paths (product-spec.md §7.3b): what
// each path can do now, the transcriber behind each, the account's summary, and where consents
// and remembered ways are kept. The app builds one (AppEnvironment); tests build stand-ins.

public struct AIPaths {
    /// What each path can do right now for this work. Async: whether the account is signed in
    /// is read from its session.
    public var situation: @MainActor (_ work: AIWork, _ hasTranscript: Bool) async -> AISituation
    /// The transcriber behind a path; nil when the path cannot transcribe in this build.
    public var transcriber: @MainActor (AIPath) -> (any SpeechTranscribing)?
    /// 生成纪要 with the 闻笺 account, from the stored transcript; nil in a build without a server.
    public var accountSummary: (@MainActor (Recording, Transcript, RecordingScene?) async throws -> Summary)?
    public var preferences: Preferences

    public init(situation: @escaping @MainActor (AIWork, Bool) async -> AISituation,
                transcriber: @escaping @MainActor (AIPath) -> (any SpeechTranscribing)?,
                accountSummary: (@MainActor (Recording, Transcript, RecordingScene?) async throws -> Summary)? = nil,
                preferences: Preferences) {
        self.situation = situation
        self.transcriber = transcriber
        self.accountSummary = accountSummary
        self.preferences = preferences
    }
}

/// What the recording page shows before AI work goes ahead (§7.3b), from an `AIRouteDecision`.
public enum AIPrompt: Equatable, Identifiable, Sendable {
    /// List these ways; `because` says why the usual one cannot be used (nil: no way chosen yet,
    /// or the user asked for the list). `remember` keeps the pick as the default (the first
    /// summary); a pick from 「选择转写方式」 is for this recording only.
    case choose(AIWork, [AIPathOption], because: AIPathProblem?, remember: Bool)
    /// Say what leaves the phone; on agreement keep the consent and go ahead.
    case confirm(AIWork, AIPath, AIConsent)
    /// The 闻笺 account was chosen but nobody is signed in: open 设置 › 账号.
    case signIn
    /// The user's AI service was chosen but is not set up: open 设置 › AI 服务.
    case setUp

    public var id: String {
        switch self {
        case let .choose(work, _, _, _): "choose-\(work)"
        case let .confirm(work, path, _): "confirm-\(work)-\(path.rawValue)"
        case .signIn: "sign-in"
        case .setUp: "set-up"
        }
    }

    /// The sheet's title.
    public var title: String {
        switch self {
        case .choose(.transcribe, _, _, _): "选择转写方式"
        case .choose(.summarize, _, _, _): "选择纪要方式"
        case .confirm(_, _, .uploadAudio): "上传录音到闻笺"
        case .confirm(_, _, .sendText): "发送文字稿到闻笺"
        case .confirm(_, _, .autoProcess): "开启录完自动整理"
        case .signIn: "先登录闻笺账号"
        case .setUp: "先设置你的 AI 服务"
        }
    }
}

extension AIWork: CustomStringConvertible {
    public var description: String { self == .transcribe ? "transcribe" : "summarize" }
}

/// What each path does with the recording, shown under its name in the list (§7.3b: say where
/// the recording goes before it goes).
public extension AIPath {
    func detail(for work: AIWork) -> String {
        switch (self, work) {
        case (.onDevice, _): "在这部手机上离线转写，录音不离开手机"
        case (.ownService, .transcribe): "录音会上传到你设置的 AI 服务"
        case (.ownService, .summarize): "只发送文字稿给你设置的 AI 服务"
        case (.account, .transcribe): "录音会上传到闻笺服务器"
        case (.account, .summarize): "只发送文字稿到闻笺服务器"
        }
    }
}

extension TranscriptionError {
    /// 本机转写失败 in a way another path may get past (§7.3b): not for a missing file, which
    /// no path can transcribe.
    var offersOtherPaths: Bool {
        switch self {
        case .permissionDenied, .unsupportedLanguage, .noSpeech, .failed: true
        case .audioMissing: false
        }
    }

    /// The reason the list gives for leaving this phone.
    var problem: AIPathProblem? { self == .unsupportedLanguage ? .unsupported : nil }
}

public extension AIPaths {
    /// The app's paths: this phone, the user's service (its transcription model for 转成文字),
    /// and the 闻笺 account when the build names a server (`account` non-nil).
    @MainActor
    static func app(preferences: Preferences, library: RecordingLibrary, assistant: AssistantConfigSource,
                    account: AccountSession?,
                    onDeviceSupported: @escaping @MainActor () -> Bool = { OnDeviceTranscriber.isSupported() }) -> AIPaths {
        let situation: @MainActor (AIWork, Bool) async -> AISituation = { work, hasTranscript in
            var signedIn: Bool?
            if let account {
                let user = await account.user
                signedIn = await account.isSignedIn
                // §7.3b: what was agreed to holds for that sign-in only. A sign-in that ended on
                // its own, or another account, asks again.
                preferences.keepAIConsents(for: signedIn == true ? user?.id : nil)
            }
            let ownTranscription = TranscriberChoice.cloudConfig(preferences: preferences, assistant: assistant) != nil
            return AccountAI.situation(for: work, preferences: preferences, onDeviceSupported: onDeviceSupported(),
                                       ownTranscription: ownTranscription, ownService: assistant.current() != nil,
                                       accountSignedIn: signedIn, hasTranscript: hasTranscript)
        }
        let transcriber: @MainActor (AIPath) -> (any SpeechTranscribing)? = { path in
            switch path {
            case .onDevice:
                return OnDeviceTranscriber(library: library)
            case .ownService:
                guard let config = TranscriberChoice.cloudConfig(preferences: preferences, assistant: assistant) else {
                    return nil
                }
                return CloudTranscriber(library: library, config: config)
            case .account:
                guard let account else { return nil }
                return AccountTranscriber(library: library, session: account)
            }
        }
        var accountSummary: (@MainActor (Recording, Transcript, RecordingScene?) async throws -> Summary)?
        if let account {
            accountSummary = { recording, transcript, scene in
                try await AccountAI.summarize(recording, transcript: transcript, scene: scene?.rawValue,
                                              profession: preferences.assistantProfession,
                                              session: account, library: library)
            }
        }
        return AIPaths(situation: situation, transcriber: transcriber, accountSummary: accountSummary,
                       preferences: preferences)
    }
}
