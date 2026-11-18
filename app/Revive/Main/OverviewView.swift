import AppModel
import Library
import SwiftUI

/// 总览 (#89): what needs attention, the todos not yet done across recordings, and the latest
/// recordings. Everything comes from this phone's library; no network (CLAUDE.md rule 3).
struct OverviewView: View {
    @Bindable var model: HomeModel
    @Bindable var overview: OverviewModel
    let env: AppEnvironment

    /// How many of the latest recordings 总览 lists.
    private let recentCount = 3

    var body: some View {
        List {
            Section {
                Text("总览")
                    .font(.largeTitle.bold())
                    .foregroundStyle(Theme.ink)
                    .accessibilityAddTraits(.isHeader)
                if let problem = model.session.bluetoothProblem {
                    Label(problem.userText ?? "", systemImage: "antenna.radiowaves.left.and.right.slash")
                        .font(.subheadline)
                        .foregroundStyle(Theme.ink)
                }
                if let card = model.syncCard, !isDone(card) {
                    SyncStatusCard(card: card, diagnostics: model.session.diagnostics) { model.retrySync() }
                }
            }
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0))

            if hasAttention {
                Section("需要处理") {
                    if let text = overview.untranscribedText {
                        Label(text, systemImage: "text.bubble")
                            .foregroundStyle(Theme.ink)
                    }
                    if env.assistantConfig.current() == nil {
                        NavigationLink(value: Route.assistant) {
                            Label("还没设置 AI 服务，生成不了纪要和待办", systemImage: "sparkles")
                                .foregroundStyle(Theme.ink)
                        }
                    }
                }
                .surfaceRows()
            }

            if !overview.visibleTodos.isEmpty {
                Section {
                    ForEach(overview.visibleTodos) { todo in
                        TodoRow(todo: todo, source: overview.sourceText(todo)) { overview.complete(todo) }
                    }
                } header: {
                    Text("接下来要做的").textCase(nil)
                } footer: {
                    if let more = overview.moreTodosText { Text(more) }
                }
                .surfaceRows()
            }

            Section {
                if model.recordings.isEmpty {
                    Text("还没有录音。按卡上的录音键，或点下方中间的红色按钮开始录第一条。")
                        .font(.subheadline)
                        .foregroundStyle(Theme.inkMuted)
                } else {
                    ForEach(model.recordings.prefix(recentCount), id: \.id) { recording in
                        NavigationLink(value: Route.recording(recording.id)) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(RecordingText.title(recording))
                                    .font(.headline)
                                    .foregroundStyle(Theme.ink)
                                Text(RecordingText.subtitle(recording, deviceName: model.deviceName(for: recording)))
                                    .font(.subheadline)
                                    .foregroundStyle(Theme.inkMuted)
                                    .monospacedDigit()
                            }
                        }
                    }
                }
            } header: {
                Text("最近的录音").textCase(nil)
            }
            .surfaceRows()
        }
        .listStyle(.insetGrouped)
        .paperBackground()
        .navigationBarTitleDisplayMode(.inline)
        .toast($overview.toast)
    }

    private var hasAttention: Bool {
        overview.untranscribedText != nil || env.assistantConfig.current() == nil
    }

    private func isDone(_ card: SyncCard) -> Bool {
        if case .done = card { true } else { false }
    }
}

/// An open todo: the box ticks it; the text opens the recording's 纪要.
private struct TodoRow: View {
    let todo: OpenTodo
    let source: String
    let complete: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Button(action: complete) {
                Image(systemName: "square")
                    .font(.title3)
                    .foregroundStyle(Theme.accent)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            // Borderless keeps the box's tap apart from the row's link.
            .buttonStyle(.borderless)
            .accessibilityLabel("完成：\(todo.text)")
            NavigationLink(value: Route.recordingSummary(todo.recording.id)) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(todo.text).foregroundStyle(Theme.ink)
                    Text(source).font(.caption).foregroundStyle(Theme.inkMuted)
                }
            }
        }
    }
}
