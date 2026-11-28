import AppModel
import Library
import SwiftUI

/// 标签 (features.md D1c): every tag with how many recordings carry it. Tap for its recordings;
/// long-press or swipe to rename (a name already in use merges the two) or delete.
struct TagsView: View {
    let env: AppEnvironment
    @State private var model: TagsModel?

    var body: some View {
        Group {
            if let model {
                TagList(model: model)
            } else {
                ProgressView().paperPage()
            }
        }
        .navigationTitle("标签")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if model == nil, let library = env.library { model = TagsModel(library: library) }
            model?.reload()
        }
    }
}

private struct TagList: View {
    @Bindable var model: TagsModel
    @State private var renaming: String?
    @State private var newName = ""
    /// Asks first, as the tag's own page does: it changes every summary that has it.
    @State private var deleting: String?

    var body: some View {
        List {
            if model.tags.isEmpty {
                ContentUnavailableView("还没有标签", systemImage: "tag",
                                       description: Text("生成纪要时，AI 服务会给录音加上主题标签。"))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            } else {
                Section {
                    ForEach(model.tags) { tag in
                        NavigationLink(value: Route.tag(tag.name)) {
                            HStack {
                                Text("# " + tag.name).foregroundStyle(Theme.ink)
                                Spacer()
                                Text("\(tag.count) 条").foregroundStyle(Theme.inkMuted).monospacedDigit()
                            }
                        }
                        .accessibilityLabel("标签 \(tag.name)，\(tag.count) 条录音")
                        .swipeActions {
                            Button("删除") { deleting = tag.name }.tint(.red)
                            Button("重命名") { startRename(tag.name) }
                        }
                        .contextMenu {
                            Button("重命名", systemImage: "pencil") { startRename(tag.name) }
                            Button("删除标签", systemImage: "trash", role: .destructive) { deleting = tag.name }
                        }
                    }
                } footer: {
                    Text("改成已有的名字会把两个标签合并。以后生成的纪要也会按你的修改处理；删除标签不会删除录音。")
                }
                .surfaceRows()
            }
        }
        .listStyle(.insetGrouped)
        .paperBackground()
        .toast($model.toast)
        .alert("重命名标签", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("标签名", text: $newName)
            Button("保存") { if let tag = renaming { model.rename(tag, to: newName) } }
            Button("取消", role: .cancel) {}
        } message: {
            Text("改成已有的名字会合并两个标签。")
        }
        .confirmationDialog(deleting.map { "删除标签「\($0)」？" } ?? "",
                            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible, presenting: deleting) { tag in
            Button("删除标签", role: .destructive) { model.delete(tag) }
        } message: { _ in
            Text("只从纪要里去掉这个标签，录音和纪要都还在。以后生成的纪要也不会再加它。")
        }
    }

    private func startRename(_ tag: String) {
        newName = tag
        renaming = tag
    }
}

/// The recordings one tag is on, newest first; each opens on its 纪要.
struct TagRecordingsView: View {
    let env: AppEnvironment
    let tag: String
    let model: HomeModel
    @Binding var path: [Route]
    @State private var tags: TagsModel?
    @State private var recordings: [Recording] = []
    @State private var renaming = false
    @State private var newName = ""
    @State private var confirmingDelete = false

    var body: some View {
        List {
            if recordings.isEmpty {
                ContentUnavailableView("没有带这个标签的录音", systemImage: "tag")
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            } else {
                Section {
                    ForEach(recordings, id: \.id) { recording in
                        NavigationLink(value: Route.recordingSummary(recording.id)) {
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
                    Text("\(recordings.count) 条").textCase(nil)
                }
                .surfaceRows()
            }
        }
        .listStyle(.insetGrouped)
        .paperBackground()
        .navigationTitle("# " + tag)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("重命名", systemImage: "pencil") {
                        newName = tag
                        renaming = true
                    }
                    Button("删除标签", systemImage: "trash", role: .destructive) { confirmingDelete = true }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("更多")
            }
        }
        .alert("重命名标签", isPresented: $renaming) {
            TextField("标签名", text: $newName)
            Button("保存") { rename() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("改成已有的名字会合并两个标签。")
        }
        .confirmationDialog("删除标签「\(tag)」？", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("删除标签", role: .destructive) {
                tags?.delete(tag)
                // This page goes away; the toast shows over the tabs instead.
                if let toast = tags?.toast { model.toast = toast }
                if !path.isEmpty { path.removeLast() }
            }
        } message: {
            Text("只从纪要里去掉这个标签，录音和纪要都还在。以后生成的纪要也不会再加它。")
        }
        .onAppear {
            if tags == nil, let library = env.library { tags = TagsModel(library: library) }
            recordings = tags?.recordings(taggedWith: tag) ?? []
        }
    }

    /// After a rename this page shows the tag under its new name.
    private func rename() {
        guard let tags else { return }
        let new = tags.rename(tag, to: newName)
        if let toast = tags.toast { model.toast = toast }
        if let new, !path.isEmpty { path[path.count - 1] = .tag(new) }
    }
}
