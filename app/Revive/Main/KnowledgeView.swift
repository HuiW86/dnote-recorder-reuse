import AppModel
import Library
import SwiftUI

/// 知识库 (#89): search titles, transcripts and summaries on this phone, and the latest
/// summaries. Asking across recordings (features.md G3) is added here when it is built; no
/// placeholder until then.
struct KnowledgeView: View {
    @Bindable var model: HomeModel
    @Bindable var overview: OverviewModel
    let env: AppEnvironment
    @State private var query = ""

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
                    Text("录音转成文字、生成纪要后，会出现在这里。转文字可以打开本机转写，或者用你自己的 AI 服务。")
                } actions: {
                    NavigationLink("去设置", value: Route.settings)
                }
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            } else {
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
        .searchable(text: $query, prompt: "搜索标题、文字稿、纪要")
        .onChange(of: query) { _, text in model.search(text) }
        // The library changed (a sync, a delete): refresh what the search shows.
        .onChange(of: model.recordings) { _, _ in if !query.isEmpty { model.search(query) } }
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
