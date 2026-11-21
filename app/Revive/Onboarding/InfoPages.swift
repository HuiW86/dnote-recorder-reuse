import SwiftUI

// P11 privacy and P12 permissions (product-spec.md §4.2). Bundled with the app, so they work
// offline (CLAUDE.md rule 3). Reached from P01 and from P09 settings.

struct PrivacyView: View {
    var body: some View {
        InfoPage(title: "隐私政策", sections: [
            ("不需要账号", "闻笺不需要注册或登录，也不会把你的信息发到我们的服务器。只有你自己设置了 AI 服务时，相关内容才会发给你选的那家服务，见下面「AI 服务」。"),
            ("录音存在哪里", "从录音卡同步来的、用这部手机录的和从其他 App 导入的录音，都只保存在 App 的本地存储里。删除 App 会一并删除这些录音。导出时，去向由你在系统分享面板里选。"),
            ("录音如何解密", "卡上的录音是加密的。解密用的密钥由 App 在这部手机上计算，不经过网络。"),
            ("我们不收集什么", "设备功能不联网。App 不收集录音、位置、通讯录或使用数据，也没有广告和统计。"),
            ("AI 服务", "只有你在设置里填了自己的 AI 服务，内容才会发给那个服务，不经过我们：生成纪要、改写、提问、润色、解释句子、列出生词、重新起标题时，发这条录音的文字稿（或其中几句）、纪要和你填的职业；在知识库提问时，发和问题最相关的 30 条以内的纪要；你另外填了转写模型并转成文字时，上传录音的音频。平时这些都要你点了才发；打开「录完自动整理」后，之后存进手机的录音会自动转成文字并整理纪要，不再等你点。服务怎样处理这些内容，以它自己的隐私政策为准。"),
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
            ("蓝牙 · 使用说明", "用来发现、连接录音卡，控制录音，并把卡上的录音同步到手机。锁屏或切到其他 App 时也会保持连接，卡上的录音结束后在后台自动同步。不允许蓝牙时连不上录音卡；已经同步的录音照常播放，用手机录音、导入和转文字也不受影响。"),
            ("语音识别 · 申请时机", "在设置里打开「本机转写」之后，第一次把录音转成文字时。"),
            ("语音识别 · 使用说明", "用来在这部手机上把录音转成文字，只用离线识别，不联网。不允许时不能转文字，其他功能不受影响。"),
            ("麦克风 · 申请时机", "第一次点「用手机录」时。"),
            ("麦克风 · 使用说明", "没有录音卡或录音卡不在身边时，用手机的麦克风录音。录音只保存在这部手机上。不允许时不能用手机录，录音卡的功能不受影响。"),
            ("通知 · 申请时机", "在设置里打开「同步完成时通知」时。"),
            ("通知 · 使用说明", "闻笺不在前台时，录音同步到手机后提醒你。通知在这部手机上产生，不经过任何服务器。不允许时开关会自动关回去，其他功能不受影响。"),
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
