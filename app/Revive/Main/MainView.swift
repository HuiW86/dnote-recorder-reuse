import AppModel
import CardService
import Library
import SwiftUI

/// The four tabs under the bottom bar (#89, product-spec.md §2.2).
enum MainTab: String, Hashable, CaseIterable {
    case overview, recordings, knowledge, card

    var title: String {
        switch self {
        case .overview: "总览"
        case .recordings: "录音"
        case .knowledge: "知识库"
        case .card: "录音卡"
        }
    }

    var symbol: String {
        switch self {
        case .overview: "house"
        case .recordings: "waveform"
        case .knowledge: "books.vertical"
        case .card: "rectangle.portrait"
        }
    }
}

/// After pairing, or after 先不连卡 on P01: the tabs, the bottom bar with the record key in its middle, and what every tab
/// shares (the recording page, prompts, "留着 / 不要", toasts). Each tab keeps its own
/// navigation stack.
struct MainView: View {
    let env: AppEnvironment
    @State private var model: HomeModel?
    @State private var overview: OverviewModel?
    @State private var questions: LibraryQuestionModel?

    var body: some View {
        Group {
            if let model, let overview, let questions {
                MainContent(model: model, overview: overview, questions: questions, env: env)
            } else {
                ContentUnavailableView(CardServiceError.bluetoothUnsupported.userText ?? "",
                                       systemImage: "exclamationmark.triangle")
                    .paperPage()
            }
        }
        .onAppear {
            // The real Bluetooth stack, or for 先不连卡 one that never asks for Bluetooth.
            if model == nil, let session = env.mainSession() {
                model = HomeModel(session: session, preferences: env.preferences, player: env.player)
            }
            if overview == nil, let library = env.library {
                overview = OverviewModel(library: library)
            }
            if questions == nil, let library = env.library {
                questions = LibraryQuestionModel(library: library, assistant: env.assistantConfig)
            }
            model?.start()
            overview?.start()
        }
    }
}

private struct MainContent: View {
    @Bindable var model: HomeModel
    let overview: OverviewModel
    let questions: LibraryQuestionModel
    let env: AppEnvironment
    @State private var tab: MainTab = LaunchOptions.startTab ?? .overview
    @State private var paths: [MainTab: [Route]] = [:]
    @State private var showsSwitcher = false
    /// The full-screen recording page (design-spec.md §3).
    @State private var showsStage = false
    /// Recording with the phone's microphone (features.md X18).
    @State private var showsPhoneStage = false
    @State private var phoneConsent = false
    /// The record key was tapped while the card cannot record.
    @State private var offersPhone = false
    /// A phone recording is starting (microphone permission, storage check): a second tap waits.
    @State private var startingPhone = false

    var body: some View {
        // The bar sits below the pages, not over them. A safe-area inset on the outside does not
        // reach pages inside a TabView or a NavigationStack (both are UIKit containers), so the
        // bar covered the detail page's player on iPhone 16 (#89 evidence). Here the pages end
        // above the bar. All four stacks stay alive, so each tab keeps its place.
        VStack(spacing: 0) {
            ZStack {
                ForEach(MainTab.allCases, id: \.self) { item in
                    let selected = item == tab
                    NavigationStack(path: path(item)) {
                        root(item)
                            .navigationDestination(for: Route.self) { route in
                                RouteDestination(route: route, env: env, model: model, path: path(item))
                            }
                    }
                    .opacity(selected ? 1 : 0)
                    .allowsHitTesting(selected)
                    .accessibilityHidden(!selected)
                }
            }
            BottomBar(tab: $tab, model: model, phone: env.phoneRecorder) { recordKeyTapped() }
        }
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .overlay(alignment: .top) {
            // "留着 / 不要" floats over every tab (features.md X10).
            if let finished = model.justRecorded, !showsStage {
                KeepOrDiscardCard(finished: finished, keep: { model.keepJustRecorded() },
                                  discard: { model.discardJustRecorded() })
                    .shadow(color: Theme.shadow, radius: 12, y: 4)
                    .padding(.horizontal, 16)
                    .padding(.top, 4)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.default, value: model.justRecorded)
        .toast($model.toast) { model.undoDelete() }
        .fullScreenCover(isPresented: $showsStage) {
            RecordingStage(model: model) { showsStage = false }
        }
        .fullScreenCover(isPresented: $showsPhoneStage) {
            if let recorder = env.phoneRecorder {
                PhoneRecordingStage(recorder: recorder, collapse: { showsPhoneStage = false }) {
                    showsPhoneStage = false
                    if let toast = recorder.toast { model.toast = toast }
                }
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
        .confirmationDialog(offerTitle,
                            isPresented: $offersPhone, titleVisibility: .visible) {
            if env.phoneRecorder != nil {
                Button("用这部手机录") { startPhoneRecording() }
            }
            if model.status == .noDevice {
                Button("添加录音卡") { addCard() }
            }
            if model.session.bluetoothProblem == .bluetoothUnauthorized {
                Button("去设置允许蓝牙") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            switch model.status {
            case .noDevice: Text("有录音卡时，点「添加录音卡」开始连接。")
            case .connecting: Text("稍等片刻，或先用这部手机录。")
            case .bluetoothUnavailable:
                Text((model.session.bluetoothProblem?.userText ?? "暂时连不上录音卡") + "。\n也可以先用这部手机录。")
            default: Text("按住卡上的录音键，白灯闪烁后松手即可连接。也可以先用这部手机录。")
            }
        }
        .alert(model.prompt?.title ?? "", isPresented: promptBinding, presenting: model.prompt) { prompt in
            Button(prompt.actionTitle) {
                switch prompt {
                case .repair:
                    model.repairTapped()
                    paths[tab, default: []].append(.pairing)
                case .rescan:
                    model.prompt = nil
                    paths[tab, default: []].append(.connectGuide)
                }
            }
            Button("取消", role: .cancel) {}
        } message: { prompt in
            Text(prompt.message)
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
        // Audio shared from another app (features.md E2): imported like a pick from Files. Waits
        // here through first use, so it is not lost before a card is paired.
        .onChange(of: env.incomingAudio, initial: true) { _, urls in
            guard !urls.isEmpty, !model.isImporting else { return }
            env.incomingAudio = []
            tab = .recordings
            Task {
                let opened = urls.filter { $0.startAccessingSecurityScopedResource() }
                defer {
                    opened.forEach { $0.stopAccessingSecurityScopedResource() }
                    // The system's Inbox copies are ours to remove once imported.
                    urls.filter { $0.path.contains("/Inbox/") }.forEach { try? FileManager.default.removeItem(at: $0) }
                }
                await model.importAudio(urls)
            }
        }
        // A tapped sync notification about one recording opens it in 录音 (#85).
        .onChange(of: env.notifications.recordingToOpen, initial: true) { _, id in
            guard let id else { return }
            env.notifications.recordingToOpen = nil
            tab = .recordings
            paths[.recordings] = [.recording(id)]
        }
        // A collapsed phone recording that stopped on its own (out of space) still says so.
        .onChange(of: env.phoneRecorder?.isSaving) { wasSaving, saving in
            guard wasSaving == true, saving == false, !showsPhoneStage,
                  let toast = env.phoneRecorder?.toast else { return }
            model.toast = toast
        }
        .task {
            // A phone recording cut off last time (the app was killed while recording) is
            // stored now, and the user is told (features.md X18).
            if let recorder = env.phoneRecorder, await recorder.recoverUnfinished() > 0, let toast = recorder.toast {
                model.toast = toast
            }
        }
        .task {
            // DEBUG launch arguments for screenshots (scripts/shots.sh); nil in release builds.
            if let id = LaunchOptions.openRecording(in: model.recordings) {
                paths[tab, default: []].append(.recording(id))
            }
        }
    }

    @ViewBuilder private func root(_ item: MainTab) -> some View {
        switch item {
        case .overview:
            OverviewView(model: model, overview: overview, env: env) {
                model.showOnly(.untranscribed)
                paths[.recordings] = []
                tab = .recordings
            }
        case .recordings:
            RecordingsView(model: model, env: env, showsSwitcher: $showsSwitcher, showsStage: $showsStage,
                           openCard: { tab = .card })
        case .knowledge:
            KnowledgeView(model: model, overview: overview, questions: questions, env: env)
        case .card:
            CardTabView(model: model, env: env, showsSwitcher: $showsSwitcher)
        }
    }

    private func path(_ item: MainTab) -> Binding<[Route]> {
        Binding(get: { paths[item] ?? [] }, set: { paths[item] = $0 })
    }

    /// The record key: start on the card, go back to the recording page, or offer the phone.
    private func recordKeyTapped() {
        if let phone = env.phoneRecorder, phone.state != .idle || phone.isSaving {
            showsPhoneStage = true
            return
        }
        switch model.status {
        case .recording, .paused:
            showsStage = true
        case .idle:
            model.startTapped()
        case _ where model.currentDevice == nil && env.phoneRecorder != nil:
            // No card to ask about (Bluetooth off or not): the key records on the phone, as the
            // empty pages say.
            startPhoneRecording()
        default:
            offersPhone = true
        }
    }

    /// "添加录音卡" with no card: through P01 for 先不连卡 (no Bluetooth stack yet), otherwise
    /// P02 → P03 in the 录音卡 tab.
    private func addCard() {
        if env.isCardless {
            env.addFirstCard()
        } else {
            tab = .card
            paths[.card] = [.connectGuide]
        }
    }

    /// Asks for consent once (P04), then starts the phone recorder and opens its page.
    private func startPhoneRecording() {
        guard let recorder = env.phoneRecorder else { return }
        guard env.preferences.recordingConsentGiven else {
            phoneConsent = true
            return
        }
        guard !startingPhone else { return }
        startingPhone = true
        // An old recording still playing would be heard by the microphone (X18).
        env.player?.stop()
        Task {
            defer { startingPhone = false }
            if await recorder.start() {
                showsPhoneStage = true
            } else if let toast = recorder.toast {
                model.toast = toast
            }
        }
    }

    private var offerTitle: String {
        switch model.status {
        case .noDevice: "还没有录音卡"
        case .connecting: "正在连接录音卡"
        case .bluetoothUnavailable: "蓝牙不可用"
        default: "录音卡还没连上"
        }
    }

    private var promptBinding: Binding<Bool> {
        Binding(get: { model.prompt != nil }, set: { if !$0 { model.prompt = nil } })
    }
}

/// Where a `Route` leads; the same in every tab.
struct RouteDestination: View {
    let route: Route
    let env: AppEnvironment
    let model: HomeModel
    @Binding var path: [Route]

    var body: some View {
        switch route {
        case .recording(let id):
            RecordingDetailView(env: env, recordingId: id) { model.offerUndo(forTrashed: $0) }
        case .recordingSummary(let id):
            RecordingDetailView(env: env, recordingId: id, initialPane: .summary) { model.offerUndo(forTrashed: $0) }
        case .device(let id): DeviceView(env: env, deviceId: id)
        case .settings: SettingsView(diagnostics: env.diagnostics, preferences: env.preferences, account: env.account)
        case .trash: TrashView(env: env)
        case .assistant: AssistantSettingsView(preferences: env.preferences)
        case .corrections: CorrectionsView(env: env)
        case .account:
            if let session = env.account {
                AccountView(session: session) { account, deleted in
                    AccountAI.leave(account, deleted: deleted, preferences: env.preferences, library: env.library)
                }
            }
        case .tags: TagsView(env: env)
        case .tag(let name): TagRecordingsView(env: env, tag: name, model: model, path: $path)
        case .about: AboutView()
        case .privacy: PrivacyView()
        case .permissions: PermissionsView()
        case .connectGuide: ConnectGuideView { path.append(.pairing) }
        case .pairing: PairingView(env: env) { path.removeAll() }
        }
    }
}

/// Two tabs on each side and the red record key in the middle, in the same place on every tab
/// (#89). While recording, the key shows the recorded time and opens the recording page.
private struct BottomBar: View {
    @Binding var tab: MainTab
    let model: HomeModel
    /// A phone recording shows its time on the key too (features.md X18).
    let phone: PhoneRecorder?
    let recordTapped: () -> Void
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        HStack(alignment: .bottom, spacing: 0) {
            item(.overview)
            item(.recordings)
            recordKey.frame(maxWidth: .infinity)
            item(.knowledge)
            item(.card)
        }
        .padding(.horizontal, 8)
        .padding(.top, 6)
        // Like the system tab bar: the bar stops growing at the largest standard size.
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .background(Theme.surface)
        .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) }
    }

    private func item(_ value: MainTab) -> some View {
        let selected = tab == value
        return Button { tab = value } label: {
            VStack(spacing: 3) {
                Image(systemName: value.symbol)
                    .font(.system(size: 20, weight: selected ? .semibold : .regular))
                    .frame(height: 26)
                // Accessibility text sizes show the icon only, as the system tab bar does;
                // a long press shows the title in the large content viewer.
                if !typeSize.isAccessibilitySize {
                    Text(value.title)
                        .font(.caption2.weight(.medium))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
            }
            .foregroundStyle(selected ? Theme.accent : Theme.inkMuted)
            .frame(maxWidth: .infinity, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(value.title)
        .accessibilityShowsLargeContentViewer {
            Label(value.title, systemImage: value.symbol)
        }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var phoneRecording: Bool { phone.map { $0.state != .idle } ?? false }
    private var isRecording: Bool { phoneRecording || model.status == .recording || model.status == .paused }
    private var isPaused: Bool { phoneRecording ? phone?.state == .paused : model.status == .paused }

    private func seconds(at date: Date) -> Int? {
        if phoneRecording, let phone { return Int(phone.elapsed) }
        return model.recordedSeconds(at: date)
    }

    private var recordKey: some View {
        let busy = model.pendingCommand == .start || model.status == .connecting
        return Button(action: recordTapped) {
            ZStack {
                Circle()
                    .fill(Theme.record)
                    .frame(width: 60, height: 60)
                    .shadow(color: Theme.shadow, radius: 8, y: 4)
                if isRecording {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(seconds(at: context.date).map { RecordingText.clock(seconds: $0) } ?? "")
                            .font(.caption2.weight(.bold).monospacedDigit())
                            .minimumScaleFactor(0.6)
                            .lineLimit(1)
                            .foregroundStyle(Theme.onDark.opacity(isPaused ? 0.6 : 1))
                            .padding(.horizontal, 6)
                    }
                    .frame(width: 60, height: 60)
                } else if busy {
                    ProgressView().tint(Theme.onDark)
                } else {
                    Circle().fill(Theme.onDark).frame(width: 20, height: 20)
                }
            }
            // A little higher than the tabs beside it, so it reads as the one action.
            .offset(y: -8)
        }
        .buttonStyle(.plain)
        .disabled(model.pendingCommand != nil && !phoneRecording)
        .accessibilityLabel(isRecording ? "正在录音，回到录音画面" : "开始录音")
    }
}
