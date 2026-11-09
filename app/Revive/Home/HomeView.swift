import AppModel
import CardService
import Library
import SwiftUI

/// Navigation targets from home (product-spec.md §2.3). Pages pass ids only.
enum Route: Hashable {
    case recording(UUID)
    case device(UUID)
    case settings, about, privacy, permissions
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
                    HomeContent(model: model, path: $path)
                } else {
                    ContentUnavailableView(CardServiceError.bluetoothUnsupported.userText ?? "",
                                           systemImage: "exclamationmark.triangle")
                }
            }
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .recording(let id): RecordingDetailView(env: env, recordingId: id)
                case .device(let id): DeviceView(env: env, deviceId: id)
                case .settings: SettingsView()
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
    @Binding var path: [Route]
    @State private var pendingDelete: Recording?
    /// The "全部完成" card folds into a check mark next to the title after 3 s.
    @State private var doneCollapsed = false

    var body: some View {
        list
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    // P08 (switch cards from the chevron) comes in batch 3c; the chip opens P07 for now.
                    if let device = model.currentDevice {
                        NavigationLink(value: Route.device(device.id)) {
                            DeviceChip(device: device, status: model.status, battery: model.battery)
                        }
                        .buttonStyle(.plain)
                    } else {
                        DeviceChip(device: nil, status: model.status, battery: model.battery)
                    }
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
            .confirmationDialog("删除这条录音？", isPresented: deleteBinding, titleVisibility: .visible,
                                presenting: pendingDelete) { recording in
                Button("删除录音", role: .destructive) { model.delete(recording.id) }
            } message: { _ in
                Text("只删除手机上的这条录音，录音卡不受影响。")
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
            .toast($model.toast)
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
                    RecordingStatusCard(model: model)
                }
                if let card = model.syncCard, !(isDone(card) && doneCollapsed) {
                    SyncStatusCard(card: card) { model.retrySync() }
                }
            }
            .listRowSeparator(.hidden)

            if let error = model.loadError {
                ContentUnavailableView {
                    Label("无法读取录音", systemImage: "exclamationmark.triangle")
                } description: {
                    Text("本机录音库读取失败，卡上的录音不受影响。")
                } actions: {
                    ShareLink(item: error) { Text("导出诊断信息") }
                }
                .listRowSeparator(.hidden)
            } else if model.recordings.isEmpty {
                if showsEmptyState {
                    ContentUnavailableView("暂无录音", systemImage: "waveform",
                                           description: Text("按卡上的录音键，或点下方开始录音"))
                        .listRowSeparator(.hidden)
                }
            } else {
                Section {
                    ForEach(model.recordings, id: \.id) { recording in
                        NavigationLink(value: Route.recording(recording.id)) {
                            RecordingRow(recording: recording, deviceName: model.deviceName(for: recording))
                        }
                        .swipeActions {
                            // No destructive role: it animates the row away before the user confirms.
                            Button("删除") { pendingDelete = recording }
                                .tint(.red)
                        }
                    }
                }
            }
        }
        .listStyle(.plain)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("全部录音 (\(model.recordings.count))")
                .font(.largeTitle.bold())
            if let card = model.syncCard, isDone(card), doneCollapsed {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
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

private struct RecordingRow: View {
    let recording: Recording
    let deviceName: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(RecordingText.title(recording))
                .font(.body)
                .lineLimit(1)
            Text(RecordingText.subtitle(recording, deviceName: deviceName))
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

/// Banner for a Bluetooth problem; the list stays usable (product-spec.md §4.3 P05).
private struct BluetoothBanner: View {
    let problem: CardServiceError

    var body: some View {
        HStack {
            Label(problem.userText ?? "", systemImage: "antenna.radiowaves.left.and.right.slash")
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
        .background(Color.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 12))
    }
}
