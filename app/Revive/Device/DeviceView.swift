import AppModel
import CardProtocol
import SwiftUI

/// P07 device page (product-spec.md §4.2): official grouping and order; settings only while
/// connected; no firmware update, factory reset, USB mode or power-off (CLAUDE.md rule 1).
struct DeviceView: View {
    let env: AppEnvironment
    let deviceId: UUID
    @State private var model: DeviceModel?

    var body: some View {
        Group {
            if let model {
                DeviceContent(env: env, model: model)
            } else {
                ProgressView()
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
    @Environment(\.dismiss) private var dismiss
    @State private var renaming = false
    @State private var newName = ""
    @State private var confirmingUnpair = false
    @State private var confirmingDeleteAfterSync = false

    var body: some View {
        List {
            if model.firmwareUnverified {
                Label(FirmwareText.unverified, systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline)
                    .foregroundStyle(.orange)
            }
            general
            if model.isConnected {
                settings
            } else {
                Section {
                    Text("连接后可修改设置").foregroundStyle(.secondary)
                }
            }
            actions
        }
        .listStyle(.insetGrouped)
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
                        Image(systemName: "chevron.right").font(.footnote).foregroundStyle(.tertiary)
                    }
                }
            }
            .foregroundStyle(.primary)
            if let battery = model.battery {
                LabeledContent("电量", value: "\(battery)%")
            }
            if let free = model.freeSpaceMb {
                LabeledContent("存储", value: "剩余 \(Self.gigabytes(free))")
            }
            LabeledContent("序列号", value: model.maskedSerial)
            LabeledContent("固件版本", value: model.firmware)
        }
    }

    @ViewBuilder private var settings: some View {
        if let s = model.switches {
            Section("录音设置") {
                toggle("降噪", .noiseCancel, s.noiseCancel) { .noiseCancel($0) }
                NavigationLink {
                    LevelPicker(title: "降噪等级", note: "等级越高，环境噪声压得越低，人声也可能变闷。",
                                value: s.noiseLevel) { model.set(.noiseLevel($0)) }
                } label: {
                    row("降噪等级", .noiseLevel) { Text("\(s.noiseLevel)").foregroundStyle(.secondary) }
                }
                .disabled(model.pending.contains(.noiseLevel))
                NavigationLink {
                    LevelPicker(title: "麦克风增益", note: "增益越高，录音音量越大，也更容易录进杂音。",
                                value: s.gain) { model.set(.gain($0)) }
                } label: {
                    row("麦克风增益", .gain) { Text("\(s.gain)").foregroundStyle(.secondary) }
                }
                .disabled(model.pending.contains(.gain))
                toggle("声控录音（VAD）", .vad, s.vad) { .vad($0) }
            }
            Section("其他") {
                toggle("指示灯", .led, s.led) { .led($0) }
                toggle("振动", .motor, s.motor) { .motor($0) }
                row("空闲自动关机", .autoOff) {
                    Picker("", selection: autoOffBinding(s.autoOffSeconds)) {
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
        } else if model.switchesFailed {
            Section {
                HStack {
                    Text("读取失败").foregroundStyle(.secondary)
                    Spacer()
                    Button("重试") { Task { await model.load() } }
                }
            }
        } else {
            Section {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
            }
        }
    }

    private var actions: some View {
        Section {
            if model.isConnected {
                Button("断开连接") { model.disconnect() }
            }
            Button("解绑此卡", role: .destructive) { confirmingUnpair = true }
                .disabled(model.unpairBlockedReason != nil || model.unpairing)
        } footer: {
            if let reason = model.unpairBlockedReason { Text(reason) }
        }
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
        HStack {
            Text(title)
            Spacer()
            if model.pending.contains(key) { ProgressView() }
            trailing()
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
                            Text("\(level)").foregroundStyle(.primary)
                            Spacer()
                            if level == value { Image(systemName: "checkmark").foregroundStyle(.tint) }
                        }
                    }
                }
            } footer: {
                Text(note)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}
