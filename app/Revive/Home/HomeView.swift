import AppModel
import CardService
import Library
import SwiftUI
import UniformTypeIdentifiers

/// Navigation targets from home (product-spec.md §2.3). Pages pass ids only.
enum Route: Hashable {
    case recording(UUID)
    case device(UUID)
    case settings, about, privacy, permissions
    /// The detail page opened on its 纪要 pane (a todo on 总览, a summary on 知识库).
    case recordingSummary(UUID)
    /// 最近删除 (features.md D1b), from settings.
    case trash
    /// 设置 → AI 服务 (features.md X11).
    case assistant
    /// 设置 → 纠错词库 (#75).
    case corrections
    /// 设置 → 账号 (features.md K1), only when the build names a server.
    case account
    /// 知识库 → 标签, and one tag's recordings (features.md D1c).
    case tags
    case tag(String)
    /// P02 → P03 from home: "重新搜索" after `unknownCard`; "重新配对" goes to P03 directly.
    case connectGuide, pairing
}

/// 录音 tab (P05, #89): the list by day with filters, the card and sync status. Search is on
/// 知识库; the record key and the shared prompts are in `MainView`.
struct RecordingsView: View {
    /// What 「文件」 offers: audio, and plain text or Markdown (features.md E2).
    static let importTypes: [UTType] = [UTType.audio, UTType.plainText] + [UTType(filenameExtension: "md")].compactMap { $0 }

    @Bindable var model: HomeModel
    let env: AppEnvironment
    @Binding var showsSwitcher: Bool
    @Binding var showsStage: Bool
    /// The card name on the chip opens the 录音卡 tab.
    let openCard: () -> Void
    /// Files picker for importing audio (features.md E2).
    @State private var importing = false
    /// 从链接导入 (features.md X12).
    @State private var importingLink = false
    @State private var folderBeingRenamed: Folder?
    @State private var folderName = ""
    /// Deleting a folder cannot be undone: it asks first.
    @State private var folderBeingDeleted: Folder?
    /// The "全部完成" card folds into a check mark next to the title after 3 s.
    @State private var doneCollapsed = false

    var body: some View {
        list
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    DeviceChip(device: model.currentDevice, status: model.status, battery: model.battery,
                               openDevice: openCard,
                               openSwitcher: { showsSwitcher = true })
                }
                ToolbarItem(placement: .topBarTrailing) {
                    // 文件 (features.md E2) or a podcast link (X12).
                    Menu {
                        Button { importing = true } label: {
                            Label("从「文件」导入", systemImage: "folder")
                        }
                        Button { importingLink = true } label: {
                            Label("从链接导入", systemImage: "link")
                        }
                    } label: {
                        if model.isImporting {
                            ProgressView()
                        } else {
                            Image(systemName: "square.and.arrow.down")
                        }
                    }
                    .disabled(model.isImporting)
                    .accessibilityLabel("导入")
                    .accessibilityHint("从「文件」导入音频或文字，或从播客链接导入")
                }
            }
            .refreshable { await model.refresh() }
            // Audio, or a text file that becomes a recording with no audio (features.md E2).
            .fileImporter(isPresented: $importing, allowedContentTypes: Self.importTypes,
                          allowsMultipleSelection: true) { result in
                guard case .success(let urls) = result else { return }
                Task {
                    // Files outside the app's container are readable only inside their security scope.
                    let opened = urls.filter { $0.startAccessingSecurityScopedResource() }
                    defer { opened.forEach { $0.stopAccessingSecurityScopedResource() } }
                    await model.importAudio(urls)
                }
            }
            .sheet(isPresented: $importingLink) {
                LinkImportSheet(model: LinkImportModel(library: model.session.library)) { title in
                    model.toast = Toast(title.isEmpty ? "已导入" : "已导入「\(title)」")
                }
            }
            .confirmationDialog(folderBeingDeleted.map { "删除文件夹「\($0.name)」？" } ?? "",
                                isPresented: Binding(get: { folderBeingDeleted != nil },
                                                     set: { if !$0 { folderBeingDeleted = nil } }),
                                titleVisibility: .visible, presenting: folderBeingDeleted) { folder in
                Button("删除文件夹", role: .destructive) { model.deleteFolder(folder) }
            } message: { _ in
                Text("里面的录音不会删除，仍可在「全部」里看到。")
            }
            .alert("重命名文件夹", isPresented: Binding(get: { folderBeingRenamed != nil },
                                                     set: { if !$0 { folderBeingRenamed = nil } })) {
                TextField("文件夹名称", text: $folderName)
                Button("保存") { if let folder = folderBeingRenamed { model.renameFolder(folder, to: folderName) } }
                Button("取消", role: .cancel) {}
            }
            .onAppear { model.refreshFolders() }
            // A recording may have been moved into a new folder on its page.
            .onChange(of: model.recordings) { _, _ in model.refreshFolders() }
            .task(id: model.syncCard) {
                doneCollapsed = false
                guard case .done = model.syncCard else { return }
                try? await Task.sleep(for: .seconds(3))
                // The card folds into the check beside the title: the same news, kept small.
                withMotion(Motion.standard) { doneCollapsed = true }
            }
    }

    private var list: some View {
        List {
            Section {
                header
                if let problem = model.session.bluetoothProblem {
                    BluetoothBanner(problem: problem)
                }
                if model.status == .recording || model.status == .paused {
                    Button { showsStage = true } label: {
                        RecordingStatusCard(model: model)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("打开录音页")
                }
                if let card = model.syncCard, !(isDone(card) && doneCollapsed) {
                    SyncStatusCard(card: card, diagnostics: model.session.diagnostics) { model.retrySync() }
                        .motionTransition(.fade)
                }
            }
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0))

            if let error = model.loadError {
                ContentUnavailableView {
                    Label("无法读取录音", systemImage: "exclamationmark.triangle")
                } description: {
                    Text("本机录音库读取失败，卡上的录音不受影响。")
                } actions: {
                    ShareLink(item: error) { Text("导出诊断信息") }
                }
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            } else if model.recordings.isEmpty {
                if showsEmptyState {
                    ContentUnavailableView("暂无录音", systemImage: "waveform",
                                           description: Text(model.currentDevice == nil
                                                             ? "点下方红色按钮用手机录，或点右上角导入音频和文字"
                                                             : "按卡上的录音键，或点下方红色按钮开始录音"))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                }
            } else {
                if model.filteredRecordings.isEmpty {
                    ContentUnavailableView {
                        Label("没有符合条件的录音", systemImage: "line.3.horizontal.decrease.circle")
                    } actions: {
                        Button("显示全部录音") { model.showAll() }
                    }
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                }
                // One card per day, with the day's count and length (design-spec.md §3, #89).
                ForEach(model.days) { day in
                    Section {
                        ForEach(day.recordings, id: \.id) { recording in
                            NavigationLink(value: Route.recording(recording.id)) {
                                RecordingRow(recording: recording, deviceName: model.deviceName(for: recording),
                                             markCount: model.markCount(for: recording))
                            }
                            .swipeActions {
                                // Straight to 最近删除; the toast offers "撤销" (the same as P06).
                                Button("删除", role: .destructive) { model.delete(recording.id) }
                            }
                            .swipeActions(edge: .leading) {
                                Button(recording.isStarred ? "取消星标" : "标星") { model.toggleStar(recording.id) }
                                    .tint(Theme.accent)
                            }
                        }
                    } header: {
                        HStack {
                            Text(day.title)
                            Spacer()
                            Text(day.countText).monospacedDigit()
                        }
                        .textCase(nil)
                    }
                    .surfaceRows()
                }
            }
        }
        .listStyle(.insetGrouped)
        .paperBackground()
        // What changes by itself at the top of the list: the sync card growing, shrinking and
        // going, the recording card and the Bluetooth banner. Not the filters (see the chips).
        .motion(Motion.standard, value: model.syncCard)
        .motion(Motion.standard, value: model.status == .recording || model.status == .paused)
        .motion(Motion.standard, value: model.session.bluetoothProblem)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("录音 (\(model.recordings.count))")
                    .font(.largeTitle.bold())
                    .foregroundStyle(Theme.ink)
                    .contentTransition(.numericText(value: Double(model.recordings.count)))
                if let card = model.syncCard, isDone(card), doneCollapsed {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Theme.ok)
                        .accessibilityLabel("全部录音已存入手机")
                        .motionTransition(.pop)
                }
            }
            .accessibilityAddTraits(.isHeader)
            if !model.recordings.isEmpty {
                filterChips
            }
        }
    }

    /// 全部 / 星标 / 有待办 / 有重点 / 还没转文字 (design-spec.md §3 筛选项, #89).
    private var filterChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(HomeModel.Filter.allCases) { filter in
                    let selected = model.filter == filter
                        && (filter != .all || (model.folderFilter == nil && model.sourceFilter == nil))
                    Button {
                        if filter == .all { model.showAll() } else { model.filter = filter }
                    } label: {
                        Text(filter.title)
                            .font(.subheadline.weight(selected ? .semibold : .regular))
                            .foregroundStyle(selected ? Theme.onDark : Theme.ink)
                            .padding(.horizontal, 16)
                            .frame(minHeight: 36)
                            .background(selected ? Theme.accent : Theme.surface, in: Capsule())
                            .overlay(Capsule().strokeBorder(selected ? Color.clear : Theme.line))
                            // Only the chip animates: the list below changes at once, as a
                            // long list re-laid out under an animation would stutter.
                            .motion(Motion.tap, value: selected)
                    }
                    .buttonStyle(.pressable)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
                // Sources (features.md D1c), only when the list has more than one.
                ForEach(model.sources, id: \.self) { source in
                    let selected = model.sourceFilter == source
                    Button { model.sourceFilter = selected ? nil : source } label: {
                        Text(RecordingText.sourceName(source))
                            .font(.subheadline.weight(selected ? .semibold : .regular))
                            .foregroundStyle(selected ? Theme.onDark : Theme.ink)
                            .padding(.horizontal, 14)
                            .frame(minHeight: 36)
                            .background(selected ? Theme.accent : Theme.surface, in: Capsule())
                            .overlay(Capsule().strokeBorder(selected ? Color.clear : Theme.line))
                            // Only the chip animates: the list below changes at once, as a
                            // long list re-laid out under an animation would stutter.
                            .motion(Motion.tap, value: selected)
                    }
                    .buttonStyle(.pressable)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
                // Folders (features.md D1c): tap to show only that folder; hold to rename or delete.
                ForEach(model.folders) { folder in
                    let selected = model.folderFilter == folder.id
                    Button { model.folderFilter = selected ? nil : folder.id } label: {
                        Label(folder.name, systemImage: "folder")
                            .font(.subheadline.weight(selected ? .semibold : .regular))
                            .foregroundStyle(selected ? Theme.onDark : Theme.ink)
                            .padding(.horizontal, 14)
                            .frame(minHeight: 36)
                            .background(selected ? Theme.accent : Theme.surface, in: Capsule())
                            .overlay(Capsule().strokeBorder(selected ? Color.clear : Theme.line))
                            // Only the chip animates: the list below changes at once, as a
                            // long list re-laid out under an animation would stutter.
                            .motion(Motion.tap, value: selected)
                    }
                    .buttonStyle(.pressable)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                    .contextMenu {
                        Button("重命名", systemImage: "pencil") {
                            folderBeingRenamed = folder
                            folderName = folder.name
                        }
                        Button("删除文件夹", systemImage: "trash", role: .destructive) { folderBeingDeleted = folder }
                    }
                }
            }
        }
    }

    /// No empty state during the first sync: the sync card already explains (product-spec.md P05).
    private var showsEmptyState: Bool {
        switch model.syncCard {
        case .checking?, .syncing?: false
        default: true
        }
    }

    private func isDone(_ card: SyncCard) -> Bool {
        if case .done = card { true } else { false }
    }

}

private struct RecordingRow: View {
    let recording: Recording
    let deviceName: String?
    var markCount = 0

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "waveform")
                .font(.body.weight(.semibold))
                .foregroundStyle(Theme.accent)
                .frame(width: 40, height: 40)
                .background(Theme.accentWash, in: RoundedRectangle(cornerRadius: Theme.Radius.control))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(RecordingText.title(recording))
                    .font(.headline)
                    .foregroundStyle(Theme.ink)
                Text(RecordingText.subtitle(recording, deviceName: deviceName))
                    .font(.subheadline)
                    .foregroundStyle(Theme.inkMuted)
                    .monospacedDigit()
            }
            Spacer(minLength: 0)
            if recording.isStarred {
                Image(systemName: "star.fill")
                    .font(.subheadline)
                    .foregroundStyle(Theme.accent)
                    .accessibilityHidden(true)
                    .motionTransition(.pop)
            }
            if markCount > 0 {
                Label("\(markCount)", systemImage: "bookmark")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(Theme.inkMuted)
            }
        }
        .padding(.vertical, 2)
        .motion(Motion.tap, value: recording.isStarred)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    /// The subtitle repeats the title's time; VoiceOver reads it once (#49).
    private var accessibilityText: String {
        var parts = [RecordingText.title(recording), RecordingText.duration(ms: recording.durationMs)]
        if let deviceName, !deviceName.isEmpty { parts.append(deviceName) }
        if recording.isStarred { parts.append("已标星") }
        if markCount > 0 { parts.append("\(markCount) 处重点") }
        return parts.joined(separator: "，")
    }
}

/// Banner for a Bluetooth problem; the list stays usable (product-spec.md §4.3 P05). Also on 总览.
struct BluetoothBanner: View {
    let problem: CardServiceError

    var body: some View {
        HStack {
            // A warning keeps the system orange, on the icon only (design-spec.md §2.1).
            Label {
                Text(problem.userText ?? "").foregroundStyle(Theme.ink)
            } icon: {
                Image(systemName: "antenna.radiowaves.left.and.right.slash").foregroundStyle(.orange)
            }
            .font(.subheadline)
            Spacer()
            if problem == .bluetoothUnauthorized {
                Button("去设置") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
                .font(.subheadline)
            }
        }
        .padding(12)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).strokeBorder(Theme.line))
    }
}
