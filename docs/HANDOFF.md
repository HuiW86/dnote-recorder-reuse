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
| **L2** | **自研客户端，BLE 直连，功能全保留** | **BLE 协议** | **本项目，编码完成，待真机联调** |
| L3 | 刷自有固件，完全掌控 | OTA 目录 / 瑞芯微下载模式 | 未开始，见 §6 |

更上层的产品意图：该卡可作为用户「对话沉淀系统」的**随身离线采集端**（补手机/一体机覆盖不到的便携场景，数据自持）。

---

## 2. 关键结论（逆向所得）

1. **官方 App 是 Capacitor（JavaScript）应用**，BLE 协议以可读 JS 实现，带中文调试日志，已完整逆向。
2. **帧格式极简**：`[PID=0xA0][CMD][LEN][PAYLOAD]`，无校验和。命令集完整（设备信息、录音控制、文件列表/下载/删除、USB/WiFi/增益/降噪配置、绑定、加密、固件升级）。
3. **连接与读取不以绑定为门禁**：App 中 `bondDevice` 调用被 `.catch(()=>{})` 吞错；绑定仅用于云账号登记与会员能力。
4. **bondId 来自云端**（`postRecorderActive` 返回 `code` 的前 16 字节），离线场景不需要。
5. **加密可离线破解**：若设备启用 ChaCha20，密钥 = `HMAC-SHA256(DEVICE_KEY_SECRET, 序列号)`，`DEVICE_KEY_SECRET` 为 App 硬编码 32 字节常量（已提取，见 `client/dnote_protocol.py`）。
6. **音频格式**：裸 Opus 帧，16kHz / 单声道 / 20ms / **定长 40 字节/帧**；封装为标准 OGG 即可播放。
7. **额外发现 — WiFi 高速通道**：设备可开热点 `FastUpload`（`192.168.88.1:6718` TCP），大文件回传远快于 BLE（BLE 实测约 23.6 KB/s，见 §5.3）。本项目未实现，列为扩展项。

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

---

## 5. 现状与下一步（最重要）

### 5.1 已完成

- BLE 协议完整逆向 → `docs/PROTOCOL.md`
- 离线客户端编码完成 → `client/`
- 离线可验证项已通过：
  - ChaCha20 纯 Python 实现与 `cryptography` 库比对一致
  - 帧编解码、JSON 解析、密钥派生单测通过
  - OGG 封装经 `ffprobe` 确认为合法 Opus/OGG 流（单声道）

### 5.2 待真机联调（阻塞项，需要有蓝牙的电脑连卡）

按顺序验证，每步是下一步的前提：

1. **连接通道**：`python dnote.py scan` 能识别；`info` 能读到设备信息 JSON。
   - 需确认字段名：序列号字段是否为 `sn`、蓝牙地址是否为 `btaddr`、是否有 `recmode`。
   - 需确认加密是否默认开启（`status` 看绑定/加密状态）。
2. **离线录音**：`record --seconds 20` 后 `list` 是否出现文件 —— 验证**不绑定也能录音**（L2 成立的关键）。
3. **下载全链路**：`pull` 得到的 `.ogg` 能否播放 —— 验证下载、解密（若加密）、封装。

### 5.3 已知不确定点 / 待核实

- `info` 返回的确切字段名（代码按 `sn`/`btaddr`/`bt`/`recmode` 假设，真机可能不同；`client/dnote.py` 的 `cmd_pull` 取 `sn` 用于解密，若字段名不符需改）。
- 文件列表 `name` 的扩展名与命名规则（影响 `pull` 输出命名；现为去扩展名加 `.ogg`）。
- `requestFileData` 的 `cmd` 参数语义：App 启动下载用 `cmd=1`，其余值（0/2…）语义未验证。
- Opus 帧是否恒为 40 字节：源码默认值 40，但 `splitOpusFrames` 第二参数可调；若真机帧长不同，解出的音频会异常，需据实调整。
- ~~实时录音能否走通~~（已核实，#4）：`0x51 [1]` 即启动实时推流 `0x68`（5 字节头 + 明文 Opus），`0x54` 单独无效；详见 `PROTOCOL.md` §4.3、§5.1，证据 `evidence/v1-live/`。
- 设备序列号与解密派生料的关系：App 中密钥派生有两处输入（绑定时用序列号；文件头带 18 字节派生料）。`decrypt_audio_file` 以文件头派生料为准，已自洽；但「设备侧启用加密」用的是序列号派生，二者是否一致需真机验证。
- ~~配对是否需要重连（H1）~~（已核实，#5）：`0xA0` 绑定/解绑立即生效，同一连接内 `0xA1` 即可查到；`dnote.py pair`/`unpair` 已实现，bondId 存 `client/.bond.json`。证据 `evidence/v3-pair/`。
- ~~按键录音能否被发现与下载（H5）~~（已核实，#5）：按键录的 `20261106040350.opus` 停止后出现在 `0x90` 列表，下载、解密、播放正常（7590 s，Opus 48 kHz 单声道）。录音进行中列表为空。
- ~~BLE 吞吐~~（已核实，#5）：约 23.6 KB/s（波动 ±0.4%），不是 1 MB/s；`download` 超时改为按文件大小计算。

### 5.4 后续方向（优先级由高到低）

1. 真机联调跑通 5.2，修正 5.3 的字段/参数。
2. 封装为带界面的桌面 App（或 Web Bluetooth 页面），降低使用门槛。
3. 实现 WiFi 高速通道（§2.7），用于批量导出。
4. 接入「对话沉淀系统」采集端：pull → 转写管线。
5. （可选，高风险）L3：研究 `Ota` 目录固件格式与签名，评估刷自有固件可行性。

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
