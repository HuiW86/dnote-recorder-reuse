import AppModel
import SwiftUI

/// P09 settings (product-spec.md §4.2). M1 has no global settings: "同步后删除" is per card on P07.
struct SettingsView: View {
    let diagnostics: DiagnosticLog
    @Bindable var preferences: Preferences
    /// The system refused notifications when the switch was turned on.
    @State private var notificationsRefused = false

    var body: some View {
        List {
            Section {
                NavigationLink("最近删除", value: Route.trash)
            } header: {
                Text("录音")
            } footer: {
                Text("在这部手机上删除的录音会保留 7 天，期间可以恢复。")
            }
            .surfaceRows()
            Section {
                Toggle("同步完成时通知", isOn: notificationsBinding)
            } footer: {
                Text(notificationsRefused
                     ? "系统没有允许闻笺发通知。请到系统「设置」→「通知」→「闻笺」里打开后再试。"
                     : "闻笺不在前台时，录音同步到手机后提醒你。通知只在这部手机上产生。")
            }
            .surfaceRows()
            Section {
                NavigationLink(value: Route.assistant) {
                    LabeledContent("AI 服务", value: preferences.assistantBaseURL.isEmpty ? "未设置" : "已设置")
                }
            } footer: {
                Text("填上你自己的 AI 服务后，可以把文字稿整理成纪要。")
            }
            .surfaceRows()
            Section {
                Toggle("本机转写（试验）", isOn: $preferences.onDeviceTranscriptEnabled)
            } footer: {
                Text("打开后，录音详情里可以把录音转成文字。识别在这部手机上完成，不联网；第一次使用时系统会询问语音识别权限。准确度还没有充分验证。")
            }
            .surfaceRows()
            Section {
                NavigationLink("权限说明", value: Route.permissions)
                DiagnosticShareLink(log: diagnostics)
            } header: {
                Text("帮助")
            } footer: {
                Text("诊断信息记录连接和同步的过程，不含录音，序列号已脱敏。只在你分享时离开这部手机。")
            }
            .surfaceRows()
            Section("关于") {
                NavigationLink("关于", value: Route.about)
                NavigationLink("隐私政策", value: Route.privacy)
            }
            .surfaceRows()
        }
        .listStyle(.insetGrouped)
        .paperBackground()
        // Notifications turned off in system Settings: the switch follows, instead of showing
        // a promise the system no longer keeps (#85).
        .task {
            guard preferences.syncNotificationsEnabled, await SyncNotifier.isDenied() else { return }
            preferences.syncNotificationsEnabled = false
            notificationsRefused = true
        }
        .navigationTitle("设置")
        .navigationBarTitleDisplayMode(.inline)
    }
}

extension SettingsView {
    /// Turning the switch on asks for the system permission first; a refusal turns it back off.
    private var notificationsBinding: Binding<Bool> {
        Binding(get: { preferences.syncNotificationsEnabled }, set: { on in
            guard on else {
                preferences.syncNotificationsEnabled = false
                return
            }
            Task {
                let granted = await SyncNotifier.requestAuthorization()
                preferences.syncNotificationsEnabled = granted
                notificationsRefused = !granted
            }
        })
    }
}

/// P10 about: name, version, what it works with, open-source licenses. No update check:
/// TestFlight tells the user itself (ADR-004).
struct AboutView: View {
    var body: some View {
        List {
            Section {
                VStack(spacing: 6) {
                    Text("闻笺").font(.title2.bold()).foregroundStyle(Theme.ink)
                    Text("版本 \(Self.version)").foregroundStyle(Theme.inkMuted)
                    // The only place the brand may appear (CLAUDE.md rule 5).
                    Text("适用于 D·NOTE 录音卡").foregroundStyle(Theme.inkMuted)
                }
                .font(.subheadline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }
            .surfaceRows()
            Section("开源许可") {
                NavigationLink("GRDB.swift") {
                    LicenseView(name: "GRDB.swift", text: Self.grdbLicense)
                }
            }
            .surfaceRows()
        }
        .listStyle(.insetGrouped)
        .paperBackground()
        .navigationTitle("关于")
        .navigationBarTitleDisplayMode(.inline)
    }

    static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

    static let grdbLicense = """
        Copyright (C) 2015-2025 Gwendal Roué

        Permission is hereby granted, free of charge, to any person obtaining a copy of this software and \
        associated documentation files (the "Software"), to deal in the Software without restriction, including \
        without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell \
        copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the \
        following conditions:

        The above copyright notice and this permission notice shall be included in all copies or substantial \
        portions of the Software.

        THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT \
        LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO \
        EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER \
        IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR \
        THE USE OR OTHER DEALINGS IN THE SOFTWARE.
        """
}

private struct LicenseView: View {
    let name: String
    let text: String

    var body: some View {
        ScrollView {
            Text(text)
                .font(.footnote.monospaced())
                .foregroundStyle(Theme.ink)
                .textSelection(.enabled)
                .padding()
        }
        .background(Theme.paper)
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
    }
}
