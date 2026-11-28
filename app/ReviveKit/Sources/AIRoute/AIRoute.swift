// Which of the three AI paths a transcription or a summary takes, and what to ask first
// (product-spec.md §7.3b, ADR-009). Rules only: the app works out what each path can do right
// now (AISituation) and shows what the decision says. Foundation only and offline, like the M1
// modules (scripts/check-m1-rules.sh); it never sends anything itself.

import Foundation

/// The three ways to get AI work done (ADR-009).
public enum AIPath: String, CaseIterable, Codable, Identifiable, Sendable {
    /// Speech recognition on this phone; transcription only, nothing leaves the phone.
    case onDevice = "on-device"
    /// The service the user configured (features.md X11).
    case ownService = "own-service"
    /// Our backend, with the 闻笺 account (K1); only in builds that name a server.
    case account

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .onDevice: "本机"
        case .ownService: "你的 AI 服务"
        case .account: "闻笺账号"
        }
    }
}

public enum AIWork: Sendable {
    case transcribe
    case summarize

    /// The paths that can do this work: the phone cannot write summaries.
    public var paths: [AIPath] {
        switch self {
        case .transcribe: [.onDevice, .ownService, .account]
        case .summarize: [.ownService, .account]
        }
    }
}

/// Why a path cannot be used right now (§7.3b 就地说明原因).
public enum AIPathProblem: Equatable, Sendable {
    /// This phone cannot recognize this recording's language offline.
    case unsupported
    /// The user's service has no address, key or model for this work.
    case notConfigured
    case signedOut
    case offline

    public var reason: String {
        switch self {
        case .unsupported: "这台手机不能离线识别这条录音的语言"
        case .notConfigured: "还没有设置你的 AI 服务"
        case .signedOut: "还没有登录闻笺账号"
        case .offline: "现在没有网络"
        }
    }
}

/// A path the phone lists for the work, and what stops it now (nil when it can be used).
public struct AIPathOption: Equatable, Sendable {
    public var path: AIPath
    public var problem: AIPathProblem?

    public init(_ path: AIPath, problem: AIPathProblem? = nil) {
        self.path = path
        self.problem = problem
    }
}

/// What the user agreed to before the 闻笺 account is sent anything (§7.3b 上传前的确认). Each
/// is asked once and kept on the phone until the account signs out or is deleted.
public enum AIConsent: String, CaseIterable, Codable, Sendable {
    /// The recording's audio goes to the server, which keeps it with its transcript and summary.
    case uploadAudio
    /// Only a transcript goes to the server, to write a summary.
    case sendText
    /// 录完自动整理 may send new recordings without asking each time.
    case autoProcess

    /// What the confirmation says, above its button.
    public var message: String {
        switch self {
        case .uploadAudio:
            "录音会发到闻笺的服务器。服务器保留录音、文字稿和纪要，可以在闻笺账号里删除；注销账号会全部删除。"
        case .sendText: "将文字稿发送到闻笺服务生成纪要。录音不会上传。"
        case .autoProcess: "开启后，符合条件的新录音会自动上传到闻笺并整理。"
        }
    }

    public var button: String {
        switch self {
        case .uploadAudio: "同意并上传"
        case .sendText: "同意并发送"
        case .autoProcess: "同意并开启"
        }
    }
}

/// What the app knows when the user asks for the work.
public struct AISituation: Equatable, Sendable {
    /// The paths this phone lists for the work, in order. A path the phone does not list is left
    /// out: the user's service for transcription without a transcription model, the account in a
    /// build without a server.
    public var options: [AIPathOption]
    /// The way the user chose for this work (P09 默认转写方式 / 默认纪要方式); nil when never chosen.
    public var defaultPath: AIPath?
    public var consents: Set<AIConsent>
    /// The recording has a transcript, so a summary sends only text.
    public var hasTranscript: Bool

    public init(options: [AIPathOption], defaultPath: AIPath? = nil, consents: Set<AIConsent> = [],
                hasTranscript: Bool = false) {
        self.options = options
        self.defaultPath = defaultPath
        self.consents = consents
        self.hasTranscript = hasTranscript
    }

    func option(_ path: AIPath) -> AIPathOption? { options.first { $0.path == path } }
}

public enum AIRouteDecision: Equatable, Sendable {
    /// Go ahead with this path.
    case run(AIPath)
    /// Show this confirmation; on agreement keep the consent and run the path.
    case confirm(AIPath, AIConsent)
    /// The account was chosen but nobody is signed in: sign in first, then decide again.
    case signIn
    /// The user's service was chosen but is not set up: open its settings.
    case setUp(AIPath)
    /// Let the user choose among these, saying why when the usual path cannot be used (nil the
    /// first time a summary is made, when no way was chosen yet).
    case choose([AIPathOption], because: AIPathProblem?)
}

public enum AIRoute {
    /// The main button: 转成文字 or 生成纪要. `override` is the way picked for this one recording
    /// (P06 ⋯ → 选择转写方式), which wins over the default.
    public static func decide(_ work: AIWork, in situation: AISituation, override: AIPath? = nil) -> AIRouteDecision {
        let options = listed(work, situation)
        let chosen: AIPath
        if let path = override ?? situation.defaultPath, work.paths.contains(path) {
            chosen = path
        } else if work == .transcribe {
            // Never chosen: this phone first (§7.3b).
            chosen = .onDevice
        } else {
            // The first summary: let the user choose (§7.3b 第一次点「生成纪要」).
            return .choose(options, because: nil)
        }
        guard let option = options.first(where: { $0.path == chosen }) else {
            // Chosen once, no longer listed here (its model was removed, or this build has no server).
            return .choose(options, because: .notConfigured)
        }
        if let problem = option.problem { return .choose(options, because: problem) }
        return pick(chosen, for: work, in: situation)
    }

    /// The user picked `path` from a list (`choose`, or P06 ⋯ → 选择转写方式).
    public static func pick(_ path: AIPath, for work: AIWork, in situation: AISituation) -> AIRouteDecision {
        let options = listed(work, situation)
        guard work.paths.contains(path), let option = options.first(where: { $0.path == path }) else {
            return path == .ownService ? .setUp(path) : .choose(options, because: .notConfigured)
        }
        switch option.problem {
        case .signedOut?: return .signIn
        case .notConfigured?: return .setUp(path)
        case let problem?: return .choose(options, because: problem)
        case nil: break
        }
        if let consent = consentNeeded(path, for: work, in: situation) { return .confirm(path, consent) }
        return .run(path)
    }

    /// The ways to offer after `failed` did not work (本机转写失败): every other listed path.
    public static func alternatives(to failed: AIPath, for work: AIWork, in situation: AISituation) -> AIRouteDecision {
        .choose(listed(work, situation).filter { $0.path != failed }, because: nil)
    }

    /// The path 录完自动整理 takes, without asking anything; nil when it should leave the work for
    /// the recording page (no way chosen for summaries, the path cannot be used now, or the
    /// account without the 自动整理 consent).
    public static func automatic(_ work: AIWork, in situation: AISituation) -> AIPath? {
        let path: AIPath
        if let chosen = situation.defaultPath, work.paths.contains(chosen) {
            path = chosen
        } else if work == .transcribe {
            path = .onDevice
        } else {
            return nil
        }
        guard let option = situation.option(path), option.problem == nil else { return nil }
        if path == .account, !situation.consents.contains(.autoProcess) { return nil }
        return path
    }

    /// Turning 录完自动整理 on needs its own confirmation when it would use the account for
    /// either step and that was not agreed to yet.
    public static func autoProcessNeedsConsent(transcribeDefault: AIPath?, summarizeDefault: AIPath?,
                                               consents: Set<AIConsent>) -> Bool {
        (transcribeDefault == .account || summarizeDefault == .account) && !consents.contains(.autoProcess)
    }

    /// What the account path must be agreed to first; nil when nothing more is needed. Agreeing
    /// to upload the audio covers sending its text (that confirmation names the transcript and
    /// summary too), not the other way round.
    public static func consentNeeded(_ path: AIPath, for work: AIWork, in situation: AISituation) -> AIConsent? {
        guard path == .account else { return nil }
        let textOnly = work == .summarize && situation.hasTranscript
        if situation.consents.contains(.uploadAudio) { return nil }
        if textOnly { return situation.consents.contains(.sendText) ? nil : .sendText }
        return .uploadAudio
    }

    /// The defaults for a phone that had the app before §7.3b, so its behaviour stays the same:
    /// the old 本机转写（试验） switch, else the user's service when it had a transcription model;
    /// summaries by the user's service when one was set up. Nil where nothing was in use.
    public static func earlierDefaults(onDeviceSwitch: Bool, ownTranscription: Bool,
                                       ownService: Bool) -> (transcribe: AIPath?, summarize: AIPath?) {
        let transcribe: AIPath? = onDeviceSwitch ? .onDevice : (ownTranscription ? .ownService : nil)
        return (transcribe, ownService ? .ownService : nil)
    }

    /// The listed options for the work, in the order of `AIWork.paths`.
    private static func listed(_ work: AIWork, _ situation: AISituation) -> [AIPathOption] {
        work.paths.compactMap { situation.option($0) }
    }
}
