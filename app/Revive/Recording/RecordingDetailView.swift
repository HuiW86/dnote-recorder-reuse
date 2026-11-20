import AppModel
import Assistant
import Library
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
                // Read on every use, so changing the switch applies to this page too (#85).
                let source: @MainActor () -> (any SpeechTranscribing)? = { [env] in
                    if env.preferences.onDeviceTranscriptEnabled { return OnDeviceTranscriber(library: library) }
                    if let cloud = env.cloudTranscriptionConfig { return CloudTranscriber(library: library, config: cloud) }
                    return nil
                }
                model = RecordingDetailModel(recordingId: recordingId, library: library, player: player,
                                             transcriberSource: source, assistant: env.assistantConfig)
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
    /// 思维导图 (features.md G1) in a sheet.
    @State private var showsMindMap = false
    /// 生词 (features.md X20 单词分级) in a sheet.
    @State private var showsWords = false
    @State private var renaming = false
    @State private var question = ""
    @State private var newTitle = ""
    @State private var newFolder = false
    @State private var folderName = ""
    /// The transcript line being corrected (纠错词库, #75), and its text in the field.
    @State private var editingLine: Int?
    @State private var lineText = ""

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
                    } else if model.isRetitling {
                        ProgressView().accessibilityLabel("正在起标题")
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
        .alert("修改这一句", isPresented: Binding(get: { editingLine != nil }, set: { if !$0 { editingLine = nil } })) {
            TextField("文字", text: $lineText, axis: .vertical)
            Button("保存") { if let index = editingLine { model.editLine(index, to: lineText) } }
            Button("取消", role: .cancel) {}
        } message: {
            Text("改正听错的词后，以后的转写会自动改正它。")
        }
        .alert("新建文件夹", isPresented: $newFolder) {
            TextField("文件夹名称", text: $folderName)
            Button("新建并移入") { model.moveToNewFolder(named: folderName) }
            Button("取消", role: .cancel) {}
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
        .sheet(isPresented: $showsMindMap) {
            if let summary = model.summary {
                MindMapSheet(title: model.title, outline: summary.outline)
            }
        }
        .sheet(isPresented: $showsWords) {
            WordListSheet(model: model)
        }
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
            // features.md D1c.
            Menu("移到文件夹", systemImage: "folder") {
                ForEach(model.folders) { folder in
                    Button(folder.name) { model.move(toFolder: folder.id) }
                }
                Button("新建文件夹…", systemImage: "folder.badge.plus") {
                    folderName = ""
                    newFolder = true
                }
                if model.recording?.folderId != nil {
                    Button("移出文件夹", systemImage: "folder.badge.minus") { model.move(toFolder: nil) }
                }
            }
            if model.canSummarize {
                if model.summary == nil {
                    Button("生成纪要", systemImage: "sparkles") {
                        pane = .summary
                        model.summarize()
                    }
                    .disabled(model.isSummarizing)
                } else {
                    // G2a: regenerate with the scene the model picks, or one the user chooses.
                    Menu("重新生成纪要", systemImage: "sparkles") {
                        Button("自动判断场景") {
                            pane = .summary
                            model.summarize()
                        }
                        ForEach(model.scenes) { scene in
                            Button("按「\(scene.name)」") {
                                pane = .summary
                                model.summarize(scene: scene)
                            }
                        }
                    }
                    .disabled(model.isSummarizing)
                }
            }
            if model.canRewrite {
                // G1: a title from another angle; replaces even a title the user typed.
                Button("让 AI 重新起标题", systemImage: "wand.and.stars") { model.retitle() }
                    .disabled(!model.canRetitle)
            }
            Menu("分享", systemImage: "square.and.arrow.up") {
                if model.hasAudio, !model.audioMissing {
                    Button("M4A（微信等大多数 App 可播放）", systemImage: "waveform") {
                        Task { shareURL = await model.exportM4A() }
                    }
                    Button("WAV（无损，用于剪辑，文件较大）", systemImage: "waveform.badge.plus") {
                        Task { shareURL = await model.exportWAV() }
                    }
                    Button("原始文件（\(model.originalFormat)）", systemImage: "doc") {
                        shareURL = model.exportFile()
                    }
                }
                if model.canExportMarkdown {
                    Button("纪要和文字稿（Markdown）", systemImage: "doc.text") {
                        shareURL = model.exportMarkdown()
                    }
                    Button("纪要和文字稿（PDF）", systemImage: "doc.richtext") {
                        shareURL = model.exportPDF()
                    }
                    Button("纪要和文字稿（Word）", systemImage: "doc.text.fill") {
                        shareURL = model.exportDOCX()
                    }
                }
                if model.canExportMindMap {
                    Button("思维导图（OPML，可导入 XMind、幕布）", systemImage: "point.3.connected.trianglepath.dotted") {
                        shareURL = model.exportMindMap()
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
            // A text-only recording (features.md E2) has nothing to play.
            if model.hasAudio {
                PlayerCard(model: model)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            }
        }
    }

    /// Title, then when, how long, the scene, and the star.
    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(model.title)
                .font(.title2.bold())
                .foregroundStyle(Theme.ink)
            if let folder = model.folderName {
                Label(folder, systemImage: "folder")
                    .font(.subheadline)
                    .foregroundStyle(Theme.inkMuted)
            }
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
            if model.hasAudio {
                LabeledContent("时长", value: model.durationText)
            }
            if let source = model.sourceText {
                LabeledContent("来源", value: model.hasAudio ? source : source + "（文字文件）")
            }
            if model.hasAudio {
                LabeledContent("大小", value: model.sizeText)
            }
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
                // G1 大纲: topics in the order discussed, with their points; also as a mind map.
                if !summary.outline.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("大纲").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.ink)
                            Spacer()
                            Button("思维导图") { showsMindMap = true }
                                .font(.subheadline)
                                .buttonStyle(.borderless)
                        }
                        ForEach(Array(summary.outline.enumerated()), id: \.offset) { index, item in
                            Text("\(index + 1). \(item.title)").foregroundStyle(Theme.ink)
                            ForEach(Array(item.points.enumerated()), id: \.offset) { _, point in
                                Text("· " + point)
                                    .foregroundStyle(Theme.inkMuted)
                                    .padding(.leading, 16)
                            }
                        }
                    }
                }
                // G1 金句: sentences quoted as said.
                if !summary.quotes.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("金句").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.ink)
                        ForEach(Array(summary.quotes.enumerated()), id: \.offset) { _, quote in
                            Text(quote)
                                .italic()
                                .foregroundStyle(Theme.ink)
                                .padding(.leading, 10)
                                .overlay(alignment: .leading) {
                                    Rectangle().fill(Theme.accent).frame(width: 2)
                                }
                                .textSelection(.enabled)
                        }
                    }
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
            if let looping = model.loopingIndex {
                // 单句循环 (features.md X20): what is looping and how to stop it.
                HStack(spacing: 8) {
                    Label("正在循环第 \(looping + 1) 句", systemImage: "repeat.1")
                        .font(.subheadline)
                        .foregroundStyle(Theme.accent)
                    Spacer()
                    Button("停止循环") { model.stopLoop() }
                        .font(.subheadline)
                }
                .listRowBackground(Color.clear)
            }
            if let transcript = model.transcript {
                ForEach(Array(transcript.segments.enumerated()), id: \.offset) { index, segment in
                    let playing = index == playingLine
                    let looping = index == model.loopingIndex
                    Button { model.play(from: segment) } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            // An imported text has no times (features.md E2).
                            if model.hasAudio {
                                Text(model.timeText(segment))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(playing ? Theme.accent : Theme.inkMuted)
                            }
                            Text(segment.text)
                                .foregroundStyle(Theme.ink)
                                .multilineTextAlignment(.leading)
                            if looping {
                                Spacer(minLength: 0)
                                Image(systemName: "repeat.1")
                                    .font(.caption)
                                    .foregroundStyle(Theme.accent)
                                    .accessibilityHidden(true)
                            }
                        }
                    }
                    .id(TranscriptLineID(index: index))
                    .listRowBackground(playing ? Theme.accentWash : Color.clear)
                    .accessibilityValue(looping ? "正在循环" : playing ? "正在播放" : "")
                    .accessibilityHint(model.hasAudio ? "从这里播放" : "")
                    .contextMenu {
                        if model.hasAudio {
                            Button(looping ? "停止循环" : "单句循环", systemImage: "repeat.1") {
                                model.toggleLoop(lineAt: index)
                            }
                        }
                        if model.canRewrite {
                            Button("解释这一句", systemImage: "text.bubble") { model.explainLine(index) }
                                .disabled(model.isAsking)
                        }
                        if !model.isPolishing {
                            Button("修改这一句", systemImage: "pencil") {
                                lineText = segment.text
                                editingLine = index
                            }
                        }
                    }
                    .accessibilityAction(named: looping ? "停止循环" : "单句循环") {
                        guard model.hasAudio else { return }
                        model.toggleLoop(lineAt: index)
                    }
                    .accessibilityAction(named: "解释这一句") {
                        guard model.canRewrite, !model.isAsking else { return }
                        model.explainLine(index)
                    }
                    .accessibilityAction(named: "修改这一句") {
                        guard !model.isPolishing else { return }
                        lineText = segment.text
                        editingLine = index
                    }
                }
            }
            Group {
                if model.isTranscribing {
                    HStack(spacing: 8) {
                        ProgressView()
                        VStack(alignment: .leading, spacing: 2) {
                            Text(model.transcriptionUsesNetwork ? "正在用你的 AI 服务转成文字" : "正在这部手机上转成文字")
                                .font(.subheadline)
                                .foregroundStyle(Theme.inkMuted)
                            // #75: learned from earlier runs on this phone; refreshed every few seconds.
                            TimelineView(.periodic(from: .now, by: 5)) { _ in
                                if let remaining = model.transcriptionRemainingText {
                                    Text(remaining).font(.caption).foregroundStyle(Theme.inkMuted)
                                }
                            }
                        }
                    }
                } else if model.canTranscribe {
                    Button(model.transcript == nil ? "转成文字" : "重新转写") { model.transcribe() }
                }
                // 逐句润色 (#75): optional, through the user's AI service; the transcribed text is kept.
                if model.isPolishing {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("正在用你的 AI 服务润色文字稿").font(.subheadline).foregroundStyle(Theme.inkMuted)
                    }
                } else if model.transcript?.isPolished == true {
                    Button("恢复原文") { model.restoreOriginal() }
                } else if model.canPolish {
                    Button("润色文字稿（去掉语气词，句子和时间不变）") { model.polish() }
                }
                // 单词分级 (X20): for a transcript mostly in a foreign language.
                if model.transcriptIsForeign {
                    if model.isListingWords {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("正在用你的 AI 服务挑生词").font(.subheadline).foregroundStyle(Theme.inkMuted)
                        }
                    } else if let list = model.wordList {
                        Button("生词 \(list.words.count) 个") { showsWords = true }
                    } else if model.canListWords {
                        Button("列出生词（按 A1～C2 分级）") { model.listWords() }
                    }
                }
                if !model.isTranscribing, !model.canTranscribe, model.transcript == nil {
                    Text("在设置里打开本机转写，或者给你的 AI 服务填上转写模型，就能把这条录音转成文字。")
                        .font(.subheadline)
                        .foregroundStyle(Theme.inkMuted)
                }
            }
            .listRowBackground(Color.clear)
        } header: {
            Text("文字稿")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                if model.canTranscribe {
                    Text(model.transcriptionUsesNetwork
                         ? "转文字时，录音音频会上传给你在设置里填的 AI 服务。"
                         : "在这部手机上识别，不联网，不区分说话人。试验功能，准确度有限。")
                }
                if model.canPolish || model.transcript?.isPolished == true {
                    Text("润色时，文字稿会发送给你在设置里填的 AI 服务；原文保留，可以恢复。")
                }
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
                    // One line at any text size: "1.25×" wrapped and made the player taller (#89).
                    Text(model.speedText)
                        .font(.footnote.weight(.semibold).monospacedDigit())
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .foregroundStyle(Theme.ink)
                        .padding(.horizontal, 4)
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

/// 生词 (features.md X20 单词分级): the words of the recording from the hardest level down,
/// filtered by a minimum level. Tapping one plays the line it was heard in.
private struct WordListSheet: View {
    @Bindable var model: RecordingDetailModel
    @Environment(\.dismiss) private var dismiss
    @State private var minimum: WordLevel = .b1

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("最低等级", selection: $minimum) {
                        Text("全部").tag(WordLevel.a1)
                        Text("B1 以上").tag(WordLevel.b1)
                        Text("B2 以上").tag(WordLevel.b2)
                        Text("C1 以上").tag(WordLevel.c1)
                    }
                    .pickerStyle(.segmented)
                }
                .listRowBackground(Color.clear)
                let groups = model.words(atLeast: minimum)
                if groups.isEmpty {
                    ContentUnavailableView("这个等级以上没有生词", systemImage: "character.book.closed")
                        .listRowBackground(Color.clear)
                }
                ForEach(groups, id: \.level) { group in
                    Section {
                        ForEach(group.words, id: \.self) { word in
                            Button {
                                model.play(word: word)
                                dismiss()
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(word.word).font(.body.weight(.semibold)).foregroundStyle(Theme.ink)
                                    if !word.meaning.isEmpty {
                                        Text(word.meaning).font(.subheadline).foregroundStyle(Theme.inkMuted)
                                    }
                                }
                            }
                            .accessibilityHint("播放这个词所在的句子")
                        }
                    } header: {
                        Text("\(group.level.rawValue) · \(group.words.count) 个").textCase(nil)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Theme.paper)
            .navigationTitle("生词")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    if model.canListWords {
                        Button("重新列出") {
                            model.listWords()
                            dismiss()
                        }
                    }
                }
            }
        }
    }
}

/// A rewrite or an answer, to read, copy or share. It opens at once and fills in as the reply
/// arrives (features.md G3); closing it stops the request.
private struct AssistantOutputSheet: View {
    let output: AssistantOutput
    @Environment(\.dismiss) private var dismiss

    private var dismissTitle: LocalizedStringKey {
        if output.isStreaming { return "停止" }
        return output.isCutOff ? "关闭" : "完成"
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if output.text.isEmpty, output.isStreaming {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("正在等你的 AI 服务回复").font(.subheadline).foregroundStyle(Theme.inkMuted)
                        }
                    } else {
                        Text(RichText.attributed(output.text))
                            .foregroundStyle(Theme.ink)
                            .textSelection(.enabled)
                    }
                    if output.isCutOff {
                        Label("回答没有收完整，可以关掉后再试一次。", systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(Theme.inkMuted)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }
            .background(Theme.paper)
            .navigationTitle(output.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(dismissTitle) { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    if output.isStreaming {
                        ProgressView().accessibilityLabel("正在接收")
                    } else {
                        ShareLink(item: output.text) {
                            Image(systemName: "square.and.arrow.up")
                        }
                        .accessibilityLabel("分享")
                    }
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

/// 思维导图 (features.md G1): the outline as a tree, the recording in the middle of the left
/// edge, one branch per topic and its points as leaves. Scrolls both ways for long outlines.
private struct MindMapSheet: View {
    let title: String
    let outline: [OutlineItem]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView([.horizontal, .vertical]) {
                HStack(alignment: .center, spacing: 0) {
                    node(title, emphasis: true)
                    connector
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(Array(outline.enumerated()), id: \.offset) { _, item in
                            HStack(alignment: .center, spacing: 0) {
                                connector
                                node(item.title, emphasis: false)
                                if !item.points.isEmpty {
                                    connector
                                    VStack(alignment: .leading, spacing: 6) {
                                        ForEach(Array(item.points.enumerated()), id: \.offset) { _, point in
                                            HStack(spacing: 0) {
                                                connector
                                                Text(point)
                                                    .font(.footnote)
                                                    .foregroundStyle(Theme.ink)
                                                    .frame(maxWidth: 220, alignment: .leading)
                                            }
                                        }
                                    }
                                    .overlay(alignment: .leading) { Rectangle().fill(Theme.line).frame(width: 1) }
                                }
                            }
                        }
                    }
                    .overlay(alignment: .leading) { Rectangle().fill(Theme.line).frame(width: 1) }
                }
                .padding(20)
            }
            .background(Theme.paper)
            .navigationTitle("思维导图")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var connector: some View {
        Rectangle().fill(Theme.line).frame(width: 16, height: 1).accessibilityHidden(true)
    }

    private func node(_ text: String, emphasis: Bool) -> some View {
        Text(text)
            .font(emphasis ? .headline : .subheadline.weight(.medium))
            .foregroundStyle(emphasis ? Theme.onDark : Theme.ink)
            .frame(maxWidth: 200, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(emphasis ? Theme.accent : Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.control))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control).strokeBorder(emphasis ? Color.clear : Theme.line))
    }
}
