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
        case let .choose(work, options, because, _):
            ChooseList(work: work, options: options, because: because) { model.pick($0) }
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
                            Text(option.problem?.reason ?? option.path.detail(for: work))
                                .font(.footnote)
                                .foregroundStyle(Theme.inkMuted)
                        }
                        .padding(.vertical, 2)
                    }
                }
            } header: {
                if let because { Text(because.reason) }
            } footer: {
                Text(work == .summarize
                     ? "选过之后会记住，可以在「设置」里修改默认纪要方式。"
                     : "这次的选择只用于这条录音。长期修改在「设置」的默认转写方式。")
            }
            .surfaceRows()
        }
        .listStyle(.insetGrouped)
        .paperBackground()
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
