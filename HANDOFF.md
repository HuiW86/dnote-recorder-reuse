# Handoff — 代码已经跑在计划前面；在第 ① 步 M1 验收过之前不加新功能，下一步是照 `docs/device-run-2.md` 做第 2 轮真机验收
<!-- Edited by hand on 2026-11-24 to match main d88af37 (PR #134 merged); not a /checkpoint run -->

## Objective
闻笺（Revive）：让失去官方后台的 D·NOTE 录音卡重新可用，再扩展成录音和声音内容的工作台（`CLAUDE.md` 定位）。推进顺序 ①～⑤ 见 `docs/features.md` §0。**眼下的目标是 ①：TestFlight 外部测试，卡友装上就能配对、录音、同步、播放**（#42，含 #66、#8）。

## 现状（2026-11-24）
- `features.md` 的 37 个条目里，状态是 `verified`（真机验证通过）的是 **0** 个；23 个 `done`（已合并）。T-M1-50～57 没有一条完整通过；T-M15-50～60 没有执行
- TestFlight 最后上传的是 0.1.0 (6)，基于 `86b898e`（2026-11-17/18）。之后 main 上改了 `app/` 的提交有 88 个，真机上只在 #89 的 DEBUG 构建上看过界面
- 代码已经做到 ⑤：M2 后端六片（#133、#134，替身代替真实的短信、邮件、ASR、大模型和 COS）、App 端账号页（#134，`ReviveAPIBaseURL` 为空时不出现）、Mac 原生版（#125）、MCP 和命令行（#132）、链接导入（#130）
- 决定（2026-11-24）：① 过了之前**不再加新功能**。只做验收要的修复、证据和文档

## Completed（本次会话，2026-11-24）
- 关闭 #136：和已合并的 #134 是同一功能（App 端账号页）的两套实现。#136 里多出来的 **P19 意见反馈页**（O1b 的 App 端）等 ① 之后在 main 的 `Account` 模块上补，分支 `claude/exciting-lovelace-y8qi4g` 保留可参考
- `docs/device-run-2.md`：第 2 轮真机验收脚本（A 部分 TestFlight、B 部分 DEBUG，约 3 小时）；结果模板 `evidence/v42-round2/README.md`，判据已预先写好
- `app/project.yml` 的 `CURRENT_PROJECT_VERSION` 改为 7（下一次上传）；`device-todo.md` 指向新脚本

## 开着的 PR（2026-11-24）
- #81（#79 构建 (5) 的复验记录）、#129（公开隐私页的生成脚本 `scripts/build_privacy_page.py`）已于 2026-11-24 合并。合并后在 main 上跑过 `client/tests/test_privacy_page.py`（5 个通过）；脚本现在因为 3 个占位符没填（日期、开发者名称、联系邮箱）拒绝生成，这是预期行为，填好后照 `docs/release/testflight.md` §1 托管
- #135（Mac 上改写和提问）：CI 通过，但 `docs/features.md`、`docs/product-spec.md` 和 main 冲突，要在它的分支上合一下 main。按上面的决定，等 ① 之后再合

## Next Actions
1. **你来做**：照 `docs/device-run-2.md` 打 0.1.0 (7)、装同一提交的 DEBUG 构建、跑 A、B 两部分，结果填 `evidence/v42-round2/README.md`。注意要先做 A1 升级，后面会删 App 重装
2. **你来做**：再找 2 张卡（#8）。这是外部测试前的硬门槛，只能你解决
3. 不通过的项开 issue 修；通过的项从 `device-todo.md` 删掉，结论贴到 #42
4. 外部测试前还要：隐私政策托管到公开地址并填好占位符（`docs/release/testflight.md` §1、§5），录演示视频
5. 准备周期长、可以现在就同时开始的（M2 部署要用）：腾讯云账号；**域名 ICP 备案**；核实个人主体能不能申请短信签名（不能就先只开邮箱登录，ADR-003）
6. 等你决定的：ADR-011 文末 3 个问题；ADR-012、ADR-013 是否接受；每月额度（`REVIVE_ASR_MONTHLY_SECONDS`、`REVIVE_LLM_MONTHLY_TOKENS`）
7. ① 之后再排：App 端「用闻笺账号」转写和整理（上传、任务轮询、`quota_exceeded`、`too_many_tasks`、换标题读 `result.title`）、首次登录合并本机录音（X3）、P19 意见反馈页、两项评估（`device-todo.md` §8a）

## 协作
- 一个方向同一时间只开一个会话（例如后端一个、App 一个），避免 #134 和 #136 这样的重复

## Risks & Decisions
- 写帧日志（`card-debug.log`）只有 DEBUG 构建有；TestFlight 构建的诊断日志不含帧，所以要看命令字的真机项只能用 Xcode 装的 DEBUG。DEBUG 的调试面板开着时 App 暂停自动同步（`RootView.swift` 的 `DebugEntry`），测自动同步时要关上
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
