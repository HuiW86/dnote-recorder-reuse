import SwiftUI

// P11 privacy and P12 permissions (product-spec.md §4.2). Bundled with the app, so they work
// offline (CLAUDE.md rule 3). Reached from P01 and from P09 settings.

struct PrivacyView: View {
    var body: some View {
        InfoPage(title: "隐私政策", sections: [
            ("不需要账号", "闻笺不需要注册或登录，也不会把你的信息发到我们的服务器。只有你自己设置了 AI 服务时，相关内容才会发给你选的那家服务，见下面「AI 服务」；从链接导入播客时会访问你给的链接，见下面「从链接导入」。"),
            ("录音存在哪里", "从录音卡同步来的、用这部手机录的、从其他 App 导入的和从播客链接下载的录音，都保存在本机的闻笺录音库。根据你的设备备份设置，iCloud 备份或电脑备份也可能保存录音库。删除 App 会删除这部手机上的副本。导出时，去向由你在系统分享面板里选。"),
            ("录音如何解密", "卡上的录音是加密的。解密用的密钥由 App 在这部手机上计算，不经过网络。"),
            ("我们不收集什么", "设备功能不联网。App 不收集录音、位置、通讯录或使用数据，也没有广告和统计。"),
            ("AI 服务", "只有你在设置里填了自己的 AI 服务，内容才会发给那个服务，不经过我们：生成纪要、改写、提问、润色、解释句子、列出生词、重新起标题时，发这条录音的文字稿（或其中几句）、纪要和你填的职业；在知识库提问时，发和问题最相关的 30 条以内的纪要；你另外填了转写模型并转成文字时，上传录音的音频。平时这些都要你点了才发；打开「录完自动整理」后，之后存进手机的录音会自动转成文字并整理纪要，不再等你点。服务怎样处理这些内容，以它自己的隐私政策为准。"),
            ("从链接导入", "粘贴播客链接并确认后，App 直接访问这个链接、下载其中的音频；Apple 播客的链接还会向 Apple 的公开查询服务查这一期的音频地址，只带链接里的节目编号。请求里没有账号、Cookie 或录音库的内容，不经过我们。请只导入你有权使用的公开内容。"),
            ("本机转写", "用「本机」方式转文字时（默认就是本机），录音在这部手机上转成文字，识别过程在本机完成，无需上传音频。只在你点「转成文字」，或打开「录完自动整理」后新录音自动转写时用到。"),
            ("诊断信息", "App 在本机记录连接、同步和出错的过程，最多保留 1 MB，不含录音。序列号只记一段摘要，不记完整号码。出问题时你可以在「设置」里手动导出，分享对象由你选择。系统备份也可能包含这个日志。"),
        ])
    }
}

/// Follows the official app's "when it is asked / what it is for" layout; M1 needs Bluetooth only.
struct PermissionsView: View {
    var body: some View {
        InfoPage(title: "权限说明", sections: [
            ("蓝牙 · 申请时机", "第一次连接录音卡之前。"),
            ("蓝牙 · 使用说明", "用来发现、连接录音卡，控制录音，并把卡上的录音同步到手机。锁屏或切到其他 App 时也会保持连接，卡上的录音结束后在后台自动同步。不允许蓝牙时连不上录音卡；已经同步的录音照常播放，用手机录音、导入和转文字也不受影响。"),
            ("语音识别 · 申请时机", "第一次用「本机」方式把录音转成文字时。"),
            ("语音识别 · 使用说明", "用来在这部手机上把录音转成文字，只用离线识别，不联网。不允许时不能转文字，其他功能不受影响。"),
            ("麦克风 · 申请时机", "第一次用这部手机录音时。"),
            ("麦克风 · 使用说明", "没有录音卡或录音卡不在身边时，用手机的麦克风录音，保存到闻笺录音库。不允许时不能用手机录，录音卡的功能不受影响。"),
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
