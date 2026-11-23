import AppModel
import Library
import Player
import SwiftUI
import UniformTypeIdentifiers

/// The main window: recordings on the left, the chosen one on the right (ADR-011 step one).
struct LibraryWindow: View {
    @Bindable var model: LibraryBrowserModel
    let player: RecordingPlayer
    let env: MacEnvironment
    @State private var selection: UUID?
    @State private var importing = false
    @State private var importingLink = false

    var body: some View {
        NavigationSplitView {
            List(model.shown, id: \.id, selection: $selection) { recording in
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.rowTitle(recording)).lineLimit(1)
                    Text(model.rowSubtitle(recording)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                .padding(.vertical, 2)
            }
            .overlay {
                if model.shown.isEmpty {
                    if model.searchResults != nil {
                        ContentUnavailableView.search(text: model.query)
                    } else {
                        ContentUnavailableView("还没有录音", systemImage: "waveform",
                                               description: Text("点工具栏的「导入」或「从链接导入」，或把音频、文字文件拖进窗口。"))
                    }
                }
            }
            .searchable(text: $model.query, placement: .sidebar, prompt: "搜索标题、文字稿、纪要")
            .navigationSplitViewColumnWidth(min: 240, ideal: 300)
            .toolbar {
                ToolbarItem {
                    Button { importing = true } label: { Label("导入", systemImage: "square.and.arrow.down") }
                        .help("导入音频或文字文件")
                        .disabled(model.isImporting)
                }
                ToolbarItem {
                    Button { importingLink = true } label: { Label("从链接导入", systemImage: "link") }
                        .help("从播客单集链接、RSS 地址或音频地址导入")
                }
            }
        } detail: {
            if let id = selection, model.recordings.contains(where: { $0.id == id }) {
                RecordingPane(recordingId: id, library: model.library, player: player, env: env).id(id)
            } else {
                ContentUnavailableView("选一条录音", systemImage: "waveform",
                                       description: Text("这里只有这台 Mac 上的录音：可以导入音频、文字文件或播客链接。连接录音卡和同步还没有在 Mac 上验证，之后再加。"))
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: Self.importTypes,
                      allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            Task { await importPicked(urls) }
        }
        .sheet(isPresented: $importingLink) {
            LinkImportSheet(model: LinkImportModel(library: model.library)) { id, title in
                model.toast = Toast(title.isEmpty ? "已导入" : "已导入「\(title)」")
                selection = id
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            Task { await importPicked(urls) }
            return !urls.isEmpty
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
        .onAppear { model.start() }
    }

    /// Audio, plain text and Markdown (features.md E2).
    private static let importTypes: [UTType] = [.audio, .plainText] + [UTType(filenameExtension: "md")].compactMap { $0 }

    private func importPicked(_ urls: [URL]) async {
        let scoped = urls.filter { $0.startAccessingSecurityScopedResource() }
        defer { scoped.forEach { $0.stopAccessingSecurityScopedResource() } }
        await model.importFiles(urls)
    }
}
