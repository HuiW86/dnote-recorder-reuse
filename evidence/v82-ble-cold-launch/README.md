# #82：冷启动自动重连真机复验

- 设备：iPhone 16，iOS 27.0；已配对的 D·NOTE 录音卡，固件 1.50（同一台测试卡）。
- 旧版：TestFlight 0.1.0 (5)，首页显示 37 条录音。
- 修复构建：0.1.0 (6)，归档源码为 `0053682b8080243556bcba10411e73139cbc55f5`，基于 `86b898e`。之后的文档提交不影响受测二进制。
- 同一归档已上传 TestFlight 内测。等待 TestFlight 下发期间，从该归档导出设备签名包，用 `xcrun devicectl device install app --device <iPhone-UDID> <Revive.app>` 覆盖安装；设备读回已装 (6)。签名包 IPA SHA-256：`c046f3f80b147b51865f719b26445ba1a0a645bfa1dfce70e33b244a7951a9a3`。
- 本机检查：`swift test --disable-xctest` 共 252 项通过，含冷启动等蓝牙就绪后自动连卡、蓝牙恢复后重连和手动断开后下拉重连；M1 静态规则及主题检查通过；`xcodebuild archive` 和 TestFlight 上传成功。

## 步骤和判据

1. 原地覆盖更新。用 `xcrun devicectl device info apps --device <iPhone-UDID>` 核对已安装版本，再核对原有配对和录音条数。
2. 使用 `xcrun devicectl device process launch --device <iPhone-UDID> --terminate-existing com.huiw86.revive` 发起冷启动。蓝牙开启、卡可响应时，应能自动连上；App 界面状态与日志均须对应。
3. 核对自动同步已完成。若卡有未同步录音，下载数量须与手机录音列表增量相符；第二次冷启动时列表不应重复增加。
4. 用 `devicectl device copy from` 读取 `Library/Application Support/diagnostics.log`，只留带时间的连接和同步事件。以下日志时区为 UTC+08:00，和 Mac 上的 PST 有 16 小时时差。

## 旧版基线（设备日志节选）

```text
2026-11-18 10:21:40.294 +08:00 [app] session started, 1 paired, link idle
2026-11-18 10:21:40.346 +08:00 [link] connect when seen, link idle
2026-11-18 10:21:40.346 +08:00 [home] reconnect failed: bluetoothUnsupported
2026-11-18 10:32:16.776 +08:00 [app] session started, 1 paired, link idle
2026-11-18 10:32:16.816 +08:00 [link] connect when seen, link idle
2026-11-18 10:32:16.817 +08:00 [home] reconnect failed: bluetoothUnsupported
```

## 修复版真机结果（2026-11-17 PST）

- 冷启动 1：会话仍有 1 张已配对卡。日志先记录 `initializing`，约 273 ms 后进入 `idle`，此时发起连接，约 0.95 秒连上。随后从卡下载 2 条未同步录音，首页由 37 条增至 39 条，显示「全部录音已存入手机」。
- 冷启动 2：终止进程再启动，约 0.18 秒连上；首页显示录音卡电量 40%，仍有 39 条录音，同步候选 0 条。
- 两次都未打开切换录音卡面板、重新配对或手动刷新。没有测试冷启动时卡休眠、锁屏后同步或撤回权限；这也不是 #42 的全量验收。手机运行的是同归档的设备签名包，TestFlight 下发与安装未验证。

```text
2026-11-18 10:45:09.361 +08:00 [app] session started, 1 paired, link initializing
2026-11-18 10:45:09.634 +08:00 [link] state idle
2026-11-18 10:45:09.634 +08:00 [link] connect when seen, link idle
2026-11-18 10:45:09.650 +08:00 [link] state connecting
2026-11-18 10:45:10.311 +08:00 [link] state connected
2026-11-18 10:45:10.492 +08:00 [sync] requested connection, queued false
2026-11-18 10:45:11.220 +08:00 [sync] downloading, 2 pending
2026-11-18 10:45:14.766 +08:00 [sync] completed, listed 30, candidates 2, retryable 0
2026-11-18 10:45:14.767 +08:00 [sync] idle after 3.5 s, failures retryable 0 undecryptable 0
2026-11-18 10:45:29.988 +08:00 [app] session started, 1 paired, link initializing
2026-11-18 10:45:30.113 +08:00 [link] state connecting
2026-11-18 10:45:30.171 +08:00 [link] state connected
2026-11-18 10:45:30.354 +08:00 [sync] requested connection, queued false
2026-11-18 10:45:30.966 +08:00 [sync] completed, listed 30, candidates 0, retryable 0
```
