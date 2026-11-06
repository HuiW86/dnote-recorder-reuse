# 交接文档

本文件面向后续接手本项目的 agent 或开发者，提供足以独立继续工作的完整上下文。阅读顺序建议：本文件 → `docs/PROTOCOL.md` → `client/` 源码。

---

## 1. 背景

### 1.1 设备

- 产品：追觅 D·NOTE AI 录音名片，型号 **DNOTE001B**
- 形态：信用卡大小（86×54×3.49mm），约 30g，Type-C，400mAh，30 小时续航
- 主控：瑞芯微（Rockchip）音频 MCU（USB 厂商号 0x2207；具体型号未拆机确认，疑似 RK2108/RK2118 系列）；另有独立蓝牙芯片承担 BLE
- 存储：板载 Flash，USB 可枚举为 FAT32（型号后缀 8G/64G 对应容量）
- 官方软件：App「DreameNote」（包名 `com.dnote.dreame`）+ 追觅云；转写/总结在云端

### 1.2 触发问题

用户持有该卡，**官方 App 无法使用**：登录需短信验证码，验证码已无法下发（服务方关停短信或后端）。账号与云端两条路都断，但硬件完好。

### 1.3 目标

复用硬件、自研软件。按能力深度分三层，本项目聚焦 **L2**：

| 层 | 目标 | 依赖 | 状态 |
|---|---|---|---|
| L1 | USB 当 U 盘读录音文件 | 设备 FAT32 存储 | 已确认可行（见 §4） |
| **L2** | **自研客户端，BLE 直连，功能全保留** | **BLE 协议** | **本项目，真机跑通 录音→列表→下载→解密（2026-11-05，见 §5）** |
| L3 | 刷自有固件，完全掌控 | OTA 目录 / 瑞芯微下载模式 | 未开始，见 §6 |

更上层的产品意图：该卡可作为用户「对话沉淀系统」的**随身离线采集端**（补手机/一体机覆盖不到的便携场景，数据自持）。

---

## 2. 关键结论（逆向所得）

1. **官方 App 是 Capacitor（JavaScript）应用**，BLE 协议以可读 JS 实现，带中文调试日志，已完整逆向。
2. **帧格式极简**：`[PID=0xA0][CMD][LEN][PAYLOAD]`，无校验和。命令集完整（设备信息、录音控制、文件列表/下载/删除、USB/WiFi/增益/降噪配置、绑定、加密、固件升级）。
3. **~~连接与读取不以绑定为门禁~~（真机证伪，见 §5.2）**：App 侧确实吞掉了 `bondDevice` 的错误，但**设备固件侧**有门禁——未配对时只开放查询类与简单设置命令，录音（0x51 回 `{"name":"NULL"}`）、文件列表（0x90 无响应）、格式化（0x94 回 `0x00`）均被拒。离线配对（设置密钥 + 本地 bondId + 重连）后全部可用。
4. **bondId 来自云端**（`postRecorderActive` 返回 `code` 的前 16 字节），但设备不校验其来源：本地随机 16 字节即可完成绑定，离线可行。
5. **加密可离线破解**：若设备启用 ChaCha20，密钥 = `HMAC-SHA256(DEVICE_KEY_SECRET, 序列号)`，`DEVICE_KEY_SECRET` 为 App 硬编码 32 字节常量（已提取，见 `client/dnote_protocol.py`）。
6. **音频格式**：裸 Opus 帧，16kHz / 单声道 / 20ms / **定长 40 字节/帧**；封装为标准 OGG 即可播放。
7. **额外发现 — WiFi 高速通道**：设备可开热点 `FastUpload`（`192.168.88.1:6718` TCP），大文件回传远快于 BLE（~1MB/s）。本项目未实现，列为扩展项。

完整细节见 `docs/PROTOCOL.md`。

---

## 3. 逆向方法（可复现）

### 3.0 APK 来源

- 官方安卓分发页（App 内「软件下载」指向此处）：
  `https://a.122.city/app/installSuccess/6a1ff640b2eb467f6f1dfb18?lang=en&shortcutUrl=a52uej3b`
- App 代码内硬编码的下载直链常量：`ANDROID_DOWNLOAD_URL = https://fir.xcxwo.com/a52uej3b`
  （`fir.xcxwo.com` 为 fir.im 式的应用分发平台；短码 `a52uej3b` 与上面分发页的 `shortcutUrl` 一致，可互相印证）
- 分析所用样本：`app-release.apk`，`com.dnote.dreame`，约 50MB，Capacitor 应用。
- 注：上述为第三方分发地址，链接含时效性 token，可能失效；失效后从官网 `dreamenote.cn/app` 重新获取。请核对包名 `com.dnote.dreame` 以确认是同一 App。
- 2026-11-05 重新获取（脚本化，无需手机）：分发页是模板，元数据接口 `GET https://download.appmeta.cn/a52uej3b`（返回 app id、`token`、`master.id`），再拼 `https://download.appmeta.cn/apps/<app.id>/install?short=a52uej3b&download_token=<token>&release_id=<master.id>` 直接下载。
  - 版本 **1.0.11（build 45）**，52,567,760 字节，sha256 `53ec0e4af8e825138622a0c83aea307118aa7c3736748807965acdccb148f9f9`
  - 主 bundle `assets/public/assets/index-Bh9iBsYd.js`；`DEVICE_KEY_SECRET` 与 `client/dnote_protocol.py` 一致
  - APK 内附固件 `assets/public/assets/Firmware-DVJaG6Rm.lz`（~2MB），L3 线索，未分析
  - APK 本身不入库（版权），按上述方法随时可重取

### 3.1 步骤

1. 取得 APK（`com.dnote.dreame`，`app-release.apk`，~50MB）。
2. `unzip` 解包，确认为 Capacitor 应用（`assets/capacitor.config.json`、`assets/public/`）。
3. BLE 协议在 `assets/public/assets/index-*.js`（主 bundle）。用 `js-beautify` 美化后检索：
   - UUID 常量：`SERVICE_UUID` / `WRITE_UUID` / `NOTIFY_UUID`
   - 命令构造：`buildFrame` 及其调用（`queryFileList`、`requestFileData`、`bondDevice`、`setChaCha20Key` 等）
   - 下载状态机：`DeviceFileTransferService`
   - 解密：`decryptAudioFile`、`deriveDeviceKey`、`DEVICE_KEY_SECRET`
   - 音频：`splitOpusFrames`、`OggOpusEncoder`、`decodeDeviceAudio`
4. 绑定流程在 `assets/public/assets/DeviceScan-*.js`。

---

## 4. L1 现场确认记录（USB 路径）

- `/dev/diskN` 外部物理磁盘，容量与型号相符
- 文件系统为标准 FAT32（`mkfs.fat` 创建，无分区表的「超级软盘」布局），**未加密**
- 目录结构：`/sdcard/record/`（录音目录，现场为空）、`/sdcard/Ota/`（固件投放目录，现场为空）
- USB 仅全速（12 Mb/s，约 1MB/s）
- macOS 新系统 `mount -t msdos` 因内核扩展签名失效而失败，改用 `diskutil mount readOnly diskN` 可挂载
- 重要：设备按状态决定是否开放 USB 存储；录音/写盘期间会关闭 USB MSC

> 现场 record 目录为空，推测该卡几乎未被正常使用过（设备时钟未校准，目录时间戳停留在默认值）。

**2026-11-05 补充（macOS 27 / Darwin 27.0.0）**：BLE 发 `0x82 [1]` 打开 USB 存储后，设备以 `Re Disk`（VID 0x2207 / PID 0x0090，USB 全速）枚举成功，但 `IOUSBMassStorageDriver` 长期 busy、周期性复位，始终不出 `/dev/diskN`；经扩展坞或直插机身表现相同。同一张卡在 Windows 上可正常读取（`record` 目录为空）。判断为该固件与新版 macOS 存储驱动的兼容问题，L1 在新 macOS 上不可用，需 Windows 或旧版 macOS。

---

## 5. 现状与下一步（最重要）

### 5.1 已完成

- BLE 协议完整逆向 → `docs/PROTOCOL.md`
- 离线客户端编码完成 → `client/`
- 真机联调通过（见 §5.2）
- 离线可验证项已通过：
  - ChaCha20 纯 Python 实现与 `cryptography` 库比对一致
  - 帧编解码、JSON 解析、密钥派生单测通过
  - OGG 封装经 `ffprobe` 确认为合法 Opus/OGG 流（单声道）

### 5.2 真机联调结果（2026-11-05，Mac + bleak，固件 v1.50）

**全链路已跑通**：配对 → `record` → `list` → `pull`，得到 `20261105203844.opus`（22,060B，BLE 下载约 1s）→ 解密 → 550 帧 / 11.0s 的 OGG，`ffprobe` 识别为 opus/48kHz/mono，ffmpeg 无错解码，mean −23.9dB / max −8.5dB（有真实声音）。

设备状态演进与关键现象：

| 阶段 | 现象 |
|---|---|
| 初始（未配对） | `scan`/`info`/`status`/`0x87 校时`/`0x82 USB 开关` 正常；`0x51 录音` 回 `{"name":"NULL"}` 且 `rec` 始终 0；`0x90 列表` 无任何响应；`0x94 格式化` 回 `0x00`（失败）；按键录音亦未产生文件 |
| 同一连接内依次 `0xA2 设置密钥(enable, HMAC(secret, sn))` → `0xA1`/`0xA3` 确认 → `0xA0 绑定(随机 16B)` | 均回 `0x01`，`isBonded: True`；**但同一连接内录音仍回 NULL** |
| 断开后重新连接 | `0x90` 开始正常回复（空列表也会回 `{"end":1}`）；`0x51` 回 `{"name":"<YYYYMMDDHHmmss>.opus"}`，`0x56` 中 `rec:1`、`size` 递增 |

**离线配对流程（替代 App 的绑定，已验证可用）**：

1. 连接，`0x80` 取 `sn`；`0x87` 校时
2. `0xA2`：`[1] + HMAC-SHA256(DEVICE_KEY_SECRET, sn)` → 期望回 `0x01`
3. `0xA0`：`[1] + 本地生成的 16 字节 bondId` → 期望回 `0x01`；**bondId 需持久保存**（解绑/多端识别用）
4. **断开并重新连接**，之后录音与文件操作可用

> 待复核：第 4 步"重连后生效"是按时间线推断的。断开发生在发送 `0x54 [1]`（实时录音）之后约 8s，不能完全排除 0x54 或断开本身才是触发条件。做 App 前应在"解绑 → 重新配对 → 仅重连"路径上复现一次。

已确认的字段/参数（原 5.3 的不确定点）：

- `0x80` 字段：`sn, v, time, rec, recmode, usb, bat, df, total_df, bt, btaddr, wifiap`（`df`/`total_df` 单位疑为 MB，8G 卡 total 7671）
- `0x81` 字段：`ms, led, motor, nc, wav, vad, gain, nn, autoff`
- `0x56` 字段：`name, size, recd, rec, upload`；`rec` 0=空闲 1/2=录音中 3=结束（取自 App 逻辑，1 已实测）
- 文件名：`YYYYMMDDHHmmss.opus`（取设备时钟，故需先校时）
- 下载 `cmd=1` 可用；Opus 定长 40 字节/帧成立；开启加密后文件以 `encryt` 开头，现有解密逻辑一次通过
- 设置类命令回 `[0x01]` 表示成功、`[0x00]` 表示失败
- 设备会主动推送 `0x80`（如按键切换后 `recmode` 1→0）

### 5.3 未解决 / 待核实

- **配对生效条件**：见上方"待复核"。
- **`0x54` 实时录音**：发 `[1]` 后无任何响应，约 8s 后 BLE 断开；App 中 `0x54` 响应会再次调用 `startRealTimeRecording`，实时音频走 `0x68` 通知。未研究。
- **`0x94` 格式化**：未配对时回 `0x00`；配对后未重试。
- **按键交互**：短按/长按语义未知；观察到按键会改变 `recmode`。
- **扫描时长**：默认 8s 偶发扫不到（广播间隔较长），15s 稳定。
- **macOS USB 存储**：见 §4 补充。

### 5.4 当前设备状态（这张卡）

- 已绑定，bondId `169b4119193cb65d7e2dac1baef12c1c`；ChaCha20 加密已开启（之后的录音均为加密文件）
- 设备上有 1 个测试录音 `20261105203844.opus`（未删除）
- 撤销：`0xA0 [0]` 解绑；`0xA2 [0] + key` 关闭加密

### 5.5 后续方向（优先级由高到低）

产品目标已明确为：**做一个替代官方 App 的应用**（官方 App 无法登录，硬件对用户等同变砖）。

1. 客户端加 `pair` 命令（固化 §5.2 配对流程 + 持久化 bondId），并复核"重连生效"；`scan` 默认时长调到 15s。
2. 确定 App 技术路线（手机原生 / 小程序 / 桌面 / Web Bluetooth），协议层 `dnote_protocol.py` 作为移植基准。
3. 研究 `0x54` 实时录音（App 的核心体验之一）。
4. 实现 WiFi 高速通道（§2.7），用于批量导出。
5. 接入「对话沉淀系统」采集端：pull → 转写管线。
6. （可选，高风险）L3：研究 APK 内置固件与 `Ota` 目录格式，评估刷自有固件可行性。

---

## 6. L3 预研线索（未开始）

- 刷写入口两条：① 设备 `/sdcard/Ota/` 目录投放固件包，重启自动刷（需确认有无签名校验）；② 瑞芯微 USB 下载模式（Maskrom/Loader）+ `rkdeveloptool`，可整片读写 Flash。
- 风险：芯片若开读保护/安全启动，或 SDK 不公开，难以推进；操作不当会变砖。
- 价值：完全掌控（实时推流、多通道原始音频、自定义交互）。仅在 L2 不满足需求时再考虑。

---

## 7. 法律与边界

- 仅用于复用本人持有设备、取回本人录音；逆向对象为自有设备通信协议，用于互操作。
- 不得用于他人设备；不得分发受版权保护的固件或 App 资源。
- `DEVICE_KEY_SECRET` 等常量来自对自有设备 App 的分析，随本仓库仅为实现互操作，不含任何第三方录音数据。

---

## 8. 工作目录约定

- `client/` 为可运行代码，`client/dnote_protocol.py` 为纯协议层（无蓝牙依赖，便于单测与跨栈移植）。
- 新增能力优先扩展 `dnote_protocol.py`（协议）与 `dnote.py`（交互），保持协议层与传输层分离。
