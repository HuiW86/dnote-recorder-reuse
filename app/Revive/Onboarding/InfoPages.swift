import SwiftUI

// P11 privacy and P12 permissions (product-spec.md §4.2). Bundled with the app, so they work
// offline (CLAUDE.md rule 3). Reached from P01 and from P09 settings.

struct PrivacyView: View {
    var body: some View {
        InfoPage(title: "隐私政策", sections: [
            ("不需要账号", "闻笺不需要注册或登录，也不会把你的信息发到任何服务器。"),
            ("录音存在哪里", "录音从录音卡同步到这部手机，只保存在 App 的本地存储里。删除 App 会一并删除这些录音。"),
            ("录音如何解密", "卡上的录音是加密的。解密用的密钥由 App 在这部手机上计算，不经过网络。"),
            ("我们不收集什么", "App 不联网，不收集录音、位置、通讯录或使用数据，也没有广告和统计。"),
            ("本机转写", "打开「本机转写」后，录音在这部手机上转成文字，使用系统的离线语音识别，录音和文字都不会离开手机。不打开就不会用到。"),
            ("诊断信息", "App 在本机记录连接、同步和出错的过程，最多保留 1 MB，不含录音。序列号只记一段摘要，不记完整号码。出问题时你可以在「设置」里手动导出，只在你主动分享时离开这部手机。"),
        ])
    }
}

/// Follows the official app's "when it is asked / what it is for" layout; M1 needs Bluetooth only.
struct PermissionsView: View {
    var body: some View {
        InfoPage(title: "权限说明", sections: [
            ("蓝牙 · 申请时机", "第一次连接录音卡之前。"),
            ("蓝牙 · 使用说明", "用来发现、连接录音卡，控制录音，并把卡上的录音同步到手机。锁屏或切到其他 App 时也会保持连接，卡上的录音结束后在后台自动同步。不允许蓝牙时，App 只能播放已经同步的录音。"),
            ("语音识别 · 申请时机", "在设置里打开「本机转写」之后，第一次把录音转成文字时。"),
            ("语音识别 · 使用说明", "用来在这部手机上把录音转成文字，只用离线识别，不联网。不允许时不能转文字，其他功能不受影响。"),
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
                    Text(text).foregroundStyle(Theme.ink)
                }
                .surfaceRows()
            }
        }
        .listStyle(.insetGrouped)
        .paperBackground()
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}
