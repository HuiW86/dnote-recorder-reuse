import AppModel
import Assistant
import Player
import SwiftUI
import Transcription

/// The three panes of the detail page (#89).
enum DetailPane: String, CaseIterable, Identifiable {
    case summary, transcript, rewrite

    var id: String { rawValue }

    var title: String {
        switch self {
        case .summary: "纪要"
        case .transcript: "文字稿"
        case .rewrite: "改写"
        }
    }
}

/// P06 recording detail: header, the 纪要 / 文字稿 / 改写 panes, the floating player, and the
/// page's actions in "⋯" (product-spec.md §4.2, #89).
struct RecordingDetailView: View {
    let env: AppEnvironment
    let recordingId: UUID
    /// The pane to open on; nil picks one from what the recording has.
    var initialPane: DetailPane?
    /// Called after the recording was moved to 最近删除, so the list can offer "撤销" (#85).
    var onDeleted: (UUID) -> Void = { _ in }
    @State private var model: RecordingDetailModel?

    var body: some View {
        Group {
            if let model {
                RecordingDetailContent(model: model, initialPane: initialPane ?? LaunchOptions.startPane,
                                       onDeleted: onDeleted)
            } else {
                ProgressView().paperPage()
            }
        }
        .onAppear {
            if model == nil, let library = env.library, let player = env.player {
                // On-device transcription is behind a switch until its quality is measured (#67).
                // On the phone when that is switched on; otherwise the user's own service, if they
                // gave it a transcription model (the audio is then uploaded, and the page says so).
                let transcriber: (any SpeechTranscribing)? = if env.preferences.onDeviceTranscriptEnabled {
                    OnDeviceTranscriber(library: library)
                } else if let cloud = env.cloudTranscriptionConfig {
                    CloudTranscriber(library: library, config: cloud)
                } else {
                    nil
                }
                model = RecordingDetailModel(recordingId: recordingId, library: library, player: player,
                                             transcriber: transcriber, assistant: env.assistantConfig)
            }
        }
        .onDisappear { model?.leave() }
    }
}

private struct RecordingDetailContent: View {
    @Bindable var model: RecordingDetailModel
    var initialPane: DetailPane?
    var onDeleted: (UUID) -> Void = { _ in }
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pane: DetailPane?
    /// The transcript line being played, polled while 文字稿 is shown.
    @State private var playingLine: Int?
    @State private var confirmingDelete = false
    @State private var shareURL: URL?
    @State private var renaming = false
    @State private var question = ""
    @State private var newTitle = ""

    var body: some View {
        Group {
            if model.recording == nil {
                ContentUnavailableView("这条录音已删除", systemImage: "trash")
                    .paperPage()
            } else if model.audioMissing {
                ContentUnavailableView {
                    Label("找不到这条录音的音频文件", systemImage: "exclamationmark.triangle")
                } actions: {
                    Button("删除这条记录", role: .destructive) { confirmingDelete = true }
                        .buttonStyle(.borderedProminent)
                }
                .paperPage()
            } else {
                content
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if model.recording != nil {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if model.isExporting {
                        ProgressView().accessibilityLabel("正在导出")
                    }
                    moreMenu
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
        .onChange(of: model.isTranscribing) { _, running in
            if !running { model.reloadTranscript() }
        }
        .onChange(of: model.isDeleted) { _, deleted in
            guard deleted else { return }
            onDeleted(model.recordingId)
            dismiss()
        }
        .toast($model.toast)
        .sheet(item: $model.assistantOutput) { output in
            AssistantOutputSheet(output: output)
        }
    }

    /// Everything the page can do, in one menu (#89).
    private var moreMenu: some View {
        Menu {
            Button("重命名", systemImage: "pencil") {
                newTitle = model.editableTitle
                renaming = true
            }
            Button(model.isStarred ? "取消星标" : "标星", systemImage: model.isStarred ? "star.slash" : "star") {
                model.toggleStar()
            }
            if model.canSummarize {
                Button(model.summary == nil ? "生成纪要" : "重新生成纪要", systemImage: "sparkles") {
                    pane = .summary
                    model.summarize()
                }
                .disabled(model.isSummarizing)
            }
            Menu("分享", systemImage: "square.and.arrow.up") {
                if !model.audioMissing {
                    Button("M4A（微信等大多数 App 可播放）", systemImage: "waveform") {
                        Task { shareURL = await model.exportM4A() }
                    }
                    Button("原始文件（OGG）", systemImage: "doc") {
                        shareURL = model.exportFile()
                    }
                }
                if model.canExportMarkdown {
                    Button("纪要和文字稿（Markdown）", systemImage: "doc.text") {
                        shareURL = model.exportMarkdown()
                    }
                }
            }
            .disabled(model.isExporting)
            if let transcript = model.transcript, !transcript.segments.isEmpty {
                Button("拷贝文字稿", systemImage: "doc.on.doc") {
                    UIPasteboard.general.string = transcript.segments.map(\.text).joined(separator: "\n")
                    model.toast = Toast("已拷贝文字稿")
                }
            }
            Divider()
            Button("删除录音", systemImage: "trash", role: .destructive) { confirmingDelete = true }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .accessibilityLabel("更多")
    }

    /// The pane shown: the user's choice, else the one asked for, else 纪要 when there is one,
    /// then 文字稿.
    private var currentPane: DetailPane {
        pane ?? initialPane ?? (model.summary == nil && model.transcript != nil ? .transcript : .summary)
    }

    private var paneBinding: Binding<DetailPane> {
        Binding(get: { currentPane }, set: { pane = $0 })
    }

    private var content: some View {
        ScrollViewReader { proxy in
            List {
                Section {
                    header
                        .listRowSeparator(.hidden)
                    Picker("内容", selection: paneBinding) {
                        ForEach(DetailPane.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .listRowSeparator(.hidden)
                }
                .listRowBackground(Color.clear)
                switch currentPane {
                case .summary:
                    summarySection
                    infoSection
                case .transcript:
                    if !model.marks.isEmpty {
                        marksSection
                    }
                    transcriptSection
                case .rewrite:
                    rewriteSection
                }
            }
            .listStyle(.plain)
            .paperBackground()
            .onChange(of: playingLine) { _, line in
                // Follow the line being played; with Reduce Motion on, the page does not move (#89).
                guard let line, !reduceMotion, currentPane == .transcript else { return }
                withAnimation { proxy.scrollTo(TranscriptLineID(index: line), anchor: .center) }
            }
        }
        .task(id: currentPane) {
            guard currentPane == .transcript else { return }
            while !Task.isCancelled {
                let line = model.currentSegmentIndex
                if line != playingLine { playingLine = line }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        // The player floats over the bottom of the page (design-spec.md §3).
        .safeAreaInset(edge: .bottom) {
            PlayerCard(model: model)
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
        }
    }

    /// Title, then when, how long, the scene, and the star.
    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(model.title)
                .font(.title2.bold())
                .foregroundStyle(Theme.ink)
            HStack(spacing: 6) {
                Text(headerLine)
                    .font(.subheadline)
                    .foregroundStyle(Theme.inkMuted)
                    .monospacedDigit()
                if model.isStarred {
                    Image(systemName: "star.fill")
                        .font(.subheadline)
                        .foregroundStyle(Theme.accent)
                        .accessibilityLabel("已标星")
                }
            }
        }
    }

    private var headerLine: String {
        var parts = [model.startedAtText, model.durationText]
        if let scene = model.sceneName { parts.append(scene) }
        return parts.joined(separator: " · ")
    }

    private var marksSection: some View {
        Section("重点") {
            ForEach(model.marks) { mark in
                Button { model.play(from: mark) } label: {
                    Label(model.markText(mark), systemImage: "bookmark.fill")
                        .monospacedDigit()
                }
                .accessibilityHint("从这里播放")
            }
        }
        .listRowBackground(Color.clear)
    }

    private var infoSection: some View {
        Section {
            LabeledContent("时长", value: model.durationText)
            if let source = model.sourceText {
                LabeledContent("来源", value: source)
            }
            LabeledContent("大小", value: model.sizeText)
        }
        .listRowBackground(Color.clear)
    }
}

/// Scroll target of a transcript line.
private struct TranscriptLineID: Hashable {
    let index: Int
}

extension RecordingDetailContent {
    /// 改写和提问 (features.md X15, G3): the user's own AI service, on this recording's text.
    @ViewBuilder fileprivate var rewriteSection: some View {
        if !model.canRewrite {
            Section {
                Text("转成文字、并在设置里填了 AI 服务后，可以把这条录音改写成别的样子，或者问它问题。")
                    .font(.subheadline)
                    .foregroundStyle(Theme.inkMuted)
            }
            .listRowBackground(Color.clear)
        } else {
            rewriteControls
        }
    }

    @ViewBuilder private var rewriteControls: some View {
        Section {
            Menu {
                ForEach(RewriteStyle.allCases) { style in
                    Button(style.name) { model.rewrite(style) }
                }
            } label: {
                Label("改写成…", systemImage: "square.and.pencil")
            }
            .disabled(model.isAsking)
            HStack {
                TextField("问这条录音一个问题", text: $question)
                    .submitLabel(.send)
                    .onSubmit { model.ask(question) }
                Button("提问") { model.ask(question) }
                    .disabled(question.trimmingCharacters(in: .whitespaces).isEmpty || model.isAsking)
            }
            if model.isAsking {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("正在用你的 AI 服务处理").font(.subheadline).foregroundStyle(Theme.inkMuted)
                }
            }
        } header: {
            Text("改写和提问")
        } footer: {
            Text("会把纪要和文字稿发送给你在设置里填的 AI 服务；录音音频不会发送。回答只依据这条录音。")
        }
        .listRowBackground(Color.clear)
    }

    /// 纪要 (features.md G1): made by the user's own AI service from the transcript.
    @ViewBuilder fileprivate var summarySection: some View {
        Section {
            if let summary = model.summary {
                VStack(alignment: .leading, spacing: 6) {
                    if !summary.title.isEmpty {
                        Text(summary.title).font(.headline).foregroundStyle(Theme.ink)
                    }
                    Text(summary.summary).foregroundStyle(Theme.ink)
                    if let scene = model.sceneName {
                        Text(scene).font(.caption).foregroundStyle(Theme.inkMuted)
                    }
                }
                ForEach(Array(summary.sections.enumerated()), id: \.offset) { _, section in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(section.heading).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.ink)
                        ForEach(Array(section.items.enumerated()), id: \.offset) { _, item in
                            Text("· " + item).foregroundStyle(Theme.ink)
                        }
                    }
                }
                if !summary.tags.isEmpty || !summary.people.isEmpty {
                    FlowLayout {
                        ForEach(summary.people, id: \.self) { person in
                            Chip(text: person, symbol: "person")
                        }
                        ForEach(summary.tags, id: \.self) { tag in
                            Chip(text: "# " + tag.trimmingCharacters(in: CharacterSet(charactersIn: "# ")), symbol: nil)
                        }
                    }
                }
                ForEach(Array(summary.todos.enumerated()), id: \.offset) { index, todo in
                    Button { model.setTodo(index, done: !todo.done) } label: {
                        Label(todo.text, systemImage: todo.done ? "checkmark.square.fill" : "square")
                            .foregroundStyle(Theme.ink)
                    }
                    .accessibilityAddTraits(todo.done ? .isSelected : [])
                }
            }
            if model.isSummarizing {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("正在用你的 AI 服务整理纪要").font(.subheadline).foregroundStyle(Theme.inkMuted)
                }
            } else if model.canSummarize {
                Button(model.summary == nil ? "生成纪要" : "重新生成纪要") { model.summarize() }
            } else if let hint = model.summaryHint {
                Text(hint).font(.subheadline).foregroundStyle(Theme.inkMuted)
            }
        } header: {
            Text("纪要")
        } footer: {
            Text("生成纪要时，文字稿会发送给你在设置里填的 AI 服务；录音音频不会发送。")
        }
        .listRowBackground(Color.clear)
    }

    /// 文字稿 (features.md X9): made on this phone; tapping a line plays from there.
    @ViewBuilder fileprivate var transcriptSection: some View {
        Section {
            if let transcript = model.transcript {
                ForEach(Array(transcript.segments.enumerated()), id: \.offset) { index, segment in
                    let playing = index == playingLine
                    Button { model.play(from: segment) } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text(model.timeText(segment))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(playing ? Theme.accent : Theme.inkMuted)
                            Text(segment.text)
                                .foregroundStyle(Theme.ink)
                                .multilineTextAlignment(.leading)
                        }
                    }
                    .id(TranscriptLineID(index: index))
                    .listRowBackground(playing ? Theme.accentWash : Color.clear)
                    .accessibilityValue(playing ? "正在播放" : "")
                    .accessibilityHint("从这里播放")
                }
            }
            Group {
                if model.isTranscribing {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text(model.transcriptionUsesNetwork ? "正在用你的 AI 服务转成文字" : "正在这部手机上转成文字，长录音需要一些时间")
                            .font(.subheadline)
                            .foregroundStyle(Theme.inkMuted)
                    }
                } else if model.canTranscribe {
                    Button(model.transcript == nil ? "转成文字" : "重新转写") { model.transcribe() }
                } else if model.transcript == nil {
                    Text("在设置里打开本机转写，或者给你的 AI 服务填上转写模型，就能把这条录音转成文字。")
                        .font(.subheadline)
                        .foregroundStyle(Theme.inkMuted)
                }
            }
            .listRowBackground(Color.clear)
        } header: {
            Text("文字稿")
        } footer: {
            if model.canTranscribe {
                Text(model.transcriptionUsesNetwork
                     ? "转文字时，录音音频会上传给你在设置里填的 AI 服务。"
                     : "在这部手机上识别，不联网，不区分说话人。试验功能，准确度有限。")
            }
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
                    .overlay(alignment: .leading) { markTicks }
                    HStack {
                        Text(Self.clock(position, hours: duration >= 3600))
                        Spacer()
                        // Decoded length is a few ms short of the stored one (Opus pre-skip); round so
                        // it reads like 时长 instead of dropping a second once loaded.
                        Text(Self.clock(duration.rounded(), hours: duration >= 3600))
                    }
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Theme.inkMuted)
                }
            }
            HStack(spacing: 40) {
                Button { model.skip(by: -15) } label: {
                    Image(systemName: "gobackward.15").font(.title2)
                        .foregroundStyle(Theme.ink)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("后退 15 秒")
                Button { model.togglePlay() } label: {
                    Group {
                        if model.isPreparing {
                            ProgressView()
                        } else {
                            Image(systemName: model.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                                .font(.system(size: 48))
                                .foregroundStyle(Theme.accent)
                        }
                    }
                    .frame(width: 56, height: 56)
                }
                .accessibilityLabel(model.isPlaying ? "暂停" : "播放")
                Button { model.skip(by: 15) } label: {
                    Image(systemName: "goforward.15").font(.title2)
                        .foregroundStyle(Theme.ink)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("前进 15 秒")
                Button { model.cycleSpeed() } label: {
                    Text(model.speedText)
                        .font(.footnote.weight(.semibold).monospacedDigit())
                        .foregroundStyle(Theme.ink)
                        .frame(minWidth: 44, minHeight: 44)
                        .background(Theme.paper, in: RoundedRectangle(cornerRadius: Theme.Radius.control))
                }
                .accessibilityLabel("播放速度 \(model.speedText)")
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity)
            if model.isPreparing {
                Text("正在准备播放")
                    .font(.caption)
                    .foregroundStyle(Theme.inkMuted)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(16)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).strokeBorder(Theme.line))
        .shadow(color: Theme.shadow, radius: 10, y: 4)
    }

    /// The marks as short ticks over the progress bar; not interactive (the 重点 list is).
    private var markTicks: some View {
        GeometryReader { proxy in
            ForEach(Array(model.markPositions.enumerated()), id: \.offset) { _, position in
                Rectangle()
                    .fill(Theme.ink)
                    .frame(width: 2, height: 10)
                    .position(x: proxy.size.width * position, y: proxy.size.height / 2)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private static func clock(_ seconds: Double, hours: Bool) -> String {
        let s = max(0, Int(seconds))
        return hours ? RecordingText.clock(seconds: s) : String(format: "%02d:%02d", s / 60, s % 60)
    }
}

/// A rewrite or an answer, to read, copy or share.
private struct AssistantOutputSheet: View {
    let output: AssistantOutput
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(output.text)
                    .foregroundStyle(Theme.ink)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
            }
            .background(Theme.paper)
            .navigationTitle(output.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    ShareLink(item: output.text) {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .accessibilityLabel("分享")
                }
            }
        }
    }
}

/// A person or a tag under a summary; one line, cut short when wider than the page.
private struct Chip: View {
    let text: String
    let symbol: String?

    var body: some View {
        HStack(spacing: 4) {
            if let symbol { Image(systemName: symbol).imageScale(.small) }
            Text(text).lineLimit(1)
        }
        .font(.footnote)
        .foregroundStyle(Theme.ink)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Theme.accentWash, in: RoundedRectangle(cornerRadius: Theme.Radius.chip))
    }
}
