import AppModel
import Library
import SwiftUI

/// 最近删除 (features.md D1b): restore a recording, or delete it for good.
struct TrashView: View {
    let env: AppEnvironment
    @State private var model: TrashModel?

    var body: some View {
        Group {
            if let model {
                TrashContent(model: model)
            } else {
                ContentUnavailableView("无法读取录音", systemImage: "exclamationmark.triangle")
                    .paperPage()
            }
        }
        .navigationTitle("最近删除")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if model == nil, let library = env.library { model = TrashModel(library: library) }
            model?.start()
        }
        .onDisappear { model?.stop() }
    }
}

private struct TrashContent: View {
    @Bindable var model: TrashModel
    @State private var pendingDelete: Recording?
    @State private var confirmingEmpty = false

    var body: some View {
        Group {
            if model.recordings.isEmpty {
                ContentUnavailableView("没有最近删除的录音", systemImage: "trash",
                                       description: Text("在这部手机上删除的录音会在这里保留 7 天"))
                    .paperPage()
            } else {
                list
            }
        }
        .toolbar {
            if !model.recordings.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("清空") { confirmingEmpty = true }
                }
            }
        }
        .confirmationDialog("彻底删除这条录音？", isPresented: deleteBinding, titleVisibility: .visible,
                            presenting: pendingDelete) { recording in
            Button("彻底删除", role: .destructive) { model.deleteForever(recording.id) }
        } message: { recording in
            Text(recording.source != .card ? "这是唯一一份，删除后无法恢复。"
                 : model.isLastCopy(recording) ? "录音卡上已没有原文件，删除后无法恢复。"
                 : "删除后无法恢复，但录音卡上的原文件不受影响。")
        }
        .confirmationDialog("清空最近删除？", isPresented: $confirmingEmpty, titleVisibility: .visible) {
            Button("全部彻底删除", role: .destructive) { model.empty() }
        } message: {
            // Says how many exist nowhere else, instead of promising the card has them.
            let lastCopies = model.recordings.filter { model.isLastCopy($0) }.count
            Text(lastCopies == 0
                 ? "将彻底删除全部 \(model.recordings.count) 条录音，无法恢复；录音卡上的原文件不受影响。"
                 : lastCopies == model.recordings.count
                 ? "将彻底删除全部 \(model.recordings.count) 条录音，都只有这一份，无法恢复。"
                 : "将彻底删除全部 \(model.recordings.count) 条录音，无法恢复；其中 \(lastCopies) 条只有这一份。")
        }
        .toast($model.toast)
    }

    private var list: some View {
        List {
            Section {
                ForEach(model.recordings, id: \.id) { recording in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(RecordingText.title(recording))
                            .font(.headline)
                            .foregroundStyle(Theme.ink)
                        Text("\(RecordingText.duration(ms: recording.durationMs)) · \(model.remainingText(recording))")
                            .font(.subheadline)
                            .foregroundStyle(Theme.inkMuted)
                    }
                    .padding(.vertical, 2)
                    .swipeActions(edge: .trailing) {
                        // No destructive role: it animates the row away before the user confirms.
                        Button("彻底删除") { pendingDelete = recording }
                            .tint(.red)
                    }
                    .swipeActions(edge: .leading) {
                        Button("恢复") { model.restore(recording.id) }
                            .tint(Theme.ok)
                    }
                    .contextMenu {
                        Button("恢复", systemImage: "arrow.uturn.backward") { model.restore(recording.id) }
                        Button("彻底删除", systemImage: "trash", role: .destructive) { pendingDelete = recording }
                    }
                    .accessibilityAction(named: "恢复") { model.restore(recording.id) }
                    .accessibilityAction(named: "彻底删除") { pendingDelete = recording }
                }
            } footer: {
                Text("向右滑恢复，向左滑彻底删除。到期后自动删除。")
            }
            .surfaceRows()
        }
        .listStyle(.insetGrouped)
        .paperBackground()
    }

    private var deleteBinding: Binding<Bool> {
        Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })
    }
}
