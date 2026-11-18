import AppModel
import CardService
import Library
import SwiftUI

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
                case .recording(let id): RecordingDetailView(env: env, recordingId: id)
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
    @State private var showsSwitcher = false
    /// The full-screen recording page (design-spec.md §3).
    @State private var showsStage = false
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
                    NavigationLink(value: Route.settings) {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("设置")
                }
            }
            .refreshable { await model.refresh() }
            .safeAreaInset(edge: .bottom) { RecordControlBar(model: model) }
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
            } else if model.recordings.isEmpty {
                if showsEmptyState {
                    ContentUnavailableView("暂无录音", systemImage: "waveform",
                                           description: Text("按卡上的录音键，或点下方开始录音"))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                }
            } else {
                // One card per day (design-spec.md §3).
                ForEach(DayGroup.group(model.recordings)) { day in
                    Section {
                        ForEach(day.recordings, id: \.id) { recording in
                            NavigationLink(value: Route.recording(recording.id)) {
                                RecordingRow(recording: recording, deviceName: model.deviceName(for: recording))
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
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    /// The subtitle repeats the title's time; VoiceOver reads it once (#49).
    private var accessibilityText: String {
        var parts = [RecordingText.title(recording), RecordingText.duration(ms: recording.durationMs)]
        if let deviceName, !deviceName.isEmpty { parts.append(deviceName) }
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
