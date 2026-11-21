import AppModel
import Library
import Player
import SwiftUI

/// One recording on the Mac: playback, its transcript and its summary (ADR-011 step one).
/// Transcribing and summarizing come later; nothing here uses the network.
struct RecordingPane: View {
    @State private var model: RecordingDetailModel

    init(recordingId: UUID, library: RecordingLibrary, player: RecordingPlayer) {
        _model = State(initialValue: RecordingDetailModel(recordingId: recordingId, library: library, player: player))
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
        .onDisappear { model.leave() }
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
        } else {
            Text("这条录音还没有文字稿。Mac 版暂时还不能转文字和整理纪要。").foregroundStyle(.secondary)
        }
    }
}
