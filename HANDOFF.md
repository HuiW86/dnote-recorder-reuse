# Handoff — 不需要真机的工作基本做完；下一步是装一个新构建，按 device-todo 做真机验收
<!-- Edited by hand on 2026-11-21 to match main aed4bdb (PR #108–#124), then for PR #130; not a /checkpoint run -->

## Objective
复刻 D·NOTE 官方 App（Revive，显示名「闻笺」），面向三类人（`CLAUDE.md` 定位）。当前推进顺序的第 ① 项：M1 验收与 TestFlight 外部测试（#42，含 #66）。

## Completed（2026-11-20～21，都已合并到 main）
- PR #108（另一个会话）：录音状态三路来源按统一规则合并，关闭 #53；新增 `docs/device-todo.md`；X22「录完自动整理」
- PR #109：
  - P01「先不连卡，直接用」：没有卡也能进入标签栏；iOS 没问过蓝牙时用 `NoCardLink`，不弹权限框；「添加录音卡」回到 P01
  - AI 请求没有网络、或关了「无线数据」时提示去哪里打开（`AssistantError.offline`）
  - TestFlight 材料和公开隐私政策按当前功能重写；审核备注引导审核员走「先不连卡」
- 手机录音（X18）补强：
  - PR #109：来电等打断时暂停并说明原因
  - PR #111：录音中写 CAF，App 被关掉后下次打开找回
  - PR #113：录音中标重点（迁移 `v16`，`phone_mark`）
  - PR #114：存储空间不到 100 MB 不开始，录音中不到 30 MB 自动停止并保存
  - PR #115：录音器自己停下（写入出错、媒体服务重置）时保存录到的部分
- PR #112：P10「关于」加非官方声明，开源许可加 beanpod（MIT）
- PR #116：P11、P12 的文字跟上先不连卡和手机录音
- PR #117：「什么时候创建蓝牙」的规则移到 `AppModel/BluetoothStart.swift` 并有测试
- 顺带修了 `PlayerTests` `reachesEndAndResets` 在 CI 上的超时（等待 3 s → 30 s）
- 之后（2026-11-21）：
  - PR #118：本文件和 `device-todo.md` 跟上 main
  - PR #119、#120、#122（另一个会话）：`SyncEngine` 改为依赖不绑定设备的 `DeviceSource`；多语言评估，决定先只做简体中文
  - PR #110（另一个会话）：知识库提问只发和问题相关的纪要
  - PR #121：ADR-011 提议稿，Mac 版用原生 macOS 目标、Developer ID 分发；状态 Proposed，等用户决定
  - PR #123：ASR 对比的方法和打分工具（`docs/asr-evaluation.md`、`client/asr_eval.py`）
  - PR #124：纪要提示词 × 模型的盲评方法和汇总工具（`docs/summary-evaluation.md`、`client/summary_scores.py`）

## In Progress
- PR #130（本会话，等 app-ci 和合并）：
  - X12 的 iPhone 部分「从链接导入」：播客单集页面、RSS、Apple 播客、音频地址；新联网模块 `LinkImport`
  - `app/ReviveKit/scripts/linux-test.sh`：没有 macOS 时在 Linux 上跑只用 Foundation 的那 217 个测试
- 其他会话开着的：PR #125（Mac 版，ADR-011 已接受）、#129（公开隐私页的生成脚本）、#81（#79 的复验记录）。#130 也改了 `privacy-policy.md` 的正文，和 #129 合并时可能要手动合一下

## Next Actions
1. 装一个当前 main 的构建（PR #124 之后；#110 也改了 App 代码）（TestFlight 要先把 `app/project.yml` 的 `CURRENT_PROJECT_VERSION` 加 1），按 `docs/device-todo.md` 的顺序做真机检查。新增的几项都在 §6：T-M15-60 先不连卡（审核员走的路，外部测试前必须过）、T-M2-10 关掉「无线数据」、T-M4-17～21 手机录音
2. #42：T-M1-50～57、多卡 #8（至少 3 张卡）、#66 的 TOC 统计
3. 发布前：隐私政策托管到公开地址并填好占位符（`docs/release/testflight.md` §1、§5），录演示视频
4. 两项评估（`device-todo.md` §8a）：备好真卡录音和参考文本、服务商账号后，按 `asr-evaluation.md`、`summary-evaluation.md` 跑，结果填进去
5. 需要用户决定或提供条件才能做的：
   - ADR-011 文末的 3 个问题：原生还是 Catalyst；是否在 App Store 之外分发，证书和下载页谁提供；要不要先让 Mac 用户直接装 iPhone 版
   - M2 后端：云厂商账号
   - M6：两种设备的真机
   - 从链接导入与审核准则 5.2.3：读单集网页的 `og:audio` 是否保留（`testflight.md` §2 的【待核对】；退路是只留 RSS、Apple 播客和音频直链）
6. 从链接导入的真手机检查：`device-todo.md` §6a（T-M5-60～62），和 §6 的 T-M2-10 一起做

## Risks & Decisions
- 用户决定（2026-11-20）：加「先不连卡，直接用」
- `AVAudioRecorder` 被杀掉时留下的 CAF 是否真的可读，单元测试只模拟了被截断的文件，要真机确认（T-M4-18）
- 「无线数据」关掉时 iOS 报的是不是 `-1009`，要国行 iPhone 确认（T-M2-10）
- 「设置 › 开发者 › 重置媒体服务」这一项是否存在没有核实（T-M4-21 用它触发）
- 本容器默认没有 Swift 工具链：`app/ReviveKit/scripts/linux-test.sh --install` 下载 Swift 6.2（约 1 GB），之后能跑 CardProtocol、CardLink、CardService、DeviceSource、Library、SyncEngine、LinkImport 的测试。AVFoundation、Speech、CoreBluetooth、SwiftUI 的部分和 iOS 构建仍然只能看 PR 的 app-ci；app-ci 只在 PR 和推送 main 时跑

## Verify
- `cd app/ReviveKit && swift test --disable-xctest`（macOS）
- `app/ReviveKit/scripts/linux-test.sh`（Linux，只是其中一部分）
- `scripts/check-m1-rules.sh`、`scripts/check-theme.sh`
- `cd client && python3 -m pytest`
- `cd app && xcodegen generate && xcodebuild build -project Revive.xcodeproj -scheme Revive -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO`
