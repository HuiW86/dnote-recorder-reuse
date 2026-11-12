# V7 iOS 可行性原型证据（#7，H6）

## 环境

| 项 | 值 |
|---|---|
| 手机 | iPhone 12（iPhone13,2），iOS 27.2（24B119） |
| 录音卡 | DNOTE001B，固件 v1.50，sn `h7spab9m1novnz0415` |
| 原型 | `ios-prototype/`（SwiftUI + CoreBluetooth，XcodeGen），Xcode 27.0，部署目标 iOS 17 |
| 日期 | 2026-11-06（日志时间戳为手机本地时间） |

## 文件

- `probe.log`：手机端原始日志，用 `xcrun devicectl device copy from --domain-type appDataContainer --domain-identifier com.huiw86.dnoteprobe --source Documents/probe.log` 拉取。每行带 `[fg]`/`[bg]`/`[lock]` 标签，表示当时 App 处于前台、后台或锁屏
- `unit-tests.log`：模拟器单元测试（ChaCha20 RFC 8439 向量；解密和 Ogg 封装与 Python 参考实现逐字节一致，夹具由 `ios-prototype/tools/make_fixtures.py` 生成）。2026-11-12 注：该脚本已删除，同样的三个夹具改由 `app/ReviveKit/scripts/make_fixtures.py` 生成，字节不变（#58）
- `opuscheck.swift`、`opus-decoder-macos.log`：Apple 自带 Opus 解码器解卡的真实码流（450 帧 → 9.0 s，峰值 0.70）

## 结论

| 验收项 | 结果 | 判据与依据 |
|---|---|---|
| 扫描 → 配对 → 列表 → 蓝牙下载 → 解密 → 播放 | **通过** | 配对写入后回读 bondId 一致（`pair: verify ... [PASS]`）；`20261106034454.opus` 生成的 `.ogg` SHA256 `8309e76d…` 与 Mac 备份相同；用户确认能听到声音 |
| 蓝牙吞吐 | 25.55 KB/s | 15,180,060 B / 580.3 s；`.ogg` SHA256 `c45eebf1…` 与 #5 Mac 三次下载相同。Mac 基线 23.6 KB/s |
| 后台蓝牙：前台、后台、锁屏各 ≥ 3 次 | **通过** | 前台 3 次、后台 3 次、锁屏 4 次，加锁屏静置 4 分 13 秒后再录 1 次，共 11 次全部发现新文件（`auto-list: new files`），从停止录音到发现约 1.3–1.5 s；全程连接未断开；后台和锁屏时用户看到了本地通知 |
| 连上 `FastUpload` 热点 | **部分成立** | 见下文 |
| 机型与 iOS 版本 | 已记录 | 见"环境" |

### 后台蓝牙的工作方式与边界

- 卡的广播**不含服务 UUID**，按 `FE98` 过滤的扫描一次也没命中（`scan: start filter=FE98`，没有 `found`）。iOS 后台扫描必须按服务过滤，所以**断开后靠后台扫描重新发现卡不可行**。
- 可行的做法是**保持连接**，靠卡的主动推送唤醒 App：按键开始录音推送 `0x54 {name}`，停止推送 `0x56 rec:0` 和 `0x55`，另有约每 4 分钟一次的 `0x80`。App 收到 `0x56 rec:0` 后自动拉取文件列表。
- iOS 会在 App 重启后保留这条连接（`restored state peripherals=[...:2]`），App 用 `retrieveConnectedPeripherals` 接手即可。
- 未覆盖：用户在多任务界面划掉 App（iOS 不会再唤醒）；卡走出范围后的待连重连（代码已有 `connectWhenSeen`，未实测）；数小时级的长时间保持；后台自动**下载**（本次只验证"发现"）。

### 热点（`FastUpload`）

流程按官方 JS（`FastTransferWifi`）：`0x88 {ap:1, ssid:"FastUpload", psk}` → 等待 → `NEHotspotConfiguration` 加入 → TCP `192.168.88.1:6718`（最多 6 次）→ `0x88 {ap:0}`。

| 轮次 | 变量 | 次数 | 结果 |
|---|---|---|---|
| 1 | 随机密码，等 3 s，`joinOnce=true` | 3 | 2 次 TCP 连上（第 4、第 2 次尝试）；1 次失败 |
| 2–3 | 同上；先加失败原因日志，再加"Wi-Fi 地址须为 192.168.88.x，否则重新加入（最多 3 次）" | 2 | 失败 |
| 4 | 先 `ap=0` 再 `ap=1`，等 6 s | 3 | 失败 |
| 5 | 固定密码，热点先稳定 10 s | 3 | 失败 |
| 6 | 固定密码 + `joinOnce=false` | 3 | 失败 |
| 手动 | App 保持热点开启，用户在系统设置里手动加入 | 1 | **能看到 `FastUpload`，手动加入成功** |

合计自动加入 14 轮，成功 2 轮。失败时的现象一致：用户看到"无法加入网络 FastUpload"，`apply()` 却没有报错，Wi-Fi 地址仍在家庭网段 `192.168.31.x`；卡在 `0x80` 中报告 `wifiap:1`。

判断：卡的热点正常，iOS 能连上；问题出在 App 通过 `NEHotspotConfiguration` 自动加入不稳定，原因未定位。官方 App 在 iOS 上也走这个接口（`CapacitorWifi.connect`），所以这条路不是死路，但正式 App 采用前需要专门排查。TCP 层快传协议属于 #6，本次未测。

## 对 H6 的结论

- 配对与蓝牙下载：成立，项目无需整体重新评估。
- 后台蓝牙：成立（以保持连接为前提），不需要回退到"打开 App 时同步"。
- 热点：部分成立，自动加入可靠性待查，影响 #6 和 #13 在 iOS 上的方案。

## 复现

```sh
cd ios-prototype
xcodegen generate
xcodebuild test -project DNoteProbe.xcodeproj -scheme DNoteProbe -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
xcodebuild -project DNoteProbe.xcodeproj -scheme DNoteProbe -destination 'id=<UDID>' -allowProvisioningUpdates build
```

真机签名需要 Xcode 已登录团队 `NY89JGE95Q` 的账号，并带热点配置（Hotspot Configuration）能力。
