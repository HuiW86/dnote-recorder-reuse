import AppModel
import SwiftUI

/// P09 settings (product-spec.md §4.2). M1 has no global settings: "同步后删除" is per card on P07.
struct SettingsView: View {
    let diagnostics: DiagnosticLog

    var body: some View {
        List {
            Section {
                NavigationLink("权限说明", value: Route.permissions)
                DiagnosticShareLink(log: diagnostics)
            } header: {
                Text("帮助")
            } footer: {
                Text("诊断信息记录连接和同步的过程，不含录音，序列号已脱敏。只在你分享时离开这部手机。")
            }
            Section("关于") {
                NavigationLink("关于", value: Route.about)
                NavigationLink("隐私政策", value: Route.privacy)
            }
        }
        .listStyle(.insetGrouped)
        .paperBackground()
        .navigationTitle("设置")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// P10 about: name, version, what it works with, open-source licenses. No update check:
/// TestFlight tells the user itself (ADR-004).
struct AboutView: View {
    var body: some View {
        List {
            Section {
                VStack(spacing: 6) {
                    Text("闻笺").font(.title2.bold())
                    Text("版本 \(Self.version)").foregroundStyle(.secondary)
                    // The only place the brand may appear (CLAUDE.md rule 5).
                    Text("适用于 D·NOTE 录音卡").foregroundStyle(.secondary)
                }
                .font(.subheadline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }
            Section("开源许可") {
                NavigationLink("GRDB.swift") {
                    LicenseView(name: "GRDB.swift", text: Self.grdbLicense)
                }
            }
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
                .textSelection(.enabled)
                .padding()
        }
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
    }
}
