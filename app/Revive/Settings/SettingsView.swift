import Account
import AIRoute
import AppModel
import SwiftUI

/// P09 settings (product-spec.md §4.2). M1 has no global settings: "同步后删除" is per card on P07.
struct SettingsView: View {
    let diagnostics: DiagnosticLog
    @Bindable var preferences: Preferences
    /// Nil unless the build names a server: then there is no 账号 row at all.
    var account: AccountSession?
    /// The system refused notifications when the switch was turned on.
    @State private var notificationsRefused = false
    /// "未登录" or the signed-in account, for the 账号 row.
    @State private var accountName = "未登录"
    /// 录完自动整理 would use the 闻笺 account: confirm before turning it on (§7.3b).
    @State private var confirmingAutoProcess = false

    var body: some View {
        List {
            Section("外观") {
                Picker("外观", selection: $preferences.appearance) {
                    ForEach(Preferences.Appearance.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            .surfaceRows()
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
            if account != nil {
                Section {
                    NavigationLink(value: Route.account) {
                        LabeledContent("账号", value: accountName)
                    }
                } footer: {
                    Text("登录后可以用闻笺的服务器转写和整理录音。录音卡、录音、同步、播放不需要登录。")
                }
                .surfaceRows()
            }
            Section {
                NavigationLink(value: Route.assistant) {
                    LabeledContent("AI 服务", value: preferences.assistantBaseURL.isEmpty ? "未设置" : "已设置")
                }
            } footer: {
                Text("填上你自己的 AI 服务后，可以把文字稿整理成纪要。")
            }
            .surfaceRows()
            Section {
                NavigationLink("纠错词库", value: Route.corrections)
            } footer: {
                Text("在文字稿里长按一句改正听错的词，以后转写会自动改正。")
            }
            .surfaceRows()
            // §7.3b: replaces 本机转写（试验）. Lists only the ways this phone has; a choice of one is
            // no choice, so it is not shown.
            if choosesTranscription || choosesSummary {
                Section {
                    if choosesTranscription {
                        Picker("默认转写方式", selection: transcriptionPathBinding) {
                            ForEach(transcriptionPaths) { Text($0.title).tag($0) }
                        }
                    }
                    if choosesSummary {
                        Picker("默认纪要方式", selection: $preferences.defaultSummaryPath) {
                            Text("第一次用时选").tag(AIPath?.none)
                            ForEach(summaryPaths) { Text($0.title).tag(AIPath?.some($0)) }
                        }
                    }
                } footer: {
                Text(account != nil
                     ? "「本机」离线完成，不联网；「你的 AI 服务」和「闻笺账号」会把录音或文字稿发给对应服务。单条录音可在详情页右上角「⋯」里单独换方式。"
                     : "「本机」离线完成，不联网；「你的 AI 服务」会把录音或文字稿发给你设置的服务。单条录音可在详情页右上角「⋯」里单独换方式。")
                }
                .surfaceRows()
            }
            Section {
                Toggle("录完自动整理", isOn: autoProcessBinding)
            } footer: {
                Text("仅处理开启后新存入的录音，按上面的默认方式自动转文字并生成纪要（未选默认纪要方式或暂不可用时跳过）。只在闻笺运行时进行。")
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
            if let account {
                let user = await account.user
                accountName = user?.displayName ?? "未登录"
            }
            guard preferences.syncNotificationsEnabled, await SyncNotifier.isDenied() else { return }
            preferences.syncNotificationsEnabled = false
            notificationsRefused = true
        }
        .navigationTitle("设置")
        .confirmationDialog("开启录完自动整理？", isPresented: $confirmingAutoProcess,
                            titleVisibility: .visible) {
            Button(AIConsent.autoProcess.button) {
                preferences.grant(.autoProcess)
                preferences.autoProcessEnabled = true
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text(AIConsent.autoProcess.message)
        }
        .navigationBarTitleDisplayMode(.inline)
    }
}

extension SettingsView {
    /// Turning the switch on asks for the system permission first; a refusal turns it back off.
    /// This phone, the user's service once it has a transcription model, the account in a build
    /// with a server (§7.3b).
    private var transcriptionPaths: [AIPath] {
        var paths: [AIPath] = [.onDevice]
        if !preferences.assistantTranscriptionModel.trimmingCharacters(in: .whitespaces).isEmpty,
           !preferences.assistantBaseURL.isEmpty { paths.append(.ownService) }
        if account != nil { paths.append(.account) }
        return paths
    }

    /// More than one way, or a stored default that is no longer offered and must be changeable.
    private var choosesTranscription: Bool {
        transcriptionPaths.count > 1 || !transcriptionPaths.contains(preferences.defaultTranscriptionPath ?? .onDevice)
    }

    /// A way to summarize exists (the user's service is filled in, or the build has the account),
    /// or a default was chosen that can still be put back to 第一次用时选.
    private var choosesSummary: Bool {
        !preferences.assistantBaseURL.isEmpty || account != nil || preferences.defaultSummaryPath != nil
    }

    private var summaryPaths: [AIPath] {
        var paths: [AIPath] = [.ownService]
        if account != nil { paths.append(.account) }
        return paths
    }

    /// Never chosen reads as 本机: that is what 转成文字 does then (§7.3b).
    private var transcriptionPathBinding: Binding<AIPath> {
        Binding(get: { preferences.defaultTranscriptionPath ?? .onDevice },
                set: { preferences.defaultTranscriptionPath = $0 })
    }

    private var autoProcessBinding: Binding<Bool> {
        Binding(get: { preferences.autoProcessEnabled }, set: { on in
            if on, AIRoute.autoProcessNeedsConsent(transcribeDefault: preferences.defaultTranscriptionPath,
                                                   summarizeDefault: preferences.defaultSummaryPath,
                                                   consents: preferences.aiConsents) {
                confirmingAutoProcess = true
            } else {
                preferences.autoProcessEnabled = on
            }
        })
    }

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
            // Unofficial, and whose names are whose (#75 致谢与免责声明). The brand itself appears
            // only in the line above (CLAUDE.md rule 5).
            Section("声明") {
                Text("闻笺由独立开发者开发，不是录音卡厂商的官方 App，与厂商没有关联。录音卡的名称和商标归各自的所有者所有。")
                    .foregroundStyle(Theme.ink)
            }
            .surfaceRows()
            Section("开源许可") {
                NavigationLink("GRDB.swift") {
                    LicenseView(name: "GRDB.swift", text: Self.grdbLicense)
                }
                // Prompts and scene definitions adapted from it ship in the app (NOTICE); MIT asks
                // for its notice in every copy.
                NavigationLink("beanpod") {
                    LicenseView(name: "beanpod", text: Self.beanpodLicense)
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

    /// The repository's NOTICE, as it applies to the app.
    static let beanpodLicense = """
        录音场景分类，总结、改写、提问和跨录音提问的提示词，以及常见服务商地址列表，改编自 andyhuo520/beanpod（commit 0d00fab）。代码由本项目重写。

        MIT License

        Copyright (c) 2026 berryxia

        Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

        The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

        THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
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
