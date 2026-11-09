# PR #46 合并前冒烟：同步后删除、本地删除保护、诊断导出 — 2026-11-09

PR #46 的最后一批修复改到了删除卡上文件的路径（`4bd46f5`），只有模拟卡测试。合并前在真卡上确认删除路径没有回归、本地删除过的录音不会再从卡上删除，并顺带验证 P08、P09 导出诊断信息。

不在本次范围：
- 唤醒提示：`03c-sleep-long-press-wake.log` 已有证据。
- 换卡（`4bd46f5` 第二部分、`5d1cfaa`）：只有 1 张卡，测不了，等 #8 补齐多卡后在 #42 补测。
- 深色模式、动态字体、VoiceOver、断网：移到 #42。

## 环境

| 项 | 值 |
|---|---|
| 手机 | iPhone 12（iPhone13,2），iOS 待填；poki-mcp 操作屏幕 |
| App | Debug 构建，提交 待填（`feat/41-pages-batch1`） |
| 卡 | 固件 v1.50；sn SHA-256 前 8 位 待填；电量 待填 |

## 步骤

0. **备份**（`test-spec.md` §4）：P07「断开连接」，Mac 上 `cd client && source .venv/bin/activate && python dnote.py pull --out /tmp/v46-backup`，记下文件数和每个文件的 sha256（音频不入库）。
1. **准备**：P07「同步后删除」保持关闭。在 P05 录两段约 10 s 的录音 A、B，等首页显示「全部录音已存入手机」。
2. **本地删除**：在 App 里删除 A（只删手机上的）。
3. **打开同步后删除**：P07 打开「同步后删除」，回首页下拉同步，等同步结束。
4. **核对卡上文件**：P07「断开连接」，`python dnote.py list`。
5. **P08、P09**：首页点卡名旁的箭头打开 P08，确认列出这张卡和「上次连接」时间，点「添加录音卡」进到扫描页再返回；P09「导出诊断信息」存到「文件」，用 devicectl 取回。
6. **取日志**：

```sh
xcrun devicectl device copy from --device 00008101-001828D02686001E \
  --domain-type appDataContainer --domain-identifier com.huiw86.revive \
  --source Documents/card-debug.log --destination evidence/v46-merge-smoke/card-debug.log
```

## 判据（测试前写定）

| 编号 | 判据 |
|---|---|
| S1 | 第 3 步后日志里有 B 的 `tx 91`，且出现在 B 的录音提交之后；第 4 步卡上没有 B |
| S2 | 第 3 步后日志里**没有** A 的 `tx 91`；第 4 步卡上仍有 A，大小与备份一致 |
| S3 | 第 3 步后 App 里 B 能播放；A 没有重新出现在列表里 |
| S4 | P08 列出这张卡和上次连接时间；「添加录音卡」能进扫描页并返回，不影响当前连接 |
| S5 | 诊断文件里原始 `sn`、完整 `btaddr`、bondId 的命中数都是 0（用 client 从卡上读原始值检索，只输出命中数） |
| S6 | 全程日志没有 `tx 93`、`tx 94`、`tx B0`、`tx B1` |

## 结果

待测。

## 结论

待测。
