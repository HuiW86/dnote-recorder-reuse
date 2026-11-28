import AppModel
import CardProtocol
import SwiftUI

/// P07 device page (product-spec.md §4.2): official grouping and order; settings only while
/// connected; no firmware update, factory reset, USB mode or power-off (CLAUDE.md rule 1).
struct DeviceView: View {
    let env: AppEnvironment
    let deviceId: UUID
    /// The 录音卡 tab (#89): says the phone can record without the card while it is not connected.
    var isTab = false
    @State private var model: DeviceModel?

    var body: some View {
        Group {
            if let model {
                DeviceContent(env: env, model: model, isTab: isTab)
            } else {
                ProgressView().paperPage()
            }
        }
        .navigationTitle(model?.device?.name ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if model == nil, let session = env.startBluetooth() {
                model = DeviceModel(session: session, preferences: env.preferences, deviceId: deviceId)
            }
        }
    }
}

private struct DeviceContent: View {
    let env: AppEnvironment
    @Bindable var model: DeviceModel
    var isTab = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var renaming = false
    @State private var newName = ""
    @State private var confirmingUnpair = false
    @State private var confirmingDeleteAfterSync = false

    var body: some View {
        List {
            if model.firmwareUnverified {
                // Unverified firmware is a warning: system orange (design-spec.md §2.1, CLAUDE.md rule 7).
                Label(FirmwareText.unverified, systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline)
                    .foregroundStyle(.orange)
                    .surfaceRows()
            }
            if isTab, !model.isConnected, env.phoneRecorder != nil {
                Label("录音卡不在身边也能录：点下方红色按钮，选「用这部手机录」。", systemImage: "mic")
                    .font(.subheadline)
                    .foregroundStyle(Theme.ink)
                    .surfaceRows()
            }
            general
            if model.isConnected {
                settings
            } else {
                Section {
                    Text(model.canReconnect
                         ? "已断开连接。点下方「重新连接」，连上后可修改设置。"
                         : "未连接录音卡。按住卡上的录音键，白灯闪烁后松手，连上后可修改设置。")
                        .foregroundStyle(Theme.inkMuted)
                }
                .surfaceRows()
            }
            actions
        }
        .listStyle(.insetGrouped)
        .paperBackground()
        .task(id: model.isConnected) { await model.load() }
        .toast($model.toast)
        .alert("名称", isPresented: $renaming) {
            TextField("录音卡名称", text: $newName)
            Button("取消", role: .cancel) {}
            Button("保存") { model.rename(newName) }
        } message: {
            Text("只改这部手机上显示的名称。")
        }
        .alert("解绑此卡？", isPresented: $confirmingUnpair) {
            Button("取消", role: .cancel) {}
            Button("解绑", role: .destructive) {
                Task {
                    guard await model.unpair() else { return }
                    env.refreshDevices()
                    dismiss()
                }
            }
        } message: {
            Text("解绑后这部手机不再管理这张卡。卡上的录音和已同步到手机的录音都会保留。")
        }
        .alert("同步后删除卡上录音？", isPresented: $confirmingDeleteAfterSync) {
            Button("取消", role: .cancel) {}
            Button("开启") { model.setDeleteAfterSync(true) }
        } message: {
            Text("录音确认已存入手机后，才会从卡上删除。")
        }
    }

    // MARK: Sections

    private var general: some View {
        Section("通用") {
            Button {
                newName = model.device?.name ?? ""
                renaming = true
            } label: {
                LabeledContent("名称") {
                    HStack(spacing: 4) {
                        Text(model.device?.name ?? "")
                        Image(systemName: "chevron.right").font(.footnote).foregroundStyle(Theme.inkMuted)
                    }
                }
            }
            .foregroundStyle(Theme.ink)
            if let battery = model.battery {
                LabeledContent("电量", value: "\(battery)%")
            }
            if let free = model.freeSpaceMb {
                LabeledContent("存储", value: "剩余 \(Self.gigabytes(free))")
            }
            LabeledContent("序列号", value: model.maskedSerial)
            LabeledContent("固件版本", value: model.firmware)
        }
        .surfaceRows()
    }

    @ViewBuilder private var settings: some View {
        if let s = model.switches {
            Section("录音设置") {
                toggle("降噪", .noiseCancel, s.noiseCancel) { .noiseCancel($0) }
                // The level does nothing while 降噪 is off.
                if s.noiseCancel {
                    NavigationLink {
                        LevelPicker(title: "降噪等级", note: "等级越高，环境噪声压得越低，人声也可能变闷。",
                                    value: s.noiseLevel) { model.set(.noiseLevel($0)) }
                    } label: {
                        row("降噪等级", .noiseLevel) { Text("\(s.noiseLevel)").foregroundStyle(Theme.inkMuted) }
                    }
                    .disabled(model.pending.contains(.noiseLevel))
                }
                NavigationLink {
                    LevelPicker(title: "麦克风增益", note: "增益越高，录音音量越大，也更容易录进杂音。",
                                value: s.gain) { model.set(.gain($0)) }
                } label: {
                    row("麦克风增益", .gain) { Text("\(s.gain)").foregroundStyle(Theme.inkMuted) }
                }
                .disabled(model.pending.contains(.gain))
                toggle("声控录音（VAD）", .vad, s.vad) { .vad($0) }
            }
            .surfaceRows()
            Section("其他") {
                toggle("指示灯", .led, s.led) { .led($0) }
                toggle("振动", .motor, s.motor) { .motor($0) }
                row("空闲自动关机", .autoOff) {
                    Picker("空闲自动关机", selection: autoOffBinding(s.autoOffSeconds)) {
                        ForEach(Self.autoOffChoices(current: s.autoOffSeconds), id: \.self) {
                            Text(Self.minutes($0)).tag($0)
                        }
                    }
                    .labelsHidden()
                    .disabled(model.pending.contains(.autoOff))
                }
                #if DEBUG
                // Release builds show it once device evidence covers delete-after-store (#41 batch 3d).
                Toggle("同步后删除卡上录音", isOn: deleteAfterSyncBinding)
                #endif
            }
            .surfaceRows()
        } else if model.switchesFailed {
            Section {
                HStack {
                    Text("读取失败").foregroundStyle(Theme.inkMuted)
                    Spacer()
                    Button("重试") { Task { await model.load(force: true) } }
                }
            }
            .surfaceRows()
        } else {
            Section {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
            }
            .surfaceRows()
        }
    }

    private var actions: some View {
        Section {
            if model.isConnected {
                Button("断开连接") { model.disconnect() }
            } else if model.canReconnect {
                Button("重新连接") { model.reconnect() }
            }
            Button("解绑此卡", role: .destructive) { confirmingUnpair = true }
                .disabled(model.unpairBlockedReason != nil || model.unpairing || phoneRecording)
        } footer: {
            if let reason = model.unpairBlockedReason {
                Text(reason)
            } else if phoneRecording {
                // Unpairing the last card leaves the tabs, and the way back to 停止.
                Text("正在用这部手机录音，录完再解绑。")
            }
        }
        .surfaceRows()
    }

    private var phoneRecording: Bool {
        guard let phone = env.phoneRecorder else { return false }
        return phone.state != .idle || phone.isSaving
    }

    // MARK: Rows

    private func toggle(_ title: String, _ key: DeviceModel.Setting, _ value: Bool,
                        _ setting: @escaping (Bool) -> CardSetting) -> some View {
        row(title, key) {
            Toggle(title, isOn: Binding(get: { value }, set: { model.set(setting($0)) }))
                .labelsHidden()
                .disabled(model.pending.contains(key))
        }
    }

    /// A settings row with a spinner while its value is being sent.
    private func row(_ title: String, _ key: DeviceModel.Setting,
                     @ViewBuilder trailing: () -> some View) -> some View {
        // Accessibility text sizes put the value under the title; side by side it shrinks to "1…" (#49).
        let stacked = typeSize.isAccessibilitySize
        let layout = stacked ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4)) : AnyLayout(HStackLayout())
        return layout {
            Text(title)
            if !stacked { Spacer() }
            HStack {
                if model.pending.contains(key) { ProgressView() }
                trailing()
            }
        }
    }

    private func autoOffBinding(_ current: Int) -> Binding<Int> {
        Binding(get: { current }, set: { model.set(.autoOff(seconds: UInt32($0))) })
    }

    private var deleteAfterSyncBinding: Binding<Bool> {
        Binding(get: { model.deleteAfterSync }, set: { on in
            if on { confirmingDeleteAfterSync = true } else { model.setDeleteAfterSync(false) }
        })
    }

    // MARK: Formatting

    static func gigabytes(_ mb: Int) -> String {
        mb >= 1024 ? String(format: "%.1f GB", Double(mb) / 1024) : "\(mb) MB"
    }

    static func minutes(_ seconds: Int) -> String {
        seconds % 60 == 0 ? "\(seconds / 60) 分钟" : "\(seconds) 秒"
    }

    /// The offered choices, plus the card's own value when it is not one of them.
    static func autoOffChoices(current: Int) -> [Int] {
        let choices = DeviceModel.autoOffChoices
        return choices.contains(current) ? choices : (choices + [current]).sorted()
    }
}

/// 1–9 list for noise level and gain, with one line on what it does (official app layout).
private struct LevelPicker: View {
    let title: String
    let note: String
    let value: Int
    let onSelect: (Int) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Section {
                ForEach(Array(CardSetting.levelRange), id: \.self) { level in
                    Button {
                        if level != value { onSelect(level) }
                        dismiss()
                    } label: {
                        HStack {
                            Text(level == CardSetting.levelRange.lowerBound ? "\(level)（最弱）"
                                 : level == CardSetting.levelRange.upperBound ? "\(level)（最强）" : "\(level)")
                                .foregroundStyle(Theme.ink)
                            Spacer()
                            if level == value { Image(systemName: "checkmark").foregroundStyle(Theme.accent) }
                        }
                    }
                }
            } footer: {
                Text(note)
            }
            .surfaceRows()
        }
        .listStyle(.insetGrouped)
        .paperBackground()
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}
