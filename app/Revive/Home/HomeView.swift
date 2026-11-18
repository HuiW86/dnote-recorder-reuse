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
    /// 最近删除 (features.md D1b), from settings.
    case trash
    /// 设置 → AI 服务 (features.md X11).
    case assistant
    /// P02 → P03 from home: "重新搜索" after `unknownCard`; "重新配对" goes to P03 directly.
    case connectGuide, pairing
}

/// P05 home: recording list with device, recording and sync status (product-spec.md §4.2).
struct HomeView: View {
    let env: AppEnvironment
    @State private var model: HomeModel?
    @State private var path: [Route] = []

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if let model {
                    HomeContent(model: model, env: env, path: $path)
                } else {
                    ContentUnavailableView(CardServiceError.bluetoothUnsupported.userText ?? "",
                                           systemImage: "exclamationmark.triangle")
                        .paperPage()
                }
            }
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .recording(let id):
                    RecordingDetailView(env: env, recordingId: id) { model?.offerUndo(forTrashed: $0) }
                case .device(let id): DeviceView(env: env, deviceId: id)
                case .settings: SettingsView(diagnostics: env.diagnostics, preferences: env.preferences)
                case .trash: TrashView(env: env)
                case .assistant: AssistantSettingsView(preferences: env.preferences)
                case .about: AboutView()
                case .privacy: PrivacyView()
                case .permissions: PermissionsView()
                case .connectGuide: ConnectGuideView { path.append(.pairing) }
                case .pairing: PairingView(env: env) { path.removeAll() }
                }
            }
        }
        .onAppear {
            if model == nil, let session = env.startBluetooth() {
                model = HomeModel(session: session, preferences: env.preferences, player: env.player)
            }
            model?.start()
        }
    }
}

private struct HomeContent: View {
    @Bindable var model: HomeModel
    let env: AppEnvironment
    @Binding var path: [Route]
    @State private var pendingDelete: Recording?
    @State private var query = ""
    @State private var showsSwitcher = false
    /// The full-screen recording page (design-spec.md §3).
    @State private var showsStage = false
    /// Recording with the phone's microphone (features.md X18).
    @State private var showsPhoneStage = false
    @State private var phoneConsent = false
    /// Files picker for importing audio (features.md E2).
    @State private var importing = false
    @State private var folderBeingRenamed: Folder?
    @State private var folderName = ""
    /// The "全部完成" card folds into a check mark next to the title after 3 s.
    @State private var doneCollapsed = false

    var body: some View {
        list
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    DeviceChip(device: model.currentDevice, status: model.status, battery: model.battery,
                               openDevice: { model.currentDevice.map { path.append(.device($0.id)) } },
                               openSwitcher: { showsSwitcher = true })
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { importing = true } label: {
                        if model.isImporting {
                            ProgressView()
                        } else {
                            Image(systemName: "square.and.arrow.down")
                        }
                    }
                    .disabled(model.isImporting)
                    .accessibilityLabel("导入音频文件")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink(value: Route.settings) {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("设置")
                }
            }
            .searchable(text: $query, prompt: "搜索标题、文字稿、纪要")
            .onChange(of: query) { _, text in model.search(text) }
            // The list changed (a sync, a delete): refresh what the search shows.
            .onChange(of: model.recordings) { _, _ in
                if !query.isEmpty { model.search(query) }
                // A recording may have been moved into a new folder on its page.
                model.refreshFolders()
            }
            .refreshable { await model.refresh() }
            .safeAreaInset(edge: .bottom) {
                RecordControlBar(model: model, recordWithPhone: env.phoneRecorder == nil ? nil : { startPhoneRecording() })
            }
            .fullScreenCover(isPresented: $showsPhoneStage) {
                if let recorder = env.phoneRecorder {
                    PhoneRecordingStage(recorder: recorder) {
                        showsPhoneStage = false
                        if let toast = recorder.toast { model.toast = toast }
                    }
                }
            }
            .alert("重命名文件夹", isPresented: Binding(get: { folderBeingRenamed != nil },
                                                     set: { if !$0 { folderBeingRenamed = nil } })) {
                TextField("文件夹名称", text: $folderName)
                Button("保存") { if let folder = folderBeingRenamed { model.renameFolder(folder, to: folderName) } }
                Button("取消", role: .cancel) {}
            }
            .onAppear { model.refreshFolders() }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.audio], allowsMultipleSelection: true) { result in
                guard case .success(let urls) = result else { return }
                Task {
                    // Files outside the app's container are readable only inside their security scope.
                    let opened = urls.filter { $0.startAccessingSecurityScopedResource() }
                    defer { opened.forEach { $0.stopAccessingSecurityScopedResource() } }
                    await model.importAudio(urls)
                }
            }
            .sheet(isPresented: $phoneConsent) {
                ConsentSheet {
                    env.preferences.recordingConsentGiven = true
                    phoneConsent = false
                    startPhoneRecording()
                }
            }
            .sheet(isPresented: $model.showsConsent) {
                ConsentSheet { model.consentConfirmed() }
            }
            // Adding a card on P08 drops the current one; if the new one was not paired, wait for
            // the current card again.
            .sheet(isPresented: $showsSwitcher, onDismiss: { model.start() }) {
                DeviceSwitcherSheet(model: model, env: env)
            }
            .confirmationDialog("删除这条录音？", isPresented: deleteBinding, titleVisibility: .visible,
                                presenting: pendingDelete) { recording in
                Button("删除录音", role: .destructive) { model.delete(recording.id) }
            } message: { _ in
                Text("录音会移到「最近删除」，保留 7 天。录音卡不受影响。")
            }
            .alert(model.prompt?.title ?? "", isPresented: promptBinding, presenting: model.prompt) { prompt in
                Button(prompt.actionTitle) {
                    switch prompt {
                    case .repair:
                        model.repairTapped()
                        path.append(.pairing)
                    case .rescan:
                        model.prompt = nil
                        path.append(.connectGuide)
                    }
                }
                Button("取消", role: .cancel) {}
            } message: { prompt in
                Text(prompt.message)
            }
            .toast($model.toast) { model.undoDelete() }
            .fullScreenCover(isPresented: $showsStage) {
                RecordingStage(model: model) { showsStage = false }
            }
            .onChange(of: model.status) { old, new in
                let wasRecording = old == .recording || old == .paused
                let isRecording = new == .recording || new == .paused
                if isRecording, !wasRecording, !model.showsConsent, !showsSwitcher {
                    showsStage = true
                } else if !isRecording {
                    showsStage = false
                }
            }
            .task(id: model.syncCard) {
                doneCollapsed = false
                guard case .done = model.syncCard else { return }
                try? await Task.sleep(for: .seconds(3))
                withAnimation { doneCollapsed = true }
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
                if let finished = model.justRecorded {
                    KeepOrDiscardCard(finished: finished, keep: { model.keepJustRecorded() },
                                      discard: { model.discardJustRecorded() })
                }
                if let card = model.syncCard, !(isDone(card) && doneCollapsed) {
                    SyncStatusCard(card: card, diagnostics: model.session.diagnostics) { model.retrySync() }
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
            } else if let results = model.searchResults {
                // Search (features.md D2): one flat card, newest first.
                if results.isEmpty {
                    ContentUnavailableView.search(text: query)
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                } else {
                    Section {
                        ForEach(results, id: \.id) { recording in
                            NavigationLink(value: Route.recording(recording.id)) {
                                RecordingRow(recording: recording, deviceName: model.deviceName(for: recording),
                                             markCount: model.markCount(for: recording))
                            }
                        }
                    } header: {
                        Text("找到 \(results.count) 条").textCase(nil)
                    }
                    .surfaceRows()
                }
            } else if model.recordings.isEmpty {
                if showsEmptyState {
                    ContentUnavailableView("暂无录音", systemImage: "waveform",
                                           description: Text("按卡上的录音键，或点下方开始录音"))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                }
            } else {
                if model.filteredRecordings.isEmpty {
                    ContentUnavailableView("没有符合条件的录音", systemImage: "line.3.horizontal.decrease.circle")
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                }
                // One card per day (design-spec.md §3).
                ForEach(DayGroup.group(model.filteredRecordings)) { day in
                    Section {
                        ForEach(day.recordings, id: \.id) { recording in
                            NavigationLink(value: Route.recording(recording.id)) {
                                RecordingRow(recording: recording, deviceName: model.deviceName(for: recording),
                                             markCount: model.markCount(for: recording))
                            }
                            .swipeActions {
                                // No destructive role: it animates the row away before the user confirms.
                                Button("删除") { pendingDelete = recording }
                                    .tint(.red)
                            }
                        }
                    } header: {
                        Text(day.title).textCase(nil)
                    }
                    .surfaceRows()
                }
            }
        }
        .listStyle(.insetGrouped)
        .paperBackground()
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("全部录音 (\(model.recordings.count))")
                    .font(.largeTitle.bold())
                    .foregroundStyle(Theme.ink)
                if let card = model.syncCard, isDone(card), doneCollapsed {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Theme.ok)
                        .accessibilityLabel("全部录音已存入手机")
                }
            }
            .accessibilityAddTraits(.isHeader)
            if !model.recordings.isEmpty {
                filterChips
            }
        }
    }

    /// 全部 / 有重点 / 还没转文字 (design-spec.md §3 筛选项).
    private var filterChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(HomeModel.Filter.allCases) { filter in
                    let selected = model.filter == filter && (filter != .all || model.folderFilter == nil)
                    Button {
                        model.filter = filter
                        if filter == .all { model.folderFilter = nil }
                    } label: {
                        Text(filter.title)
                            .font(.subheadline.weight(selected ? .semibold : .regular))
                            .foregroundStyle(selected ? Theme.onDark : Theme.ink)
                            .padding(.horizontal, 16)
                            .frame(minHeight: 36)
                            .background(selected ? Theme.accent : Theme.surface, in: Capsule())
                            .overlay(Capsule().strokeBorder(selected ? Color.clear : Theme.line))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
                // Folders (features.md D1c): tap to show only that folder; hold for rename and delete.
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
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                    .contextMenu {
                        Button("重命名", systemImage: "pencil") {
                            folderBeingRenamed = folder
                            folderName = folder.name
                        }
                        Button("删除文件夹", systemImage: "trash", role: .destructive) { model.deleteFolder(folder) }
                    }
                }
            }
        }
    }

    /// Asks for consent once (P04), then starts the phone recorder and opens its page.
    private func startPhoneRecording() {
        guard let recorder = env.phoneRecorder else { return }
        guard env.preferences.recordingConsentGiven else {
            phoneConsent = true
            return
        }
        Task {
            if await recorder.start() {
                showsPhoneStage = true
            } else if let toast = recorder.toast {
                model.toast = toast
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

    private var promptBinding: Binding<Bool> {
        Binding(get: { model.prompt != nil }, set: { if !$0 { model.prompt = nil } })
    }

    private var deleteBinding: Binding<Bool> {
        Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })
    }
}

/// Recordings of one calendar day, newest day first, in the order the model gives them.
private struct DayGroup: Identifiable {
    let id: Date
    let title: String
    var recordings: [Recording]

    static func group(_ recordings: [Recording], calendar: Calendar = .current, now: Date = Date()) -> [DayGroup] {
        var groups: [DayGroup] = []
        for recording in recordings {
            let day = calendar.startOfDay(for: recording.startedAt)
            if let last = groups.indices.last, groups[last].id == day {
                groups[last].recordings.append(recording)
            } else {
                groups.append(DayGroup(id: day, title: title(day, calendar: calendar, now: now), recordings: [recording]))
            }
        }
        return groups
    }

    /// "今天", "昨天", "11月7日", and "2025年11月7日" for another year.
    private static func title(_ day: Date, calendar: Calendar, now: Date) -> String {
        if calendar.isDate(day, inSameDayAs: now) { return "今天" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(day, inSameDayAs: yesterday) { return "昨天" }
        let c = calendar.dateComponents([.year, .month, .day], from: day)
        let monthDay = "\(c.month ?? 0)月\(c.day ?? 0)日"
        return c.year == calendar.component(.year, from: now) ? monthDay : "\(c.year ?? 0)年" + monthDay
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
            if markCount > 0 {
                Label("\(markCount)", systemImage: "bookmark")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(Theme.inkMuted)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    /// The subtitle repeats the title's time; VoiceOver reads it once (#49).
    private var accessibilityText: String {
        var parts = [RecordingText.title(recording), RecordingText.duration(ms: recording.durationMs)]
        if let deviceName, !deviceName.isEmpty { parts.append(deviceName) }
        if markCount > 0 { parts.append("\(markCount) 处重点") }
        return parts.joined(separator: "，")
    }
}

/// Banner for a Bluetooth problem; the list stays usable (product-spec.md §4.3 P05).
private struct BluetoothBanner: View {
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
