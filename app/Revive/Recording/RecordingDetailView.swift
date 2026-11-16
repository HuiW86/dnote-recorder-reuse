import AppModel
import Player
import SwiftUI

/// P06 recording detail: player, file info, export, delete (product-spec.md §4.2).
struct RecordingDetailView: View {
    let env: AppEnvironment
    let recordingId: UUID
    @State private var model: RecordingDetailModel?

    var body: some View {
        Group {
            if let model {
                RecordingDetailContent(model: model)
            } else {
                ProgressView()
            }
        }
        .onAppear {
            if model == nil, let library = env.library, let player = env.player {
                model = RecordingDetailModel(recordingId: recordingId, library: library, player: player)
            }
        }
        .onDisappear { model?.leave() }
    }
}

private struct RecordingDetailContent: View {
    @Bindable var model: RecordingDetailModel
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingDelete = false
    @State private var shareURL: URL?
    @State private var renaming = false
    @State private var newTitle = ""

    var body: some View {
        Group {
            if model.recording == nil {
                ContentUnavailableView("这条录音已删除", systemImage: "trash")
            } else if model.audioMissing {
                ContentUnavailableView {
                    Label("找不到这条录音的音频文件", systemImage: "exclamationmark.triangle")
                } actions: {
                    Button("删除这条记录", role: .destructive) { confirmingDelete = true }
                        .buttonStyle(.borderedProminent)
                }
            } else {
                content
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if model.recording != nil {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if !model.audioMissing {
                        Button {
                            shareURL = model.exportFile()
                        } label: {
                            Image(systemName: "square.and.arrow.up")
                        }
                        .accessibilityLabel("分享")
                    }
                    Menu {
                        Button("重命名", systemImage: "pencil") {
                            newTitle = model.editableTitle
                            renaming = true
                        }
                        Button("删除录音", systemImage: "trash", role: .destructive) { confirmingDelete = true }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("更多")
                }
            }
        }
        .confirmationDialog("删除这条录音？", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("删除录音", role: .destructive) { model.delete() }
        } message: {
            Text("录音会移到「最近删除」，保留 7 天。录音卡不受影响。")
        }
        .alert("重命名", isPresented: $renaming) {
            TextField("录音名称", text: $newTitle)
            Button("保存") { model.rename(to: newTitle) }
            Button("取消", role: .cancel) {}
        } message: {
            Text("留空则恢复为录音时间。")
        }
        .sheet(isPresented: Binding(get: { shareURL != nil }, set: { if !$0 { shareURL = nil } }),
               onDismiss: { RecordingExporter.cleanUp() }) {
            if let shareURL { ShareSheet(url: shareURL).presentationDetents([.medium, .large]) }
        }
        .onChange(of: model.isDeleted) { _, deleted in
            if deleted { dismiss() }
        }
        .toast($model.toast)
    }

    private var content: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text(model.title)
                        .font(.title2.bold())
                        .foregroundStyle(Theme.ink)
                    Text(model.startedAtText)
                        .font(.subheadline)
                        .foregroundStyle(Theme.inkMuted)
                }
                .listRowSeparator(.hidden)
            }
            .listRowBackground(Color.clear)
            Section {
                LabeledContent("时长", value: model.durationText)
                if let source = model.sourceText {
                    LabeledContent("来源", value: source)
                }
                LabeledContent("大小", value: model.sizeText)
            }
            .listRowBackground(Color.clear)
        }
        .listStyle(.plain)
        .paperBackground()
        // The player floats over the bottom of the page (design-spec.md §3).
        .safeAreaInset(edge: .bottom) {
            PlayerCard(model: model)
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
        }
    }
}

/// Player bar: scrubber, current / total time, play and 15 s skips (product-spec.md P06).
private struct PlayerCard: View {
    let model: RecordingDetailModel
    /// Position while the user drags the scrubber; nil otherwise.
    @State private var scrubbing: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TimelineView(.periodic(from: .now, by: 0.25)) { _ in
                let duration = max(model.duration, 0.01)
                let position = scrubbing ?? min(model.currentTime, duration)
                VStack(spacing: 4) {
                    Slider(value: Binding(get: { position }, set: { scrubbing = $0 }), in: 0...duration) { editing in
                        if !editing, let target = scrubbing {
                            model.seek(to: target)
                            scrubbing = nil
                        }
                    }
                    .accessibilityLabel("播放进度")
                    HStack {
                        Text(Self.clock(position, hours: duration >= 3600))
                        Spacer()
                        // Decoded length is a few ms short of the stored one (Opus pre-skip); round so
                        // it reads like 时长 instead of dropping a second once loaded.
                        Text(Self.clock(duration.rounded(), hours: duration >= 3600))
                    }
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 40) {
                Button { model.skip(by: -15) } label: {
                    Image(systemName: "gobackward.15").font(.title2)
                }
                .accessibilityLabel("后退 15 秒")
                Button { model.togglePlay() } label: {
                    Group {
                        if model.isPreparing {
                            ProgressView()
                        } else {
                            Image(systemName: model.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                                .font(.system(size: 48))
                        }
                    }
                    .frame(width: 56, height: 56)
                }
                .accessibilityLabel(model.isPlaying ? "暂停" : "播放")
                Button { model.skip(by: 15) } label: {
                    Image(systemName: "goforward.15").font(.title2)
                }
                .accessibilityLabel("前进 15 秒")
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity)
            if model.isPreparing {
                Text("正在准备播放")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(16)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).strokeBorder(Theme.line))
        .shadow(color: Color.black.opacity(0.08), radius: 10, y: 4)
    }

    private static func clock(_ seconds: Double, hours: Bool) -> String {
        let s = max(0, Int(seconds))
        return hours ? RecordingText.clock(seconds: s) : String(format: "%02d:%02d", s / 60, s % 60)
    }
}
