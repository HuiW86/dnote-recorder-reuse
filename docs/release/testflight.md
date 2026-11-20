# TestFlight 外部测试：发布材料与检查清单

**来源**　#42（M1.7 真机验收与 TestFlight 发布）；ADR-004（TestFlight 分发）、ADR-008（显示名「闻笺」）、ADR-009（用户自配 AI 服务）
**日期**　2026-11-16（草稿）；2026-11-20 按 `main` 上已合并的功能更新（M1.5、自配 AI 服务、手机录音、导入导出），不再只写 M1

本文汇总外部测试要在 App Store Connect 里填写的内容，可直接复制。【方括号】是待填的占位符。标 **【待核对】** 的条目来自 Apple 文档或常见做法，提交前要在 App Store Connect 当时的界面上再确认一遍。

所有文案只能写「适用于 D·NOTE 录音卡」，不出现对方的其他商标（`CLAUDE.md` 硬规则 5）。

---

## 1. 隐私政策托管

**建议**：单独建一个**公开**的 GitHub 仓库，开启 GitHub Pages，只放隐私政策一页（内容取自 `privacy-policy.md`，删掉开头的维护说明框）。

- 仓库名用中性名称，例如 `wenjian-app`，不含对方商标。地址形如 `https://【GitHub 用户名】.github.io/wenjian-app/privacy.html`
- 为什么选它：不用登录就能打开；地址稳定；免费；改动有版本记录；独立开发者给 App 挂隐私政策常这么做
- 不用本仓库：本仓库是私有的，而且里面有 `DEVICE_KEY_SECRET`（ADR-006），不能为了一页隐私政策公开
- 不用 claude.ai Artifact 或 Notion 分享页：它们不是为长期稳定的公开地址设计的，Notion 在国内访问也不稳定
- 国内访问：`github.io` 在国内偶尔慢，但 Beta 审核由 Apple 访问，测试员也很少需要打开。M2 在腾讯云（ADR-003）部署后端并完成备案后，可以把页面迁到自己的域名，再到 App Store Connect 改链接

## 2. App 隐私（App Store Connect →「App 隐私」）

**回答**：「否，我们不从此 App 收集数据」。选择后问卷结束，不需要再答后面的问题。

依据（Apple「App 隐私详细信息」页面）：只在设备上处理的数据不算「收集」；「收集」指把数据传出设备，让开发者或其第三方合作方能以可读形式访问，且保存超过实时处理请求所需的时间。现在的闻笺：

- 没有后端，也没有第三方 SDK；设备模块（配对、录音控制、同步、播放、导出）不使用联网 API，由 `scripts/check-m1-rules.sh` 在 CI 中检查
- 录音、数据库、诊断日志都只在本机；诊断日志只有用户主动分享时才离开手机，去向由用户在系统分享面板里选择
- 唯一联网的是自配 AI 服务（X11，`Assistant` 模块）：地址、模型和密钥都由用户自己填，App 不内置任何服务商密钥；只在用户点了某个 AI 功能、或自己打开了「录完自动整理」（X22）时，把文字稿、纪要或（「转成文字」时）音频从手机直接发给那个服务。开发者收不到这些内容，那个服务也不是开发者的合作方，所以按上面的定义不算开发者「收集」

**【待核对】**
- TestFlight 的崩溃报告和测试员反馈由 Apple 收集，一般不算开发者「从此 App 收集」，提交前对照 Apple 当前说明确认
- 自配 AI 服务按上面的理由答「不收集」，提交前对照 Apple 当前说明再确认一次；如果 Apple 认为要申报，按「用户内容（音频、其他用户内容）· 用于 App 功能 · 不与身份关联」填
- M2 加入账号与我们自己的后端后，这份回答必须重新填写

隐私政策 URL 填 §1 的地址。

## 3. TestFlight 测试信息（TestFlight →「测试信息」）

### 3.1 Beta 版 App 描述（必填）

> 闻笺是适用于 D·NOTE 录音卡的 iOS App，不需要注册：通过蓝牙配对录音卡，在手机上开始或停止录音，录音结束后自动把卡上的录音同步到手机，可以播放、标重点、改标题，也可以导出为 M4A 等格式。卡不在身边时可以用手机麦克风录，也可以从「文件」导入音频。打开「本机转写」可以在手机上离线转成文字。录音只保存在你的手机上。
>
> 纪要、改写、提问等 AI 功能是可选的，要在设置里填你自己的 AI 服务（兼容 OpenAI 接口的地址和密钥），内容从手机直接发给你选的服务；不填也不影响其他功能。
>
> 这是第三方开发的 App，不是录音卡厂商的官方 App。

### 3.2 测试内容（每个构建填写，测试员能看到）

> 请帮忙试一试这些：
> 1. 配对：按住录音卡的录音键，看到白灯闪烁后松手，在 App 里完成配对
> 2. 录音：在 App 里开始、停止录音；也试试直接按卡上的按键录音
> 3. 同步：录音结束后，录音会自动出现在「录音」列表；试试锁屏、切到其他 App 时是否也能同步
> 4. 播放与导出：播放录音，用「⋯ → 分享」导出 M4A，在微信或「文件」里打开试试
> 5. （可选）在「设置」里打开「本机转写」，把一条录音转成文字
>
> 说明：
> - 首次打开时，系统可能询问「是否允许闻笺使用无线数据」。录音卡、录音、同步、播放和导出都不需要联网，选「不允许」不影响这些功能；以后要用自己的 AI 服务时，到 iPhone 的「设置 › 闻笺 › 无线数据」里打开
> - 「同步后删除卡上文件」默认关闭；打开后，只有录音已经存入手机，才会删除卡上的文件
> - 遇到问题，请在「设置」里导出诊断信息，连同问题描述一起通过 TestFlight 反馈。诊断信息不含录音

### 3.3 反馈电子邮件（必填）

【反馈邮箱】。测试员在 TestFlight 里的反馈会发到这里，它也是邀请邮件的回复地址。

### 3.4 Beta 版 App 审核信息（必填）

- **联系人**：【姓名】、【电话】、【邮箱】
- **登录信息**：不需要登录。取消勾选「需要登录」
- **审核备注**：

> This app is a companion for the D·NOTE voice recorder card, a Bluetooth hardware device. Pairing and syncing need the card; a video of the full flow on a real card is here: 【演示视频链接】. Without a card you can still try most of the app: on the first screen, tap "先不连卡，直接用" (use without a card). Then tap the red button in the middle of the tab bar and choose "用这部手机录" to record with the iPhone microphone, or import an audio or text file with the button at the top right of 录音. You can play, rename, star and export recordings, and transcribe them on the device after turning on 本机转写 in Settings (录音卡 tab, gear at the top right). Choosing "先不连卡" does not ask for Bluetooth.
>
> There is no account, no developer server and no third-party SDK. The optional AI features (summaries, rewriting, questions) use an OpenAI-compatible service that the user configures with their own address and API key; the app contacts only that service, only when the user taps an AI feature or turns on automatic processing of new recordings, and ships with no key of ours. Everything else works offline. On some iPhones, iOS shows a "wireless data" permission prompt on first launch; choosing "Don't Allow" does not affect the card, recording, playback or export.
>
> 本 App 用于配合 D·NOTE 录音卡（蓝牙硬件）。配对和同步需要录音卡，真卡全流程演示视频：【演示视频链接】。没有录音卡也能试大部分功能：在第一页点「先不连卡，直接用」，然后点底栏中间的红色按钮，选「用这部手机录」用手机麦克风录音，或在「录音」右上角导入音频或文字文件；可以播放、改名、标星、导出，在「设置」（「录音卡」标签右上角的齿轮）里打开「本机转写」后可以在手机上转成文字。选「先不连卡」不会请求蓝牙权限。没有账号、开发者服务器和第三方 SDK。可选的 AI 功能（纪要、改写、提问）使用用户自己填写地址和密钥的兼容 OpenAI 接口的服务，只在用户点了 AI 功能或自己打开「录完自动整理」时联系那个服务，App 不内置我们的密钥；其余功能都不联网。部分 iPhone 首次启动时系统会弹出「无线数据」权限询问，选「不允许」不影响录音卡、录音、播放和导出。

**【待核对】** 需要硬件的 App，审核员手上没有设备时，常见做法是提供一段演示视频。演示视频用真卡录：从配对到导出 M4A 走一遍，最好和 T-M1-50 一起录。画面里不要出现完整的 `sn` 或蓝牙地址（硬规则 4）。

**【待核对】** AI 功能要用户自己的密钥。审核员如果要求试用，是否要另给一个测试用的密钥，以审核反馈为准；给的话只写在「审核备注」里，不进 App、不进仓库，审核结束后在服务商那里作废。

「先不连卡，直接用」和「用这部手机录」「导入」入口的位置以 `product-spec.md` 当前版本为准（1.3.3）；界面再改时同步改这段备注。审核员走的就是 T-M15-60 这条路，提交审核前先在真机上走一遍。

## 4. 出口合规

已处理：`Info.plist` 的 `ITSAppUsesNonExemptEncryption = NO`（PR #56），之后的构建不用再回答。

## 5. 发布前检查清单

- [ ] 把要发的代码改动合并进 `main`，再打验收构建：通过 T-M1-50～57 的构建，就是发给外部测试员的构建
  - PR #64（#59，解密失败按构建号重试；含数据库迁移 `v2`）已合并；之后的迁移到 `v15`，T-M1-56 的覆盖安装要从 0.1.0 (1) 一路升到当前版本
- [ ] `app/project.yml` 的 `CURRENT_PROJECT_VERSION` 加 1。构建号也决定 #59 的「换构建后重试一次」
- [ ] 真机用例 T-M1-50～57 全部通过，证据入库（`test-spec.md` §4）。其中 T-M1-56：在装着 0.1.0 (1) 的手机上覆盖安装，录音、设备、配对都保留，迁移 `v2` 成功
- [ ] 多卡回归：至少 3 张卡（#8，硬规则 7）
- [ ] 隐私政策已托管（§1），占位符已填，与 App 内 P11 一致（含「AI 服务」一节）
- [ ] App 隐私已回答（§2），自配 AI 服务那条已按 Apple 当时的说明核对
- [ ] 真机：系统设置里关掉闻笺的「无线数据」后，录音卡、录音、同步、播放、导出都正常；点「生成纪要」时 Toast 指向「设置 › 闻笺 › 无线数据」（T-M2-10）
- [ ] 真机：T-M15-60 先不连卡通过（审核员没有卡时走这条路）
- [ ] 测试信息已填写（§3），演示视频已上传
- [ ] 提交 Beta 版 App 审核；通过后建外部群组、发公开链接
- [ ] `features.md` M1 条目状态更新为 verified

## 参考

- [Provide test information（App Store Connect 帮助）](https://developer.apple.com/help/app-store-connect/test-a-beta-version/provide-test-information/)
- [Invite external testers（App Store Connect 帮助）](https://developer.apple.com/help/app-store-connect/test-a-beta-version/invite-external-testers/)
- [App Privacy Details（Apple）](https://developer.apple.com/app-store/app-privacy-details/)
- [Manage app privacy（App Store Connect 帮助）](https://developer.apple.com/help/app-store-connect/manage-app-information/manage-app-privacy/)
