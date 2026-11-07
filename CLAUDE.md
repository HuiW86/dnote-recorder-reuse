# CLAUDE.md

替代 D·NOTE 官方 App 的 iOS App（代号 Revive）加后端，让失去官方后台的这一批录音卡重新可用。设备功能离线优先：配对、录音、同步、播放不依赖登录和网络。

## 硬规则

每条后面是它存在的原因。违反任何一条前，先停下来问人。

1. **对真机不发 `0x93` 恢复出厂、`0x94` 格式化、`0xB0`/`0xB1` 固件升级**，代码里也不留发送这些命令的路径。
   原因：会清空录音或可能变砖，不可逆（`backend-design.md` §7.1 第 6 条；`features.md` A5b、A6）。
2. **卡上的文件，确认已存入手机本地后才能用 `0x91` 删除。**
   原因：卡是录音的唯一副本；同步中断重试时不能丢，也不能重复（#11）。
3. **设备功能不能依赖登录和网络。** 配对、录音控制、蓝牙同步、播放、导出 OGG 的代码路径里不能出现后端调用。
   原因：官方 App 正是因为配对放在登录之后，登录一断整张卡就不能用了（`backend-design.md` §1.3）。
4. **新证据要脱敏**：`sn` 只记 SHA-256 前 8 位十六进制，`btaddr` 只留后两段，`bondId` 不记录。录音音频不入库（`.gitignore` 已覆盖 `*.ogg`、`*.raw`、`live.bin`）。
   原因：仓库里有 `DEVICE_KEY_SECRET`，加上 `sn` 就能算出这张卡的音频密钥（ADR-006）。
5. **App 名称、图标、Bundle ID 不使用 D·NOTE、追觅、Dreame。** 描述里只能写「适用于 D·NOTE 录音卡」。
   原因：对方商标（ADR-005）。
6. **结论要有真机证据。** 涉及设备行为的结论，要把命令、原始日志、校验值、判据写进 `evidence/<验证编号>/`，能复现。
   原因：阶段 0 有多个文档里的假设被真机推翻（`backend-design.md` §3.2）。
7. **固件版本只验证过 v1.50。** 遇到其他版本时，在界面上提示并写日志，不要默认行为一致。
   原因：只有 1 张卡做过验证；多卡样本 #8 要在 M1 发布前补齐。

## 工作方式

- 推进：milestone → issue → PR。每个 issue 写目标、二值验收标准、依赖、通用完成定义；PR 正文写 `Closes #N`。
- 提交信息用英文，遵循 Conventional Commits；代码注释用英文；文档用中文。
- 选型或不可逆的决定写 ADR（`docs/adr/`，模板 `000-template.md`）。已接受的 ADR 不改原文，改主意就新开一份。
- 范围以 `docs/features.md` 为准；改范围时同步修改 #11～#14 的「范围」和 `features.md` 的变更日志。
- 上游文档（`backend-design.md`、`features.md`）改了，要检查下游（ADR、`prd.md`、`test-spec.md`）是否需要跟着改。

## 常用命令

```bash
# Python 命令行客户端（真机验证）
cd client && python3 -m venv .venv && source .venv/bin/activate && pip install -r requirements.txt
python dnote.py scan | info | record --seconds 20 | list | pull --out ./recordings

# iOS 原型
cd ios-prototype && xcodegen generate
xcodebuild test -project DNoteProbe.xcodeproj -scheme DNoteProbe -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

正式 App 和后端的命令在工程搭起来后补上。

## 文档地图

| 想知道 | 看 |
|---|---|
| 为什么做、总体架构、验收标准、假设结论 | `docs/backend-design.md` |
| 哪个功能在哪个里程碑 | `docs/features.md` |
| 为什么选这个技术或方案 | `docs/adr/` |
| 蓝牙协议、命令字、帧格式 | `docs/PROTOCOL.md` |
| 官方 App 有哪些功能和接口 | `docs/official-app-analysis.md` |
| 设备背景、逆向方法 | `docs/HANDOFF.md` |
| 数据模型、接口契约、状态机 | `docs/prd.md`（#27，待写） |
| 测试策略 | `docs/test-spec.md`（#28，待写） |
| 当前进度 | GitHub milestone 与 issue |
