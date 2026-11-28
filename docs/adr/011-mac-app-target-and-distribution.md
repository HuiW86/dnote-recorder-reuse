# ADR-011：Mac 版用原生 macOS 目标，先用 Developer ID 分发

**日期**　2026-11-21
**状态**　Accepted（用户 2026-11-21 决定：界面层 A 原生 macOS 目标，分发 D Developer ID；第 2 条里证书和托管由谁提供、第 3 条要不要先用方案 C，仍待定）
**来源**　#72（M5 验收第一条：「进入阶段前写 ADR：Mac 版用原生 macOS 目标还是 Mac Catalyst；分发方式」）、#75 第五节

## 背景

- 用户 2026-11-16 决定做 Mac 版和创作功能（X12～X14、X16、X19，`features.md`、#72）。ADR-001 只决定了 iOS 用原生 Swift，ADR-004 只覆盖 iOS 的 TestFlight 分发。
- 现有代码：
  - `ReviveKit` 已声明 macOS 14，`swift test` 一直在 macOS 上跑（app-ci）。模块里只有 5 处 `#if os(iOS)`，主要是 `AVAudioSession`。
  - App 目标 `app/Revive/`（36 个 Swift 文件）是 SwiftUI。其中 11 个文件用到 UIKit：分享面板、打开系统设置、无障碍播报、`UIApplicationDelegateAdaptor`。界面状态大多在 `AppModel` 里，已有测试。
- Mac 版要做的功能，有几项依赖 Mac App Store 沙盒通常不允许的能力：
  - X14 语音输入：全局按键，把文字打进别的软件，要「辅助功能」权限。
  - X12 视频链接导入：beanpod 用 `yt-dlp` 这类命令行下载器，要随时更新。
  - X19 MCP 服务和命令行：要让 App 之外的进程读录音库。
  这几点要在实施前对照 Apple 当时的规则核实（标【待核实】的都是）。
- 约束：
  - 硬规则 1～3 对 Mac 版同样生效：`scripts/check-m1-rules.sh` 要覆盖 Mac 目标。
  - 硬规则 6：Mac 的蓝牙栈不同，配对、同步要重新取证，不能默认和 iPhone 一样（#72 约束）。
  - 硬规则 5：名称、图标、Bundle ID 规则不变。

## 候选方案

### 界面层

**A. 原生 macOS 目标（SwiftUI + 必要处用 AppKit），和 iOS 共用 `ReviveKit`、`AppModel`**
- 优点：
  - 全局按键、菜单栏常驻、命令行和 MCP 辅助进程都能直接做，X14、X19 不受框架限制。
  - 窗口、侧边栏、键盘快捷键都按 Mac 的习惯来。
  - beanpod 也是原生 macOS（`beanpod-evaluation.md` §1），可以参照它的界面和辅助进程。
- 缺点：
  - 界面层要另写一份：共用 `AppModel`，视图按平台分。iOS 的 36 个视图文件里，用到 UIKit 的 11 个要改写或加条件编译。
  - 两套界面都要维护，改版（design-spec）要两边各做一次。

**B. Mac Catalyst（把现有 iOS App 编译成 Mac App）**
- 优点：
  - 最快得到 M1 闭环（配对、录音控制、同步、播放、导出）。现有视图和测试几乎都能直接用，CoreBluetooth 在 Catalyst 下可用。
- 缺点：
  - 全局按键、往别的软件里打字、菜单栏常驻都要绕到 AppKit 插件包，做起来别扭，X14 是 M5 的核心功能之一。
  - 界面带着 iPad 的样子，和「Mac 上的工作台」定位不符。
  - 以后要改原生，界面层还是要重写，等于做两次。

**C. 只用「在 Mac 上运行 iPad App」（Apple 芯片 Mac 直接装 iOS 版）**
- 优点：零开发。
- 缺点：
  - 不能做任何 Mac 专属功能。
  - 只用于临时让用户在 Mac 上看录音，不算 Mac 版。

### 分发

**D. Developer ID 签名 + 公证，在 App Store 之外分发（网站下载或 GitHub Releases），用 Sparkle 之类的方式更新**
- 优点：
  - 不受沙盒限制：辅助功能权限、调用和更新命令行下载器、给命令行和 MCP 辅助进程开放录音库，都能做。
- 缺点：
  - 要自己托管安装包和更新。
  - 用户第一次打开会看到「来自互联网」的提示。
  - 没有 TestFlight 那样现成的测试员管理。

**E. Mac App Store / Mac 上的 TestFlight（必须开沙盒）**
- 优点：
  - 和 iOS 一样的测试与审核流程，用户最熟悉。
- 缺点：
  - X14 的全局输入、X12 的下载器、X19 的外部进程访问，很可能过不了沙盒或审核【待核实】。
  - 这几项正是 M5 的主要内容。

## 决定

界面层选 **A**：原生 macOS 目标，与 iOS 共用 `ReviveKit` 和 `AppModel`，视图按平台分开写。分发选 **D**：Developer ID + 公证，在 App Store 之外分发。

做法上分两步：

1. **M5 第一步：Mac 上的 M1 闭环**（#72 验收第二条）
   - 在 `app/project.yml` 加 macOS 目标。
   - 视图先移植录音列表、详情、配对、设置；用到 UIKit 的那 11 处改成按平台实现。
   - `scripts/check-m1-rules.sh` 扩到 Mac 目标。
   - 在 Mac 上用真卡重新取证配对和同步（硬规则 6）。
2. **M5 第二步：X14、X12、X19 这些需要沙盒之外能力的功能**。
   - 这时再按 Apple 当时的规则核实一次：如果其中一部分能在沙盒里做，可以另出一个功能少一些的 Mac App Store 版，作为补充，不替代 D。

## 后果

- 正面：
  - M5 的核心功能不受框架和沙盒限制，不会做到一半发现要重写界面或换分发方式。
  - iOS 版不受影响：共用的是已经有测试的模块，iOS 的视图不动。
  - 共用 `AppModel` 后，新功能的模型逻辑和测试两个平台写一次。
- 负面：
  - 两套视图要维护；界面改版要两边各做。
  - 要搭 Developer ID 证书、公证、安装包托管和自动更新，iOS 没有这些。
  - Mac 版的测试员要单独管理，TestFlight 不能用。
- 反悔成本：
  - 界面层：A 改成 B 只是丢掉 Mac 视图；B 改成 A 要重写整个界面层。所以先选 A 风险更小。
  - 分发：D 改成 E 要给 App 加沙盒，并把沙盒外的功能拆掉或换实现；E 改成 D 只要换签名和托管。

## 待用户决定

1. 同不同意界面层用原生目标（A），而不是 Catalyst（B）。
2. 同不同意先在 App Store 之外分发（D）；需要的 Developer ID 证书和下载页托管，由谁提供。
3. 第一步做完前，要不要先用方案 C（在 Apple 芯片 Mac 上直接装 iOS 版）给 Mac 用户临时用。

## 实施记录

- 2026-11-21：M5 第一步的第一部分合入。`app/project.yml` 加 macOS 目标 `ReviveMac`（Bundle ID `com.huiw86.revive.mac`，开启 hardened runtime，不开沙盒），CI 每个 PR 都构建它；窗口是 `NavigationSplitView`：左边是这台 Mac 上的录音（搜索、导入音频或文字文件、拖进窗口导入），右边是播放、纪要和文字稿。列表的状态在 `AppModel` 的 `LibraryBrowserModel`，导入抽成 iOS 和 Mac 共用的 `LibraryImport`。配对、同步、转文字和整理纪要还没有：前两者要先在 Mac 上用真卡取证（硬规则 6）。`scripts/check-m1-rules.sh` 的禁发命令字检查本来就扫整个 `app/`，已覆盖 Mac 目标；`scripts/check-theme.sh` 扩到 Mac 视图。
- 2026-11-21：Mac 上加转文字和生成纪要。设置窗口（⌘,）用 iPhone 同一个 `AssistantSettingsModel`；选用哪个服务、哪种转写的逻辑从 iOS 的 `AppEnvironment` 移到 `AppModel`（`AssistantConfigSource.saved()`、`TranscriberChoice`），两边共用。密钥用同一个 `KeychainKeyStore` 存；macOS 上没有指定数据保护钥匙串，预计落在登录钥匙串里，iOS 的「只在本机」属性在那里不起作用。这一点还没有在 Mac 上实际保存、读取过（`device-todo.md` §9）。Mac 和 iPhone 的密钥不互通。
- 2026-11-21：Mac 上加重命名和导出。导出用 `RecordingDetailModel` 现成的导出（与 iPhone 相同的文件），iPhone 的分享面板在 Mac 上换成保存面板（`FileSaver`）。
- 2026-11-23：Mac 上加改写和单条提问，用 `RecordingDetailModel` 的 `rewrite`、`ask` 和流式回复；回复窗口在 Mac 上用拷贝代替分享。
