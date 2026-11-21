import AppModel
import Library
import Player
import SwiftUI
import Transcription

/// One recording on the Mac: playback, its transcript and its summary (ADR-011 step one).
/// Transcribing uses 本机转写 or the user's service; summaries the user's service (X11). The
/// audio or text leaves the Mac only for the service the user set, and the pane says so.
struct RecordingPane: View {
    @State private var model: RecordingDetailModel

    init(recordingId: UUID, library: RecordingLibrary, player: RecordingPlayer, env: MacEnvironment) {
        // Read on every use, so a change in 设置 applies to an open pane too (#85).
        let source: @MainActor () -> (any SpeechTranscribing)? = { [env] in env.transcriber(library: library) }
        _model = State(initialValue: RecordingDetailModel(recordingId: recordingId, library: library, player: player,
                                                          transcriberSource: source, assistant: env.assistantConfig))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.title).font(.title2.weight(.semibold)).textSelection(.enabled)
                    Text(model.hasAudio ? "\(model.startedAtText) · \(model.durationText)" : model.startedAtText)
                        .foregroundStyle(.secondary)
                }
                if model.hasAudio {
                    if model.audioMissing {
                        Text("找不到这条录音的音频文件。").foregroundStyle(.secondary)
                    } else {
                        playerBar
                    }
                }
                actions
                if let summary = model.summary { summaryView(summary) }
                transcriptView
            }
            .padding(24)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(model.title)
        .toolbar {
            ToolbarItem {
                Button { model.toggleStar() } label: {
                    Label(model.isStarred ? "取消星标" : "标星", systemImage: model.isStarred ? "star.fill" : "star")
                }
            }
        }
        .onChange(of: model.isTranscribing) { _, running in
            if !running { model.reloadTranscript() }
        }
        .onChange(of: model.isSummarizing) { _, running in
            if !running { model.reloadSummary() }
        }
        .overlay(alignment: .bottom) {
            if let toast = model.toast {
                Text(toast.text)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.bottom, 20)
                    .task(id: toast.id) {
                        try? await Task.sleep(for: .seconds(3))
                        if model.toast?.id == toast.id { model.toast = nil }
                    }
            }
        }
        .onDisappear { model.leave() }
    }

    /// 转成文字 and 生成纪要, with what they send and where (ADR-009).
    @ViewBuilder private var actions: some View {
        let showsTranscribe = model.canTranscribe || model.isTranscribing
        let showsSummarize = model.canSummarize || model.isSummarizing
        if showsTranscribe || showsSummarize {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 12) {
                    if showsTranscribe {
                        Button(model.transcript == nil ? "转成文字" : "重新转写") { model.transcribe() }
                            .disabled(model.isTranscribing)
                    }
                    if model.isTranscribing {
                        ProgressView().controlSize(.small)
                        Text(model.transcriptionRemainingText ?? "正在转文字").foregroundStyle(.secondary)
                    }
                    if showsSummarize {
                        Button(model.summary == nil ? "生成纪要" : "重新生成纪要") { model.summarize() }
                            .disabled(model.isSummarizing)
                    }
                    if model.isSummarizing {
                        ProgressView().controlSize(.small)
                        Text("正在整理纪要").foregroundStyle(.secondary)
                    }
                }
                if showsTranscribe, model.transcriptionUsesNetwork {
                    Text("转文字时，录音音频会上传给你在设置里填的服务。").font(.caption).foregroundStyle(.secondary)
                }
                if showsSummarize {
                    Text("生成纪要时，文字稿会发给你在设置里填的 AI 服务。").font(.caption).foregroundStyle(.secondary)
                }
            }
        } else if let hint = model.summaryHint {
            Text(hint.replacingOccurrences(of: "「设置 → AI 服务」", with: "「设置」（⌘,）"))
                .foregroundStyle(.secondary)
        }
    }

    private var playerBar: some View {
        HStack(spacing: 12) {
            Button { model.skip(by: -15) } label: { Image(systemName: "gobackward.15") }
                .help("后退 15 秒")
            Button { model.togglePlay() } label: {
                Image(systemName: model.isPlaying ? "pause.fill" : "play.fill").frame(width: 18)
            }
            .help(model.isPlaying ? "暂停" : "播放")
            .disabled(model.isPreparing)
            Button { model.skip(by: 15) } label: { Image(systemName: "goforward.15") }
                .help("前进 15 秒")
            TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                let total = max(model.duration, 0.1)
                HStack(spacing: 8) {
                    Slider(value: Binding(get: { min(model.currentTime, total) }, set: { model.seek(to: $0) }),
                           in: 0...total)
                    Text(RecordingText.clock(seconds: Int(model.currentTime)))
                        .monospacedDigit().foregroundStyle(.secondary)
                }
            }
            Button(model.speedText) { model.cycleSpeed() }
                .help("播放速度")
        }
    }

    private func summaryView(_ summary: Summary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("纪要").font(.headline)
            Text(summary.summary).textSelection(.enabled)
            ForEach(Array(summary.sections.enumerated()), id: \.offset) { _, section in
                Text(section.heading).font(.subheadline.weight(.semibold)).padding(.top, 4)
                ForEach(Array(section.items.enumerated()), id: \.offset) { _, item in
                    Text("• \(item)").textSelection(.enabled)
                }
            }
            if !summary.todos.isEmpty {
                Text("待办").font(.subheadline.weight(.semibold)).padding(.top, 4)
                ForEach(Array(summary.todos.enumerated()), id: \.offset) { _, todo in
                    Label(todo.text, systemImage: todo.done ? "checkmark.circle" : "circle")
                }
            }
        }
    }

    @ViewBuilder private var transcriptView: some View {
        if let transcript = model.transcript, !transcript.segments.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("文字稿").font(.headline)
                ForEach(Array(transcript.segments.enumerated()), id: \.offset) { _, segment in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        if model.hasAudio {
                            Button(model.timeText(segment)) { model.play(from: segment) }
                                .buttonStyle(.link).monospacedDigit()
                                .help("从这里播放")
                        }
                        Text(segment.text).textSelection(.enabled)
                    }
                }
            }
        } else if model.hasAudio, !model.canTranscribe {
            Text("这条录音还没有文字稿。在「设置」（⌘,）里打开本机转写，或填上带转写模型的 AI 服务，就能转成文字。")
                .foregroundStyle(.secondary)
        }
    }
}
