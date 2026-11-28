import Account
import AIRoute
import AppModel
import SwiftUI

/// What P06 shows before transcription or a summary goes ahead (product-spec.md §7.3b): the list
/// of ways, the confirmation before the 闻笺 account is sent anything, or the settings a chosen
/// way still needs (sign in, set up the user's AI service), opened right here.
struct AIPathSheet: View {
    let model: RecordingDetailModel
    let prompt: AIPrompt
    let env: AppEnvironment
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(prompt.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(isSettings ? "完成" : "取消") { dismiss() }
                    }
                }
        }
        .presentationDetents(isSettings ? [.large] : [.medium, .large])
    }

    private var isSettings: Bool {
        switch prompt {
        case .signIn, .setUp: true
        case .choose, .confirm: false
        }
    }

    @ViewBuilder
    private var content: some View {
        switch prompt {
        case let .choose(work, options, because, remember):
            ChooseList(work: work, options: options, because: because, remember: remember) { model.pick($0) }
        case let .confirm(_, _, consent):
            ConfirmPane(consent: consent) { model.agree() }
        case .signIn:
            if let session = env.account {
                AccountView(session: session) { account, deleted in
                    AccountAI.leave(account, deleted: deleted, preferences: env.preferences, library: env.library)
                }
            }
        case .setUp:
            AssistantSettingsView(preferences: env.preferences)
        }
    }
}

/// One row per way: its name, where the recording goes, and why it cannot be used now.
private struct ChooseList: View {
    let work: AIWork
    let options: [AIPathOption]
    let because: AIPathProblem?
    let remember: Bool
    let pick: (AIPath) -> Void

    var body: some View {
        List {
            Section {
                ForEach(options, id: \.path) { option in
                    Button {
                        pick(option.path)
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(option.path.title).foregroundStyle(Theme.ink)
                            Text(option.problem == .unsupported
                                 ? AIPathProblem.unsupported.reason
                                 : option.path.detail(for: work))
                                .font(.footnote)
                                .foregroundStyle(Theme.inkMuted)
                            if let hint = actionHint(for: option.problem) {
                                Text(hint.text)
                                    .font(.footnote)
                                    .foregroundStyle(hint.actionable ? Theme.accent : Theme.inkMuted)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            } header: {
                if let because { Text(headerText(for: because)) }
            } footer: {
                Text(footerText)
            }
            .surfaceRows()
        }
        .listStyle(.insetGrouped)
        .paperBackground()
    }

    private func headerText(for problem: AIPathProblem) -> String {
        switch problem {
        case .unsupported: "这部手机不支持离线识别这种语言，请换一种方式。"
        case .notConfigured: "默认方式还没设置，请先设置或换一种方式。"
        case .signedOut: "默认方式需要先登录闻笺账号，可点下方登录，或换一种方式。"
        case .offline:
            work == .transcribe
                ? "现在没有网络，请联网后再试，或改用本机转写。"
                : "现在没有网络，请联网后再试。"
        }
    }

    private func actionHint(for problem: AIPathProblem?) -> (text: String, actionable: Bool)? {
        switch problem {
        case .signedOut: ("未登录，点此登录", true)
        case .notConfigured: ("未设置，点此前往设置", true)
        case .offline: ("现在没有网络，联网后可用", false)
        case .unsupported, nil: nil
        }
    }

    private var footerText: String {
        if remember {
            return "选择后会设为默认纪要方式，之后可在「设置」里修改。"
        }
        return work == .summarize
            ? "这次选择仅用于本次生成；修改默认方式请到「设置」。"
            : "仅用于这条录音；想长期更换请到「设置」修改默认转写方式。"
    }
}

/// Says what leaves the phone, with the one button that sends it (§7.3b 上传前的确认).
private struct ConfirmPane: View {
    let consent: AIConsent
    let agree: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(consent.message)
                .foregroundStyle(Theme.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(consent.button, action: agree)
                .buttonStyle(.borderedProminent)
                .frame(maxWidth: .infinity)
            Spacer()
        }
        .padding(20)
        .background(Theme.paper)
    }
}
