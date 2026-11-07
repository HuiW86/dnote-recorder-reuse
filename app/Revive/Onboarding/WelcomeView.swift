import AppModel
import CardService
import SwiftUI
import UIKit

/// P01 welcome and permission (product-spec.md §4.2). Says what Bluetooth is for before
/// iOS asks; the prompt only appears after "继续".
struct WelcomeView: View {
    let env: AppEnvironment
    @Binding var path: [OnboardingFlow.Route]
    @State private var model: OnboardingModel
    @Environment(\.scenePhase) private var scenePhase

    init(env: AppEnvironment, path: Binding<[OnboardingFlow.Route]>) {
        self.env = env
        _path = path
        _model = State(initialValue: OnboardingModel(
            authorization: { AppEnvironment.bluetoothAuthorization },
            startBluetooth: { [env] in env.startBluetooth() }))
    }

    var body: some View {
        Group {
            if model.phase == .denied {
                ContentUnavailableView {
                    Label(CardServiceError.bluetoothUnauthorized.userText ?? "", systemImage: "antenna.radiowaves.left.and.right.slash")
                } description: {
                    Text("在「设置」里允许 Revive 使用蓝牙，然后回到这里。")
                } actions: {
                    Button("去设置") { openSettings() }
                        .buttonStyle(.borderedProminent)
                }
            } else {
                intro
            }
        }
        .onChange(of: model.phase) { _, phase in
            if phase == .proceed { goToGuide() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { model.refresh() }
        }
    }

    private var intro: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "rectangle.portrait.on.rectangle.portrait")
                .font(.system(size: 64))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            VStack(spacing: 8) {
                Text("让你的录音卡重新可用")
                    .font(.title2.bold())
                Text("不用登录、不用联网，录音只保存在这部手机上")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            VStack(alignment: .leading, spacing: 16) {
                PermissionRow(symbol: "dot.radiowaves.left.and.right", title: "蓝牙",
                              detail: "连接录音卡、同步录音")
                PermissionRow(symbol: "lock.iphone", title: "后台",
                              detail: "锁屏时保持连接，录音结束后自动同步")
            }
            .padding(.top, 8)
            Spacer()
            HStack(spacing: 4) {
                Button("隐私政策") { path.append(.privacy) }
                Text("·").foregroundStyle(.secondary)
                Button("权限说明") { path.append(.permissions) }
            }
            .font(.footnote)
            Button {
                model.continueTapped()
                if model.phase == .proceed { goToGuide() }
            } label: {
                Group {
                    if model.phase == .requesting {
                        ProgressView()
                    } else {
                        Text("继续")
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(model.phase == .requesting)
        }
        .padding(24)
    }

    /// Idempotent: the phase can reach `.proceed` from the button and from `onChange`.
    private func goToGuide() {
        if path.last != .connectGuide && !path.contains(.pairing) { path.append(.connectGuide) }
    }

    private func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
    }
}

private struct PermissionRow: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: symbol)
                .foregroundStyle(.tint)
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
