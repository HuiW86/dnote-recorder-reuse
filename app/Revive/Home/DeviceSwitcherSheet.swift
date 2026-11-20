import AppModel
import SwiftUI

/// P08 switch cards: paired cards from the local database and "添加录音卡" (product-spec.md P08,
/// §3.3). Adding goes P02 → P03 inside this sheet; pairing makes the new card current.
struct DeviceSwitcherSheet: View {
    @Bindable var model: HomeModel
    let env: AppEnvironment
    @Environment(\.dismiss) private var dismiss
    @State private var path: [Step] = []

    private enum Step: Hashable {
        case connectGuide, pairing
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section {
                    ForEach(model.deviceRows) { row in
                        Button {
                            if model.selectDevice(row.id) { dismiss() }
                        } label: {
                            DeviceSwitcherRow(row: row)
                        }
                        .foregroundStyle(Theme.ink)
                    }
                }
                .surfaceRows()
                Section {
                    Button {
                        if env.isCardless {
                            // 先不连卡: pair through P01, which explains Bluetooth before iOS asks.
                            dismiss()
                            env.addFirstCard()
                        } else {
                            path.append(.connectGuide)
                        }
                    } label: {
                        Label("添加录音卡", systemImage: "plus")
                    }
                }
                .surfaceRows()
            }
            .listStyle(.insetGrouped)
            .paperBackground()
            .navigationTitle("录音卡")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
            .navigationDestination(for: Step.self) { step in
                switch step {
                case .connectGuide: ConnectGuideView { path.append(.pairing) }
                case .pairing: PairingView(env: env) { dismiss() }
                }
            }
            .alert(model.pendingSwitch?.title ?? "", isPresented: switchBinding, presenting: model.pendingSwitch) { _ in
                Button("切换") {
                    if model.confirmSwitch() { dismiss() }
                }
                Button("取消", role: .cancel) {}
            } message: { pending in
                Text(pending.message)
            }
            .alert(model.switcherPrompt?.title ?? "", isPresented: promptBinding,
                   presenting: model.switcherPrompt) { prompt in
                Button(prompt.actionTitle) {
                    model.switcherPrompt = nil
                    path.append(.connectGuide)
                }
                Button("取消", role: .cancel) {}
            } message: { prompt in
                Text(prompt.message)
            }
        }
        .tint(Theme.accent)
        .presentationDetents([.medium, .large])
    }

    private var promptBinding: Binding<Bool> {
        Binding(get: { model.switcherPrompt != nil }, set: { if !$0 { model.switcherPrompt = nil } })
    }

    private var switchBinding: Binding<Bool> {
        Binding(get: { model.pendingSwitch != nil }, set: { if !$0 { model.pendingSwitch = nil } })
    }
}

private struct DeviceSwitcherRow: View {
    let row: DeviceRow

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(row.name)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(Theme.inkMuted)
            }
            Spacer()
            if row.isCurrent {
                Image(systemName: "checkmark")
                    .foregroundStyle(Theme.accent)
                    .accessibilityLabel("当前录音卡")
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var subtitle: String { row.subtitle }
}
