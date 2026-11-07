import SwiftUI

// P11 privacy and P12 permissions (product-spec.md §4.1). Bundled with the app, so they work
// offline (CLAUDE.md rule 3). Reached from P01 now; P09 settings links here in batch 3.

struct PrivacyView: View {
    var body: some View {
        InfoPage(title: "隐私政策", sections: [
            ("不需要账号", "Revive 不需要注册或登录，也不会把你的信息发到任何服务器。"),
            ("录音存在哪里", "录音从录音卡同步到这部手机，只保存在 App 的本地存储里。删除 App 会一并删除这些录音。"),
            ("我们不收集什么", "App 不联网，不收集录音、位置、通讯录或使用数据，也没有广告和统计。"),
            ("诊断信息", "出问题时你可以手动导出诊断信息，它只在你主动分享时离开这部手机。"),
        ])
    }
}

struct PermissionsView: View {
    var body: some View {
        InfoPage(title: "权限说明", sections: [
            ("蓝牙", "用来发现、连接录音卡，控制录音，并把卡上的录音同步到手机。不允许蓝牙时，App 只能播放已经同步的录音。"),
            ("后台运行", "锁屏或切到其他 App 时保持与录音卡的连接；卡上的录音结束后，会在后台自动同步。"),
        ])
    }
}

private struct InfoPage: View {
    let title: String
    let sections: [(String, String)]

    var body: some View {
        List {
            ForEach(sections, id: \.0) { heading, text in
                Section(heading) {
                    Text(text)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}
