import AppModel
import Library
import SwiftUI

/// 知识库 (#89): ask across recordings (features.md G3) with the user's own service, search
/// titles, transcripts and summaries on this phone, and the latest summaries.
struct KnowledgeView: View {
    @Bindable var model: HomeModel
    @Bindable var overview: OverviewModel
    @Bindable var questions: LibraryQuestionModel
    let env: AppEnvironment
    @State private var query = ""
    @State private var question = ""

    var body: some View {
        List {
            Section {
                Text("知识库")
                    .font(.largeTitle.bold())
                    .foregroundStyle(Theme.ink)
                    .accessibilityAddTraits(.isHeader)
            }
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0))

            // G3: only when there are summaries to ask about; otherwise the empty state below says
            // how to get them.
            if model.searchResults == nil, !overview.digest.recentSummaries.isEmpty {
                askSection
            }

            if let results = model.searchResults {
                if results.isEmpty {
                    ContentUnavailableView.search(text: query)
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                } else {
                    Section {
                        ForEach(results, id: \.id) { recording in
                            NavigationLink(value: Route.recording(recording.id)) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(RecordingText.title(recording)).font(.headline).foregroundStyle(Theme.ink)
                                    Text(RecordingText.subtitle(recording, deviceName: model.deviceName(for: recording)))
                                        .font(.subheadline)
                                        .foregroundStyle(Theme.inkMuted)
                                        .monospacedDigit()
                                }
                            }
                        }
                    } header: {
                        Text("找到 \(results.count) 条").textCase(nil)
                    }
                    .surfaceRows()
                }
            } else if overview.digest.recentSummaries.isEmpty {
                ContentUnavailableView {
                    Label("还没有整理好的纪要", systemImage: "books.vertical")
                } description: {
                    Text("在录音详情里点「转成文字」、再生成纪要后，会出现在这里。转文字默认在这部手机上离线完成；生成纪要要用 AI 服务。")
                } actions: {
                    NavigationLink("设置 AI 服务", value: Route.assistant)
                }
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            } else {
                if !overview.digest.tags.isEmpty {
                    tagsSection
                }
                Section {
                    ForEach(overview.digest.recentSummaries) { item in
                        NavigationLink(value: Route.recordingSummary(item.recording.id)) {
                            SummaryRow(item: item)
                        }
                    }
                } header: {
                    Text("最近整理好的").textCase(nil)
                }
                .surfaceRows()
            }
        }
        .listStyle(.insetGrouped)
        .paperBackground()
        .navigationBarTitleDisplayMode(.inline)
        .toast($questions.toast)
        .searchable(text: $query, prompt: "搜索标题、文字稿、纪要")
        .onChange(of: query) { _, text in model.search(text) }
        // The library changed (a sync, a delete): refresh what the search shows.
        .onChange(of: model.recordings) { _, _ in if !query.isEmpty { model.search(query) } }
    }
}

extension KnowledgeView {
    /// 标签 (features.md D1c): the most used tags at a glance; the row opens the full list.
    @ViewBuilder fileprivate var tagsSection: some View {
        Section {
            NavigationLink(value: Route.tags) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("全部 \(overview.digest.tags.count) 个标签").foregroundStyle(Theme.ink)
                    Text(overview.digest.tags.prefix(6).map { "# \($0.name)" }.joined(separator: "  "))
                        .font(.subheadline)
                        .foregroundStyle(Theme.inkMuted)
                        .lineLimit(2)
                }
            }
        } header: {
            Text("标签").textCase(nil)
        }
        .surfaceRows()
    }

    /// "问问你的录音": the question, the answer with the recordings it cited (features.md G3).
    @ViewBuilder fileprivate var askSection: some View {
        Section {
            if questions.isConfigured {
                HStack {
                    TextField("问问你的录音", text: $question, axis: .vertical)
                        .lineLimit(1...4)
                        .submitLabel(.send)
                        .onSubmit { questions.ask(question) }
                    if questions.isAsking {
                        ProgressView()
                    } else {
                        Button("提问") { questions.ask(question) }
                            .disabled(question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                if let answer = questions.answer {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(answer.question).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.ink)
                        // G3 "SSE 流式": the answer fills in as it arrives.
                        if answer.text.isEmpty, answer.isStreaming {
                            Text("正在等你的 AI 服务回复").font(.subheadline).foregroundStyle(Theme.inkMuted)
                        } else {
                            Text(RichText.attributed(answer.text)).foregroundStyle(Theme.ink).textSelection(.enabled)
                        }
                        if answer.isCutOff {
                            Label("回答没有收完整，可以再问一次。", systemImage: "exclamationmark.triangle")
                                .font(.footnote)
                                .foregroundStyle(Theme.inkMuted)
                        }
                    }
                    if !answer.sources.isEmpty {
                        ForEach(Array(answer.sources.enumerated()), id: \.offset) { _, item in
                            NavigationLink(value: Route.recordingSummary(item.recording.id)) {
                                Label(item.summary.title.isEmpty ? RecordingText.title(item.recording) : item.summary.title,
                                      systemImage: "doc.text")
                                    .foregroundStyle(Theme.ink)
                            }
                        }
                    }
                    Button(answer.isStreaming ? "停止" : "清除回答") { questions.clear() }
                        .font(.subheadline)
                }
            } else {
                NavigationLink(value: Route.assistant) {
                    Label("填上你的 AI 服务后，可以问所有录音", systemImage: "sparkles")
                        .foregroundStyle(Theme.ink)
                }
            }
        } header: {
            Text("问问你的录音").textCase(nil)
        } footer: {
            if questions.isConfigured { Text(questions.privacyNote) }
        }
        .surfaceRows()
    }
}

/// A summary: its title, its first lines, and when the recording was made.
private struct SummaryRow: View {
    let item: SummarizedRecording

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(item.summary.title.isEmpty ? RecordingText.title(item.recording) : item.summary.title)
                .font(.headline)
                .foregroundStyle(Theme.ink)
            if !item.summary.summary.isEmpty {
                Text(item.summary.summary)
                    .font(.subheadline)
                    .foregroundStyle(Theme.ink)
                    .lineLimit(2)
            }
            Text(RecordingText.dateTime(item.recording.startedAt))
                .font(.caption)
                .foregroundStyle(Theme.inkMuted)
                .monospacedDigit()
        }
    }
}
