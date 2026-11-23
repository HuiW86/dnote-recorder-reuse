# Handoff — 不需要真机的工作基本做完；下一步是装一个新构建，按 device-todo 做真机验收
<!-- Edited by hand on 2026-11-22 to match main 2e98f7f (PR #108–#133) plus the M2 slice 2 branch; not a /checkpoint run -->

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
- 2026-11-22：PR #130 合并：X12 的 iPhone 部分「从链接导入」（单集页面的 `og:audio`、RSS、Apple 播客、音频地址；联网模块 `LinkImport`）；`app/ReviveKit/scripts/linux-test.sh` 在 Linux 上跑 217 个 Swift 测试。用户决定先保留读网页的 `og:audio`（审核准则 5.2.3，退路见 `testflight.md` §2）
- 2026-11-22：PR #132 合并：X19 接入 AI 助手，`revive` 命令行与 MCP 服务（`docs/assistant-tools.md`）；打进 Mac 版要等 #125
- 2026-11-22：PR #133 合并：M2 后端第一片，账号（K1）、设备登记（A4b）、意见反馈（O1b）

## In Progress
- M2 后端第二片（分支 `claude/zen-allen-e62580`，等 CI 和合并）：录音与上传 `/v1/recordings`，预签名分片直传、断点续传、按 SHA-256 去重、下载地址、删除留墓碑；音频删除走 `object_deletions` 队列，注销时连音频一起删；COS 用本机替身 `LocalStore`（`/dev-storage` 签名地址，生产拒绝启动）；`python -m revive_api.maintenance` 清理存储挂掉时没删的、7 天没传完的。PR #134，backend-ci 已过
- M2 后端第三片（同一分支，追加在 #134 上）：任务队列（ADR-013，Proposed：自己写，一张 `tasks` 表，自动重试 30/60/120 秒、15 分钟租约）、工作进程 `python -m revive_api.worker`（顺带每 10 分钟跑维护）、`GET /tasks/{id}`；转写骨架 `POST /recordings/{id}/transcribe`、文字稿、说话人命名、`asr_seconds` 用量；识别引擎是 `asr.Transcriber` 接口，暂用 `StandInTranscriber`（生产拒绝启动）。后端测试 61 个。ADR-012、ADR-013 都是 Proposed，等你确认
- M2 后端第四片（同一分支，追加在 #134 上）：AI 纪要 `POST/GET /recordings/{id}/summaries`、`GET /templates`；提示词、长文分段、回复解析照 App 的 `Summarizer` 移植，`app/ReviveKit/Tests/AssistantTests/Fixtures/prompts` 的 7 个样本两边逐字比对（App 端 `PromptFixtureTests` 只能等 #134 的 app-ci 在 macOS 上验证）；大模型是 `llm.ChatModel` 接口，暂用 `StandInChatModel`。App 端 `Summarizer` 抽出 `userMessage`、`chunkNotes` 两个函数，行为不变。后端测试 79 个。#134 的 CI（backend-ci、macOS 上的 app-ci）都已通过
- M2 后端第五片（同一分支，2026-11-23）：用量与额度骨架，`GET /me/usage`、按北京时间自然月、转写按时长预占、纪要 token 用完即止、`429 quota_exceeded`、每人最多 10 个排队任务；额度数值未定（配置项，生产环境必须设）。后端测试 87 个
- M2 后端第六片（同一分支，2026-11-23）：换角度重起标题 `POST /recordings/{id}/retitle`，新标题在任务的 `result` 里（`tasks` 加 `result` 列），录音标题由 App 决定是否替换；App 端抽出 `Summarizer.retitleMessage`，提示词样本 8 个。后端测试 92 个。M2 后端里不需要外部条件的部分到这里做完了
- 其他会话开着的：PR #125（Mac 版，ADR-011 已接受）、#129（公开隐私页的生成脚本）、#81（#79 的复验记录）。#130 改了 `privacy-policy.md` 的正文，#129 合并时可能要手动合一下

## Next Actions
1. 装一个当前 main 的构建（PR #124 之后；#110 也改了 App 代码）（TestFlight 要先把 `app/project.yml` 的 `CURRENT_PROJECT_VERSION` 加 1），按 `docs/device-todo.md` 的顺序做真机检查。新增的几项都在 §6：T-M15-60 先不连卡（审核员走的路，外部测试前必须过）、T-M2-10 关掉「无线数据」、T-M4-17～21 手机录音
2. #42：T-M1-50～57、多卡 #8（至少 3 张卡）、#66 的 TOC 统计
3. 发布前：隐私政策托管到公开地址并填好占位符（`docs/release/testflight.md` §1、§5），录演示视频
4. 两项评估（`device-todo.md` §8a）：备好真卡录音和参考文本、服务商账号后，按 `asr-evaluation.md`、`summary-evaluation.md` 跑，结果填进去
5. 需要用户决定或提供条件才能做的：
   - ADR-011 文末的 3 个问题：原生还是 Catalyst；是否在 App Store 之外分发，证书和下载页谁提供；要不要先让 Mac 用户直接装 iPhone 版
   - M2 后端：确认 ADR-012；腾讯云账号（服务器、PostgreSQL、COS、KMS）；短信签名和模板（个人主体能否申请要核实，不能就先只开邮箱登录，ADR-003）；发信用的邮件服务；域名 ICP 备案。有了这些才能把替身换成真实的短信、邮件和密钥服务并部署
   - 额度定多少：每月转写多少分钟、大模型多少 token（`REVIVE_ASR_MONTHLY_SECONDS`、`REVIVE_LLM_MONTHLY_TOKENS`）
   - M2 后端里不需要外部条件的部分已做完；下一步是 App 端的登录和「用闻笺账号」这条路（App 要处理 `quota_exceeded`、`too_many_tasks`，换标题读任务的 `result.title`）。真 ASR 引擎等 ASR 对比结果和账号。COS 的真实 `ObjectStore` 实现等账号；到时 COS 上要配「7 天清掉未完成的分片上传」的生命周期规则
   - M6：两种设备的真机
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
- `cd backend && TEST_DATABASE_URL=... .venv/bin/pytest`（容器里：`service postgresql start`，给 postgres 设密码，建 `revive_test` 库）
- `cd app && xcodegen generate && xcodebuild build -project Revive.xcodeproj -scheme Revive -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO`
