import AppModel
import CardService
import SwiftUI
import UIKit

/// P03 scan and pair (product-spec.md §4.2, §4.3, §7.1).
struct PairingView: View {
    let env: AppEnvironment
    /// "开始使用" after pairing.
    let onFinished: () -> Void
    @State private var model: PairingModel?

    var body: some View {
        Group {
            if let model {
                PairingContent(model: model, onFinished: onFinished)
            } else {
                ContentUnavailableView(CardServiceError.bluetoothUnsupported.userText ?? "",
                                       systemImage: "exclamationmark.triangle")
            }
        }
        .navigationTitle("连接录音卡")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if model == nil, let session = env.startBluetooth() {
                model = PairingModel(session: session, preferences: env.preferences)
            }
            model?.start()
        }
        .onDisappear {
            model?.stop()
            // Pairing can finish after the user went back; the root then moves on to home.
            env.refreshDevices()
        }
    }
}

private struct PairingContent: View {
    @Bindable var model: PairingModel
    let onFinished: () -> Void

    var body: some View {
        Group {
            if let problem = model.bluetoothProblem {
                BluetoothProblemView(problem: problem) { model.scan() }
            } else {
                switch model.phase {
                case .scanning: scanList
                case .notFound: notFound
                case .working, .failed: PairingStepsView(model: model)
                case .done: done
                }
            }
        }
        // Both buttons answer; the setter must not, or a dismissal ordered before the button
        // action would decline a confirmed re-bind.
        .alert("此卡已被其他设备绑定", isPresented: Binding(get: { model.rebindPending }, set: { _ in })) {
            Button("重新绑定", role: .destructive) { model.answerRebind(true) }
            Button("取消", role: .cancel) { model.answerRebind(false) }
        } message: {
            Text("重新绑定后原设备将无法管理此卡。卡上的录音不受影响。")
        }
    }

    private var scanList: some View {
        List {
            Section {
                ForEach(model.candidates) { card in
                    Button { model.select(card) } label: { CandidateRow(card: card) }
                        .foregroundStyle(.primary)
                }
            } header: {
                HStack(spacing: 8) {
                    Text("正在寻找附近的录音卡…")
                    ProgressView()
                }
                .textCase(nil)
            } footer: {
                Text("看不到你的卡？按住录音键，白灯闪烁后松手")
            }
        }
        .listStyle(.insetGrouped)
    }

    private var notFound: some View {
        ContentUnavailableView {
            Label("没有找到录音卡", systemImage: "magnifyingglass")
        } description: {
            Text("请把卡靠近手机，按住录音键，白灯闪烁后松手")
        } actions: {
            Button("再试一次") { model.scan() }
                .buttonStyle(.borderedProminent)
        }
    }

    private var done: some View {
        ScrollingPage {
            VStack(spacing: 24) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(.green)
                    .accessibilityHidden(true)
                Text("配对完成").font(.title2.bold())
                if let name = model.selected?.displayName {
                    Text(name).foregroundStyle(.secondary)
                }
            }
            .multilineTextAlignment(.center)
            .padding(.vertical, 24)
        } footer: {
            Button(action: onFinished) {
                Text("开始使用").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
    }
}

private struct CandidateRow: View {
    let card: CardCandidate
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        // Accessibility text sizes stack the row: side by side it squeezes into a narrow column (#49).
        let stacked = typeSize.isAccessibilitySize
        let layout = stacked ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8)) : AnyLayout(HStackLayout(spacing: 12))
        layout {
            if !stacked {
                Image(systemName: "rectangle.portrait")
                    .font(.title2)
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(card.displayName).font(.body)
                Text("电量 \(card.battery)% · 固件 \(card.firmware)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            if !stacked { Spacer() }
            if card.firmwareUnverified {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                    .accessibilityLabel(FirmwareText.unverified)
            }
            if !stacked {
                Image(systemName: "chevron.right")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// Connect → read info → pair, with the failed step's message and "重试" (product-spec.md P03).
private struct PairingStepsView: View {
    let model: PairingModel

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            if let name = model.selected?.displayName {
                Text(name).font(.title3.bold())
            }
            ForEach(PairingModel.Step.allCases, id: \.self) { step in
                StepRow(title: Self.title(step), state: state(of: step))
            }
            if case .failed(_, let error) = model.phase {
                Text(error.userText ?? "出了点问题，请重试")
                    .foregroundStyle(.red)
                HStack {
                    Button("重试") { model.retry() }
                        .buttonStyle(.borderedProminent)
                    Button("换一张卡") { model.scan() }
                        .buttonStyle(.bordered)
                }
            }
            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    static func title(_ step: PairingModel.Step) -> String {
        switch step {
        case .connecting: "正在连接"
        case .readingInfo: "正在读取信息"
        case .pairing: "正在配对"
        }
    }

    private func state(of step: PairingModel.Step) -> StepRow.State {
        switch model.phase {
        case .working(let current):
            step.rawValue < current.rawValue ? .done : step == current ? .active : .pending
        case .failed(let current, _):
            step.rawValue < current.rawValue ? .done : step == current ? .failed : .pending
        default:
            .pending
        }
    }
}

private struct StepRow: View {
    enum State { case pending, active, done, failed }
    let title: String
    let state: State

    var body: some View {
        HStack(spacing: 12) {
            Group {
                switch state {
                case .pending: Image(systemName: "circle").foregroundStyle(.tertiary)
                case .active: ProgressView()
                case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                }
            }
            .frame(width: 24)
            Text(title).foregroundStyle(state == .pending ? .secondary : .primary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(Self.spoken(state))
    }

    private static func spoken(_ s: State) -> String {
        switch s {
        case .pending: "未开始"
        case .active: "进行中"
        case .done: "已完成"
        case .failed: "失败"
        }
    }
}

/// Bluetooth off, not allowed or unavailable (product-spec.md §7.1).
struct BluetoothProblemView: View {
    let problem: CardServiceError
    let retry: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label(problem.userText ?? "", systemImage: "antenna.radiowaves.left.and.right.slash")
        } actions: {
            switch problem {
            case .bluetoothUnauthorized:
                Button("去设置") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
                .buttonStyle(.borderedProminent)
            case .bluetoothUnsupported:
                Button("重试", action: retry).buttonStyle(.borderedProminent)
            default:
                EmptyView()  // bluetoothOff: recovers by itself once Bluetooth is on
            }
        }
    }
}
