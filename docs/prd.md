# 工程规格：数据模型、接口契约、状态机

**范围**　M1 完整（App 内部，无后端）；M2～M4 到模块级
**上游**　`backend-design.md`（架构与验收）、`features.md`（范围）、`PROTOCOL.md`（设备协议）、`adr/`（选型）
**下游**　`test-spec.md`（#28）、M1 开发子 issue
**日期**　2026-11-06（#27）

功能编号（A1、C1、X1 等）引用 `features.md`。标 **【待验证】** 的条目依赖尚未真机确认的设备行为，M1 开发时先验证再实现。

---

## 1. App 分层（M1）

```
界面（SwiftUI）
  │
  └─ AppModel ─────── 页面状态，不含视图；CardSession 持有设备会话，消费设备事件并驱动同步
        │
        ├─ CardService ──── 设备业务：配对、录音控制、设置、文件列表与下载
        │     ├─ CardLink ──── CoreBluetooth：扫描、连接、写、通知、断线恢复
        │     └─ CardProtocol ── 帧编解码、命令白名单、固件差异适配（CardLink 也依赖它）
        │
        ├─ SyncEngine ───── 设备上的文件 → 本地录音库，按 §4 状态机（只依赖 DeviceSource 和 Library，§2.6）
        │     └─ DeviceSource ── 与设备无关的接口 `SyncSource`；D·NOTE 卡由 CardService 里的 `CardSyncSource` 实现（ADR-010）
        │
        ├─ Library ──────── 本地数据库与音频文件（§5）
        │
        └─ Player ───────── 解密后的 OGG 播放；导出分享（Exporter）也在这个模块里（依赖 Library）
```

规则：

- **M1 各层不引用任何网络库**。M2 的同步与 AI 模块单独成层，只读写 Library，不被设备层调用（`CLAUDE.md` 硬规则 3）。
- 联网的模块目前有三个，都不在上图里，只由 AppModel 的相应页面和 App 目标引用，设备和离线模块不能引用（`scripts/check-m1-rules.sh`）：`Assistant`（用户自配 AI 服务，X11）、`LinkImport`（从播客链接下载音频，X12；只用 Foundation，不依赖其他模块，下载完由 AppModel 交给 Player 的 `AudioImporter` 和 Library 存入，来源记为 `import`，不改数据模型）和 `Account`（闻笺账号，K1；只用 Foundation，钥匙串在有 Security 的平台上用，不依赖其他模块；它的页面状态 `AccountModel` 也放在这个模块里，好在 Linux 上测，App 目标直接引用；2026-11-27 起 AppModel 的 `AccountAI` 也引用它，把闻笺账号这条路接到录音库上，§5.14）。
- 转写和纪要走哪条路（本机、你的 AI 服务、闻笺账号）的规则在 `AIRoute`（`product-spec.md` §7.3b）：只用 Foundation，不联网，不依赖其他模块，只给出决定（直接用、先确认、先登录、去设置、让用户选），由 AppModel 按当时的情况（`AISituation`）调用。
- 读写录音库给 AI 助手用的 `LibraryTools`（X19）和命令行 `revive` 只依赖 Library（`revive` 在 Mac 上另依赖 Player 转换音频），和 M1 模块一样不联网（`scripts/check-m1-rules.sh`）。`revive` 在另一个进程里打开 Mac 版的录音库（`AppDatabase.existing`，写锁最多等 5 秒），只新增录音，不改不删；库被更新的版本迁移过时只读（`isNewerThanThisBuild`）。
- 协议细节（命令字、帧格式、JSON 字段）只出现在 CardProtocol，上层只看到 Swift 类型。固件版本差异也在这一层处理。
- 协议层从 `ios-prototype/Sources/DNoteProtocol.swift` 起步，原型的单元测试和样本一并迁移。
- 代码位置：每层是 `app/ReviveKit/` 里的一个 Swift Package 目标，依赖方向在 `Package.swift` 里声明，以它为准；App 目标 `app/Revive/` 只负责界面（#36）。界面只和 AppModel 打交道，AppModel 直接依赖 CardLink、CardService、Library、SyncEngine、Player。

## 2. 设备层接口契约（M1）

接口定义是示意，非实现；命名在编码时可以调整，但能力和语义以本节为准。

### 2.1 CardLink：连接

| 能力 | 语义 |
|---|---|
| `scan()` → 发现流 | 按厂商数据公司 ID `0x22A3` 识别设备（`PROTOCOL.md` §2.2），解析广播得到固件版本、电量、SID |
| `connect(peripheral)` | 连接、发现服务 `6001`、订阅通知 `6003`；超时 10 s |
| `connectWhenSeen(peripheralId)` | 挂起连接：设备再次广播时由系统自动连上。断线后必须调用，因为 iOS 后台扫描发现不了这张卡（H6）。意外断开时由 CardLink 自动登记（#37） |
| `disconnect()` | 主动断开，不触发挂起连接 |
| `state` | `poweredOff / unauthorized / idle / connecting / connected / disconnected(reason)` |
| `write(frame)` / `notifications` | 带响应写；通知按到达顺序投递 |

需要开启 `bluetooth-central` 后台模式和状态恢复，与原型一致。

### 2.2 CardProtocol：命令白名单

协议层**只定义**以下命令，其余命令字在代码里不存在，上层无法发出（`CLAUDE.md` 硬规则 1）。

| 分组 | 命令 | 里程碑 |
|---|---|---|
| 查询 | `0x80` 设备信息、`0x81` 开关状态、`0x56` 录音状态、`0xA1` 绑定状态、`0xA3` 加密状态 | M1 |
| 设置 | `0x83` LED、`0x84` 马达、`0x85` 降噪、`0x8B` VAD、`0x8C` 增益、`0x8D` 降噪档位、`0x8F` 自动关机、`0x87` 校时 | M1 |
| 设置 | `0x82` USB 存储、`0x86` 蓝牙名、`0x8A` 保存 WAV、`0x95` 关机 | M4 |
| 录音 | `0x51` 开始（`[0]` 普通）、`0x50` 停止、`0x52` 暂停、`0x53` 继续 | M1 |
| 录音 | `0x51 [1]` 实时录音、`0x68` 实时音频 | M3 |
| 文件 | `0x90` 列表、`0x70` 下载、`0x91` 删除 | M1 |
| 配对 | `0xA0` 绑定 / 解绑、`0xA2` 设置密钥 | M1 |
| 快传 | `0x88` 热点开关 | M3 |

M3、M4 的命令在对应里程碑开工时才加入代码（#37 只定义了 M1 行）。

**永不定义**：`0x93` 恢复出厂、`0x94` 格式化、`0xB0`/`0xB1` 固件升级、`0x89` 卡 WiFi 直传（暂缓，#9）。
验证方法：代码审查 + 单元测试断言白名单之外的命令字无法构造帧（见 `test-spec.md`）。

### 2.3 CardService：业务操作

所有操作是 `async throws`，错误类型见 §6。请求和响应按命令字匹配；**同一命令字同时只允许一个请求在等待**，后发的排队。

| 操作 | 命令序列 | 返回 | 前提 |
|---|---|---|---|
| `info()` | `0x80` | `DeviceInfo`（sn、固件版本、录音状态、电量、剩余与总空间、蓝牙名、热点状态） | 已连接 |
| `switches()` | `0x81` | `DeviceSwitches`（字段见 `PROTOCOL.md` §4.1，#34 已验证） | 已连接 |
| `set(_ setting)` | `0x83`–`0x8F` 中对应一条，等待 1 字节 `0x01` 回包，再用 `0x81` 读回确认 | — | 已配对 |
| `syncTime()` | `0x87`，发送手机本地时间 | — | 已连接；每次连接后自动执行 |
| `pair()` | 见 §3 | `bondId` | 已连接 |
| `unpair()` | `0xA0 [0]` → `0xA1` 确认 | — | 已配对 |
| `startRecording()` | `0x51 [0]` | 文件名 `YYYYMMDDHHmmss.opus` | 已配对；未在录音 |
| `stopRecording()` | `0x50` | — | 录音中 |
| `pause()` / `resume()` | `0x52` / `0x53`，各回 1 字节 `0x01` | — | 录音中 / 已暂停；暂停段不写入文件（#34 已验证） |
| `recordingStatus()` | `0x56` | `{name, size, rec}`；`rec` 0 空闲 / 1 录音中 / 2 已暂停 | 已连接 |
| `listFiles()` | `0x90`，收到 `end=1` 结束 | `[CardFile(name, size)]` | 已连接（同步前的绑定检查见本节末）；**录音中卡会回空列表，不代表卡上没有文件**：列表为空时再查 `0x56`，录音中或已暂停则报 `cardBusyRecording`（#38） |
| `download(name, size, from)` | `0x70 {cmd:1, name, offset:from}`，拼接分片直到 EOF | 从 `from` 开始的原始文件字节 | 已连接（同上）；超时 = (size − from) ÷ 15 KB/s + 10 s；每个分片的 `offset` 必须等于已收到的位置（#34 证实是分片在文件中的绝对位置），跳号或总长不符报 `transferFailed` |
| `delete(name)` | `0x91 {name}` | — | 已连接；**只由 SyncEngine 调用**（§4），调用前已确认本机绑定 |

**设备主动推送**（转成事件流 `events`）：

| 推送 | 事件 | 用途 |
|---|---|---|
| `0x54 {name}` | `recordingStarted(name)` | 按键开始录音 |
| `0x56 {rec:0}`、`0x55` | `recordingStopped` | 触发 SyncEngine 刷新列表 |
| `0x80`（约每 4 分钟一次） | `deviceInfo(DeviceInfo)` | 更新电量与空间 |
| 断开 | `disconnected(reason)` | 进入挂起连接 |

**未配对的识别**：`0x51` 回 JSON `{"name":"NULL"}`（不是 ASCII `NULL`，卡不会开始录音），或 `0xA1` 显示卡没有绑定本机，都映射为 `notPaired` 错误，引导用户重新配对。未配对的卡照常响应 `0x90`、`0x70`、`0x91`（#38；只测过一张设过密钥的 v1.50 卡，从未设过密钥的卡未验证），所以同步任务每一轮开始前先用 `0xA1` 确认，卡已绑定到别的手机时不下载、不删除。

**下载断点续传**：`0x70` 的 `offset` 可以是任意值，跨连接续传结果与完整下载一致（#34 已验证）。下载中途断开时，保留已收到的字节，重连后从该位置续传。

### 2.4 固件版本适配（X1）

- 每次连接后读 `0x80` 的 `v`。已验证版本表：`["1.50"]`。
- 版本不在表内时：照常工作，按 v1.50 的行为处理；设备页显示「此固件版本未经验证，如遇问题请反馈」；日志记录版本号。不阻断使用。
- 发现某个版本的行为不同，在 CardProtocol 里按版本分支处理，并把该版本加入已验证表（#8）。

### 2.5 录音状态的合并规则（#53）

录音状态有三路来源：命令回包（`0x50`～`0x53`）、卡主动推送（`0x54`、`0x55`、`0x56 {rec:0}`、约每 4 分钟一次的 `0x80`）、App 自己读的 `0x56`。它们走同一条蓝牙链路，但在 App 里由不同的任务处理，先后不保证。`CardSession` 的每次状态变更都经过同一个入口（`apply`），按来源和到达顺序决定是否采用；顺序由一个只增不减的序号记录（`RecordingStateOrder`）。

**推进序号的事**：采用了一个状态；收到已连接卡的任何一个 `0x80`（与界面一致的也算）；开始一条录音命令；链路断开。

| 来源 | 是否采用 |
|---|---|
| 命令回包 | 直接采用。它在命令发出之后才到，比之前收到的都新 |
| 卡主动推送（`0x54` 开始、`0x55`/`0x56 {rec:0}` 停止） | 直接采用 |
| 连接后第一个 `0x80`（认出是哪张卡） | 直接采用其中的录音状态（状态码不认识时不采用） |
| 之后的 `0x80` | 与界面一致：不改状态，只推进序号。不一致：不直接采用，先读一次 `0x56`；命令进行中（等回包，或等超时后的 `0x56`）时什么都不做，由命令定 |
| `0x56` 的回答 | 发出读取后序号没有变：采用。序号变了（期间有推送、`0x80`、命令开始或断开）：不改状态；如果回答的状态和界面相同，并且是同一张卡、同一个录音文件，只取它的已录时长和文件名 |
| 不一致的 `0x80` 本身（兜底） | 只有在它触发的 `0x56` 没有回答，并且从收到这个 `0x80` 起序号没有变时才采用 |

- 用 `0x56` 或兜底的 `0x80` 发现录音已经停止（没有收到停止推送）时，主动触发一次同步，因为平时启动同步的是停止推送。
- 命令超时后的处理不变（`product-spec.md` §7.1 `requestTimeout`，#47）：不重发，读一次 `0x56`；读到的状态码不认识时，命令仍算未确认。
- DEBUG 设备调试页打开时，不一致的 `0x80` 不触发读取（调试页只发它自己的请求）。
- 以前分散在 `CardSession` 里的状态修订号、`0x80` 计数和「命令进行中」标记（#47，PR #51）都收进了这一套规则。PR #51 留下的一处：读 `0x56` 期间来了一个与界面一致的 `0x80`，原先仍会采用 `0x56` 的回答，现在按上表丢弃。

### 2.6 与设备无关的同步接口（ADR-010，2026-11-21）

`SyncEngine` 只通过 `DeviceSource` 模块里的 `SyncSource` 接口认识设备，不引用 CardProtocol、CardLink、CardService（`Package.swift` 的依赖和 `scripts/check-m1-rules.sh` 都管着这一条）。接入第二种设备时，同步状态机、录音库和硬规则 2（先存入再删）不用改，只需要再写一个 `SyncSource` 的实现。

| 能力 | 语义 | D·NOTE 卡的实现（`CardSyncSource`） |
|---|---|---|
| `isConnected`、`connectionId` | 是否连着；连着的是哪台设备。一次同步中途换了设备就停下 | 链路状态、peripheral id |
| `defaultDeviceName` | 录音库里还没起名的设备叫什么，不用品牌名（硬规则 5） | 「录音卡」 |
| `deviceInfo()` | 序列号（录音库里设备的键）、固件、电量、剩余和总空间 | 连接后读到的 `0x80`，没有时再读一次 |
| `isPairedWithThisPhone()` | 只从和这部手机配对的设备取文件 | `0xA1`（#38 E） |
| `isRecording()` | 录音中或暂停时不同步（H5） | `0x56` 的状态不是空闲 |
| `listFiles()` | 文件名加大小；录音中报 `busyRecording`，不返回没有意义的空列表 | `0x90`（#5） |
| `download(file, from:offset)` | 从某个字节开始下载，边收边交出；失败前交出的部分仍然有效 | `0x70`，按块校验偏移（#34） |
| `delete(name)` | 只在文件存入手机后调用；结果由下一次 `listFiles()` 确认 | `0x91`（#38 E） |
| `startDate(of:)` | 录音开始时间；不知道时由 SyncEngine 用同步时间 | 文件名 `YYYYMMDDHHmmss`（#59） |
| `audioConverter` | 把下载到的字节转成录音库存的 OGG Opus 和时长，在主线程以外运行 | 解密、按 40 字节一帧切分、封装 OGG（§4.2 第 2 步） |

- **错误**：实现把自己的错误换成 `SourceError`（`disconnected`、`notPaired`、`busyRecording`、`busy`、`fileNotFound`、`transferFailed`、`requestTimeout`、`unexpectedReply`、`other`）。SyncEngine 按它决定记什么失败码、要不要重试，失败码（§6，存在 `sync_item.last_error`）和以前一样。
- **事件**：设备自己的事件类型实现 `SourceEventConvertible`，只把「连上了」和「录音停了」交给 SyncEngine（§4.4）。D·NOTE 的 `CardEvent` 就是这样接入的。
- 录音库里沿用 `card_file_name`、`deleted_on_card` 这些名字，对别的设备同样指「设备上的文件」，不改表结构。

## 3. 配对状态机（A2）

```
未配对 ──连接──▶ 读取信息 ──▶ 查询绑定 ──▶ 校时 ──▶ 设置密钥 ──▶ [解绑] ──▶ 绑定 ──▶ 确认 ──▶ 已配对
                (0x80)      (0xA1)      (0x87)     (0xA2)    (0xA0 [0])  (0xA0)    (0xA1)
```

| 步骤 | 命令 | 失败处理 |
|---|---|---|
| 读取信息 | `0x80` 取 `sn`、`v` | 重试 1 次，仍失败则 `requestTimeout` |
| 查询绑定 | `0xA1` | 已绑定且 bondId 与 Keychain 中该 `sn` 的一致：已配对，直接返回，不发任何写命令。已绑定但 bondId 不同：见下方「卡已被其他手机绑定」，用户不确认则 `pairCancelled`，不发任何写命令 |
| 校时 | `0x87` | 失败不阻断，记日志 |
| 设置密钥 | `0xA2 [1] + HMAC-SHA256(DEVICE_KEY_SECRET, sn)` | v1.50 回 1 字节 `0x01`（#38 D）。回包不是 `0x01` 报 `unexpectedReply`，无回包则超时；两种情况都终止，不再发绑定命令，提示重试 |
| 解绑 | `0xA0 [0]`，回 `0x01` | 只在卡已被其他设备绑定且用户确认后发送 |
| 绑定 | `0xA0 [1] + bondId`；bondId 为本地随机生成的 16 字节 | 失败则终止，提示重试 |
| 确认 | `0xA1` 返回 `isBonded=1` 且 bondId 一致 | 不一致则 `pairVerifyFailed` |

- **先查询再写**（#38）：`0xA1` 查询放在所有写命令之前，才能做到「已配对的卡不重复绑定」（T-M1-11）和「不确认就不写」（T-M1-12）。Python 客户端的配对流程同样先查询（`evidence/v3-pair/04-pair-idempotent.log`）。
- **同一连接内生效**，不需要断开重连（H1 已否定）。
- **不发 `0x94`**：官方新卡绑定时会先格式化，我们不照搬。
- **卡已被其他手机或官方 App 绑定**（`0xA1` 返回 `isBonded=1`，bondId 不在本地）：提示「此卡已被其他设备绑定，重新绑定后原设备将无法管理此卡」，用户确认后先 `0xA0 [0]` 解绑，再走上面的绑定流程。绑定不影响卡上已有的录音；加密密钥由 `sn` 派生，与原绑定无关，旧录音仍能解开。
  已验证（#5，`evidence/v3-pair/` 00、r1～r3、05）：卡上原有其他 bondId 时，先解绑再绑定 3/3 成功，重新绑定后下载的文件与备份逐字节一致。不验证「不解绑直接覆盖」，因为不需要。
- bondId 存在 Keychain（`kSecAttrAccessibleAfterFirstUnlock`，后台也能读）；M2 起备份到账号（A4b）。

## 4. 同步状态机（C1）

这是 M1 最关键的部分：**卡是录音的唯一副本**，任何异常都不能导致丢失或重复（`CLAUDE.md` 硬规则 2；#11 验收）。

### 4.1 单个文件的状态

```
            ┌──────── 失败（可重试）────────┐
            ▼                               │
发现 ──▶ 下载中 ──▶ 已存入 ──▶ 待删除 ──▶ 已删除
                    │
                    └──（未开启「同步后删除」）── 保留在卡上
```

| 状态 | 含义 | 进入条件 | 落盘 |
|---|---|---|---|
| 发现 `discovered` | 列表里有，本地没有 | `listFiles` 结果与本地比对 | 写 SyncItem |
| 下载中 `downloading` | 正在传输 | 取到队首 | 字节写入临时文件 |
| 已存入 `stored` | 解密、封装 OGG、写库成功 | 见 §4.2 | Recording 与 SyncItem 在同一事务提交 |
| 待删除 `deletePending` | 已存入，且开启了「同步后删除」 | 已存入后立即 | — |
| 已删除 `deletedOnCard` | 卡上已删 | `0x91` 成功，且再次列表确认不在 | 记录删除时间 |
| 失败 `failed` | 可重试 | 下载、解密或写入出错 | 记录错误码和次数 |

### 4.2 「已存入」的判定

必须**全部**满足，才把状态推进到 `stored`：

1. 收到 EOF，且拼接后的长度等于列表里的 `size`；
2. 解密成功：文件头 24 字节校验通过（`PROTOCOL.md` §6.2）；未加密的文件跳过此步；
3. OGG 写入临时文件后 `fsync`，再原子移动到正式路径；
4. Recording 记录和 SyncItem 状态在**同一个数据库事务**里提交。

任一步失败：删除临时文件，状态记为 `failed`，卡上文件不动。

### 4.3 幂等与重试

- **唯一键**：`(设备 id, 卡上文件名, 文件大小)`。卡的时钟可能没校准（`HANDOFF.md` §4），文件名可能重复，所以带上大小。
- 列表比对时，唯一键已经是 `stored` 或之后状态的，跳过下载；如果开启了删除且还没删，直接进入 `deletePending`。
- `failed` 自动重试 3 次，间隔 5 s、30 s、120 s；之后等下一次触发（连接、录音停止、用户下拉刷新）。按错误区分（#39）：
  - `transferFailed`、`storeFailed`：计入重试次数，走上面的定时重试。
  - `disconnected`：不计次数，保留临时文件，等重连触发。
  - `phoneStorageFull`：本轮停止，等下一次触发。
  - `fileNotFound`：立即重新列表一次。
  - `decryptFailed`：同一个 App 构建内不再重试，原始字节已留在诊断目录。换了构建号（`CFBundleVersion`）后，App 启动时把这些项退回 `discovered`，下一轮按正常路径重新下载一次；仍然失败就记下新的构建号，等再下一个构建（#59）。失败原因可能是 App 自己的解密缺陷，升级修好后要能自动补回；卡上文件始终不动。
- 下载中途断开（App 仍在运行）：保留临时文件，重连后按其长度续传（§2.3）。
- App 被杀或崩溃后重启：`downloading` 一律回到 `discovered`，临时文件清掉，从头下载。临时文件可能没有完整落盘，不拿它续传。这是有意的（#59 复核后保留）：协议帧没有校验和（`PROTOCOL.md` §3），解密只校验文件头 24 字节（§4.2），续传接上一段没落盘完整的数据也会「成功」，得到错乱的音频，开了「同步后删除」时会丢掉唯一副本；代价是重启后长录音要重下，M3 的 WiFi 快传做完后会小很多。
- **在 App 里删除本地录音不会让它重新同步回来**：删除 Recording 和 OGG 文件，但 SyncItem 保持 `stored`，列表比对时照常跳过；也不向卡发任何命令（`test-spec.md` T-M1-32）。
- 删除只在 `stored` 之后发生。`0x91` 发出后连接断开、不确定是否删成功的，下次列表里不在就记为已删除，还在就重新删。
- 实现（#39）：下载中的字节写到 `tmp/<SyncItem id>.part`，OGG 先写到 `staging/` 并 `fsync`，再原子移动到 `audio/`。启动恢复（`RecordingLibrary.recoverAfterLaunch`）会清空 `tmp/` 和 `staging/`，并删掉 `audio/` 里没有 Recording 记录的 OGG：这是「写完 OGG、事务未提交时崩溃」留下的孤儿文件。系统不能直接播放 OGG 时，播放器把录音解码成 `decoded/<Recording id>.caf`；删除录音时一并删除，启动恢复时也会删掉没有 Recording 记录的副本和没解码完的 `.part` 文件（#40）。手机录音（X18，2026-11-20）录音中写到 `phone/phone-<开始时间毫秒>.caf`（16 kHz 单声道 16 位 PCM，App 被杀掉时文件仍可读到最后一个样本），停止后转成 M4A 存进 `audio/`，存好才删这个 CAF；存失败或录音中 App 被杀掉时 CAF 留着，下次打开标签栏时（`PhoneRecorder.recoverUnfinished`）按文件名里的开始时间存入，读不了的改名为 `.unreadable` 保留、不再重试，没有声音的删掉。启动恢复不碰 `phone/`：那里是这条录音唯一的一份。

### 4.4 触发时机

- 连接成功并完成校时后；
- 收到 `recordingStopped` 后等待 1 s；
- 用户下拉刷新。

录音中或已暂停（`rec` 不为 0）不触发，因为录音中列表为空（H5）；暂停时的列表行为未测，按录音中处理。同步过程中开始录音：当前文件下载完后暂停，等录音停止再继续。实现上，每下载一个文件前查一次 `0x56`（#39）。

CardService 的事件流只有一个消费者，SyncEngine 不直接订阅：由消费事件流的 AppModel（`CardSession`）把事件转给 `SyncEngine.handle(_:)`。

### 4.5 「同步后删除」默认关闭

卡有 8 GB，按约 2 KB/s 计可存约 1,000 小时录音，空间不紧张。默认保留卡上文件；用户在设置里打开后才删除。卡剩余空间低于 10% 时提示用户打开。

## 5. 本地数据模型（M1，并为 M2/M4 预留字段）

存储：SQLite（库选型在 M1 开工时定，候选 GRDB），音频文件放在 App 的 Application Support 目录 `audio/<recording id>.ogg`，不放 Documents（避免被「文件」App 直接改动）。

官方 App 本地有 7 个实体（`official-app-analysis.md` §1）：Record、Transcription、Summary、Folder、GenerateTask、RecordNote、GoldenMoment。M1 只建前两张表，其余在用到的里程碑再加。

### 5.1 `device`

| 字段 | 类型 | 说明 |
|---|---|---|
| `id` | UUID | 主键 |
| `peripheral_id` | TEXT | CoreBluetooth 标识，用于挂起连接 |
| `sn` | TEXT | 序列号，唯一 |
| `name` | TEXT | 显示名，默认取蓝牙名 |
| `firmware` | TEXT | 最近一次读到的版本 |
| `paired_at` | DATETIME | — |
| `last_seen_at` | DATETIME | 每次同步开始、连到卡时写入 |
| `last_synced_at` | DATETIME NULL | 一次同步完整跑完时写入（迁移 `v13`）；P08 显示「上次同步」，没有时退回 `last_seen_at` |
| `battery` / `free_mb` / `total_mb` | INTEGER | 最近一次 `0x80` 的值 |
| `remote_id` | TEXT NULL | M2 设备登记后的后端 id |

bondId 不进数据库，存 Keychain，键为 `sn`。

### 5.2 `recording`

| 字段 | 类型 | 说明 |
|---|---|---|
| `id` | UUID | 主键，也是音频文件名 |
| `device_id` | UUID NULL | 来源设备；导入的录音为空 |
| `source` | TEXT | `card` / `import`（M4）/ `realtime`（M3） |
| `card_file_name` | TEXT NULL | 卡上文件名 |
| `card_file_size` | INTEGER NULL | 卡上文件大小（加密时含文件头） |
| `started_at` | DATETIME | 从文件名解析，按设备时间；解析失败用同步时间。按同步时手机的当前时区解析：App 每次连接都用手机本地时间校时（`0x87`，不带时区），所以「上次连接后录的、手机换时区后才同步」的录音会偏差两地时差。只在跨时区出行时出现，有意不处理（#59） |
| `duration_ms` | INTEGER | 由 OGG 帧数计算；导入的文字文件为 0 |
| `audio_path` | TEXT | 相对路径；导入的文字文件为空字符串（E2，2026-11-20，见下） |
| `audio_sha256` | TEXT | OGG 文件的哈希；导入的文字文件为空字符串 |
| `title` | TEXT | 默认按开始时间生成 |
| `created_at` / `updated_at` | DATETIME | — |
| `folder_id` / `trashed_at` | — | M4 预留 |
| `starred_at` | DATETIME NULL | 标星的时间，空表示未标星（X21，迁移 `v7`，#89）；移入最近删除和恢复都不改它 |
| `title_source` | TEXT NULL | 谁定的标题（G1、X6，迁移 `v9`）：`user` 是用户改名，`ai` 是用户自配服务起的，空是默认的时间标题。AI 标题只替换默认标题和上一个 AI 标题，不替换用户的，除非用户点了「让 AI 重新起标题」。`v9` 之前改过名的行仍按标题形状算用户的 |
| `remote_id` / `remote_version` | — | M2/M4 预留 |

### 5.3 `sync_item`

| 字段 | 类型 | 说明 |
|---|---|---|
| `device_id` + `card_file_name` + `card_file_size` | — | 联合唯一（§4.3） |
| `state` | TEXT | §4.1 的状态 |
| `attempts` | INTEGER | 重试次数 |
| `last_error` | TEXT NULL | §6 的错误码 |
| `recording_id` | UUID NULL | 进入 `stored` 后关联 |
| `deleted_on_card_at` | DATETIME NULL | — |
| `failed_build` | TEXT NULL | 记下 `decryptFailed` 时的 App 构建号；其他错误为空。迁移 `v2` 新增，旧行为空，视为「其他构建」（§4.3，#59） |

迁移：用版本化的迁移脚本，只增不改；每次发版前在旧版本数据上跑一遍升级测试。

### 5.4 `recording_mark`（M1.5，迁移 `v3`）

录音中标的重点（`features.md` X7）。和 `sync_item` 一样按卡上的文件来认，所以录音还没同步、`recording` 行还不存在时就能记。

| 字段 | 类型 | 说明 |
|---|---|---|
| `id` | INTEGER PK | 自增 |
| `device_id` | UUID FK | — |
| `card_file_name` | TEXT | 录音中由卡上报的文件名 |
| `offset_ms` | INTEGER | 标记时卡上报的已录时长，暂停不影响 |
| `created_at` | DATETIME | — |

- 与录音的对应：`device_id` + `card_file_name`；超过录音时长的标记不显示。
- 2 秒内的重复标记丢弃。标记只存在手机上，不向卡发任何命令。

### 5.5 `discard_request`（M1.5，迁移 `v4`）

「不要这条」的请求（`features.md` X10），主键 `device_id` + `card_file_name`，另有 `created_at`。

- 请求本身不删任何东西。文件还没同步时照常下载、入库（`commitStored`），入库的同一个事务里把录音移入最近删除，并把 `sync_item` 置为 `deletePending`；已经入库的，在提出请求时做同样的事。
- 卡上的删除仍由 SyncEngine 在 `deletePending` 上执行，执行前照旧检查手机上有没有这条录音（硬规则 2）。「同步后删除」关着时，只删有请求的文件。
- 卡上确认删除后请求清除。撤销：删掉请求，录音从最近删除恢复，还没发出的卡上删除取消；已经从卡上删掉的不能恢复，手机上的那份保留。

### 5.6 `transcript`（M1.5，迁移 `v5`）

录音的文字稿（`features.md` X9，M2 的 F1 沿用）。主键 `recording_id`，随录音删除。

| 字段 | 类型 | 说明 |
|---|---|---|
| `recording_id` | UUID PK FK | — |
| `engine` | TEXT | 谁生成的；本机识别为 `on-device` |
| `language` | TEXT | 如 `zh-CN` |
| `segments` | TEXT（JSON） | 每句 `{startMs, text}`；润色后是润色过的文字 |
| `created_at` | DATETIME | — |
| `original_segments` | TEXT（JSON），可空 | 逐句润色（#75，迁移 `v12`）前的原文，句数和时间与 `segments` 相同；从没润色过为空。再次润色保留第一次的原文；「恢复原文」把它写回 `segments` 并清空 |

逐句润色把每句的文字（只发文字，不发音频）分批发给用户自配的 AI 服务，每批 40 句，回复的句数必须相同；对不上的那一批保持原文，全部对不上才报错。润色后改一句只改润色后的文字，恢复原文时这些修改一并丢弃。

本机转写在 `Transcription` 模块里，用系统语音识别并强制离线（`requiresOnDeviceRecognition`），不联网，纳入 `scripts/check-m1-rules.sh` 的检查。设置里的开关默认关闭，质量由 #67 测量后再决定是否默认打开。

### 5.7 M1.5 对已有字段的使用

- `recording.trashed_at`（`v1` 已预留）：非空表示在「最近删除」里，行和音频都保留；满 7 天后在 App 启动时彻底删除（D1b）。首页列表只列 `trashed_at` 为空的。
- `recording.title`：同步时写入 `yyyy-MM-dd HH:mm`；用户重命名后写入用户的标题（X6）。是否改过名按标题的形状判断，不另加字段。

### 5.8 `summary`（M2，迁移 `v6`）

录音的纪要（`features.md` G1），由用户自配的 AI 服务生成（X11，ADR-009）。主键 `recording_id`，随录音删除。

| 字段 | 类型 | 说明 |
|---|---|---|
| `recording_id` | UUID PK FK | — |
| `scene` | TEXT | 场景代号，如 `meeting`（`Assistant.RecordingScene`） |
| `title` / `summary` | TEXT | 标题、两到四句摘要 |
| `sections` | TEXT（JSON） | `[{heading, items}]`，栏目随场景 |
| `todos` | TEXT（JSON） | `[{text, done}]`，可在详情页勾选 |
| `tags` / `people` | TEXT（JSON） | 最多 6 个标签、12 个人名 |
| `outline` | TEXT（JSON） | 大纲：`[{title, points}]`，按录音里谈到的先后，最多 8 个话题、每个最多 6 条；思维导图用它画（迁移 `v10`，旧纪要为 `[]`） |
| `quotes` | TEXT（JSON） | 金句：文字稿里的原话，最多 5 句，去掉引号（迁移 `v10`，旧纪要为 `[]`） |
| `model` | TEXT | 生成它的模型名；关键词粗整理为 `keywords` |
| `created_at` | DATETIME | — |

生成时只把文字稿发给用户填的服务，录音音频不发送。联网代码只在 `Assistant` 模块里，`scripts/check-m1-rules.sh` 检查设备和离线模块不引用它。

### 5.9 `folder`（M4 D1c，迁移 `v8`）

录音所在的文件夹（`features.md` D1c）。一条录音最多在一个文件夹里，由 `recording.folder_id`（`v1` 起预留，不设外键）指向。删除文件夹只把其中录音的 `folder_id` 清空，录音保留。

| 字段 | 类型 | 说明 |
|---|---|---|
| `id` | UUID PK | — |
| `name` | TEXT | 去掉首尾空白，最多 40 字；空名字不建、不改 |
| `created_at` | DATETIME | — |

迁移编号：PR #88 原来用 `v7`，`v7` 已给星标（X21，#89）先用，文件夹顺延为 `v8`。

### 5.10 `correction`（纠错词库，迁移 `v11`，#75）

用户在文字稿里改正过的词，之后新转写的文字稿存入前自动替换（长的词优先）。只在本机。

| 字段 | 类型 | 说明 |
|---|---|---|
| `wrong` | TEXT PK | 识别错的词，2～12 字 |
| `right` | TEXT | 改正后的词，2～12 字 |
| `created_at` | DATETIME | — |

改一句时，去掉前后相同的部分得到改动的那段；不足 2 字时向后（没有就向前）补上未改的字，避免把单个字全局替换；纯插入、纯删除和整句改写不记。已有的文字稿不回头改。

### 5.11 `tag_rule`（标签管理，迁移 `v14`，D1c）

用户对标签做过的修改。标签本身只存在 `summary.tags` 里；重命名、合并、删除时先改掉所有纪要（含最近删除里的），再记一条规则，之后存入的纪要（新生成或重新生成）按规则处理，AI 不会把用户改掉的标签加回来。只在本机。

| 字段 | 类型 | 说明 |
|---|---|---|
| `tag` | TEXT PK | 被改掉的标签 |
| `replacement` | TEXT NULL | 改成的名字；空表示删除 |
| `created_at` | DATETIME | — |

改名时去掉首尾空白和 `#`，空名字或同名不改；改成已有的名字时同一条纪要里只留一个（合并）。规则会接力：A 改成 B 之后再把 B 改成 C，A 的规则跟着变成 C；删除 C 时指向 C 的规则都变成删除。改回一个曾被改掉的名字时，那个名字自己的规则作废。规则只套一次，不递归。

### 5.2.1 没有音频的录音（E2 文字文件，2026-11-20）

用户决定纯文字录音可以没有音频。从「文件」导入 `.txt`、`.md` 时插入一行 `recording`：`source = import`、`audio_path = ''`、`audio_sha256 = ''`、`duration_ms = 0`，标题取文件名；同一事务里插入 `transcript`：`engine = text`、`language = und`，每段一句、`startMs` 都是 0（长段落在句末断开，最长 200 字）。没有为此改表结构，`Recording.hasAudio`（`audio_path` 非空）是唯一判据。

空的 `audio_path` 拼出来是音频目录本身，所以：`AudioStore.removeAudio` 只删 `audio/` 下的文件；播放、导出原始文件、M4A、WAV、解码都先查 `hasAudio`，没有就报 `audioMissing`；详情页不把它当成「找不到音频」。文本编码依次试 UTF-8（含 BOM）、带 BOM 的 UTF-16、GB 18030。

### 5.12 `word_list`（单词分级，迁移 `v15`，X20）

一条录音的生词，由用户自配的 AI 服务从文字稿里挑出，存下来不再重复请求；重新列出时整份替换。主键 `recording_id`，随录音删除。

| 字段 | 类型 | 说明 |
|---|---|---|
| `recording_id` | UUID PK FK | — |
| `words` | TEXT（JSON） | `[{word, level, meaning, segmentIndex}]`：词或短语、CEFR 等级 `A1`～`C2`、在那句里的中文意思、文字稿里第几句（从 0 起） |
| `model` | TEXT | 生成它的模型名 |
| `created_at` | DATETIME | — |

只发含拉丁字母的句子（不发音频），每批 80 句，句子在批内编号；每批最多留 30 个词，同一个词只留第一次出现的。读不懂的批次跳过，全部读不懂才报错。只有文字稿里拉丁字母多于其他文字（且至少 20 个）时才提供。

### 5.13 `phone_mark`（手机录音的重点，迁移 `v16`，X7、X18，2026-11-20）

用这部手机录音时标的重点。手机录音没有卡上的文件名可认，所以挂在 `recording` 上，随录音删除（外键级联）。

| 字段 | 类型 | 说明 |
|---|---|---|
| `id` | INTEGER PK | 自增 |
| `recording_id` | UUID FK | — |
| `offset_ms` | INTEGER | 标记时这部手机的已录时长，暂停不影响 |
| `created_at` | DATETIME | — |

- 录音中 `recording` 行还不存在：标记先记在内存里，同时写进 CAF 旁边的 `phone-<开始时间毫秒>.caf.marks`（毫秒数的 JSON 数组），存入录音时和 `recording` 行在同一个事务里写进本表；App 被关掉后找回的录音也带着标记（§4 的手机录音文件布局）。
- 与 `recording_mark` 相同：2 秒内的重复标记丢弃，超过录音时长的不显示，只存在手机上。显示时两张表合成同一种「播放标记」（`RecordingLibrary.playbackMarks`），列表的重点数、「有重点」筛选、详情页的重点列表和播放条刻度都用它。

### 5.14 `remote_recording`（录音在闻笺服务器上的 id，迁移 `v17`，`product-spec.md` §7.3b，2026-11-27）

用闻笺账号转写或生成纪要时，记下本机录音对应服务器上的哪条录音，免得同一条录音在服务器上建两次。按账号分开：这部手机换一个账号登录，各有各的对应。主键 `(account_id, recording_id)`，随本机录音删除（外键级联）。

| 字段 | 类型 | 说明 |
|---|---|---|
| `account_id` | UUID | 闻笺账号的 id |
| `recording_id` | UUID FK | 本机录音 |
| `server_id` | UUID | 服务器上的录音 id |
| `has_audio` | BOOL | 服务器上那条录音有没有音频；只为发文字稿生成纪要而建的为 `false` |
| `created_at` | DATETIME | — |

- 用账号转写：上传音频（服务器按 SHA-256 认出已有的同一段音频），记下 `has_audio = true`，替换原来只有文字的那条对应（服务器上那条只有文字的录音留着，用户可以在账号里删）。
- 只用文字生成纪要：有对应就用（有没有音频都行），没有就建一条不带音频的录音，`Idempotency-Key` 用 `text-<本机录音 id>`，回答丢了重发也不会建第二条；然后 `PUT /recordings/{id}/transcript` 放上本机的文字稿（每次都放，本机改过的字也带上），再生成纪要。服务器回答 `404 recording_not_found`（在别处删了）时忘掉这条对应、换一个新键重建一次。
- 注销账号后删掉这个账号的全部对应；退出登录不删，同一个账号再登录还能用。

## 6. App 错误码（M1）

| 错误码 | 含义 | 可重试 | 用户看到的处理 |
|---|---|---|---|
| `bluetoothOff` | 手机蓝牙关闭 | 否 | 引导打开蓝牙 |
| `bluetoothUnauthorized` | 没有蓝牙权限 | 否 | 引导去设置授权 |
| `bluetoothUnsupported` | 设备不支持低功耗蓝牙，或蓝牙正在重置 | 否 | 提示稍后重试 |
| `connectTimeout` | 连接超时 | 是 | 提示按卡上按键唤醒后重试 |
| `connectFailed` | 连接失败，或服务、特征发现失败 | 是 | 同 `connectTimeout` |
| `unknownCard` | 系统不认识这个外设标识（蓝牙重置后） | 否 | 重新扫描 |
| `disconnected` | 操作中途断开 | 是 | 自动挂起连接；同步任务重试 |
| `requestTimeout(cmd)` | 命令无响应 | 是 | 重试 1 次后提示；录音控制（`0x51`～`0x53`、`0x50`）例外：不重发（第一次可能已生效、只是回包丢失），改为读一次 `0x56` 按卡上状态更新，细节见 `product-spec.md` §7.1（#47） |
| `notPaired` | 卡未配对或配对失效 | 否 | 引导重新配对 |
| `pairVerifyFailed` | 绑定或解绑后查询不一致 | 是 | 提示重试配对 |
| `pairCancelled` | 卡已被其他设备绑定，用户没有确认重新绑定 | — | 不提示错误，回到设备页 |
| `cardBusyRecording` | 录音中，不能列表或下载 | 是 | 等录音停止后自动继续 |
| `fileNotFound` | `0x70` 回 `0xF0` | 否 | 标记该 SyncItem，重新列表 |
| `transferFailed` | `0x70` 回 `0x40`，或长度不符 | 是 | 自动重试 |
| `cardBusy` | `0x70` 只回 1 字节 `0x40`，卡拒绝传输（#38） | 否 | 保留已下载部分，不计失败次数，停止本轮；提示长按关机再开机 |
| `decryptFailed` | 文件头校验不通过 | 否（换构建号后重试一次，§4.3） | 保留卡上文件，原始字节存到诊断目录，提示反馈 |
| `unexpectedReply(cmd)` | 回包格式不符合协议，或设置写入后读回不一致 | 是 | 重试 1 次后提示反馈 |
| `invalidArgument` | 参数非法（如增益超出 1～9），没有发出任何命令 | 否 | 程序错误，记日志 |
| `bondStorageFailed` | Keychain 读写 bondId 失败 | 是 | 提示重试配对 |
| `storeFailed` | 写库失败（OGG 已删回，卡上文件不动） | 是 | 自动重试 |
| `phoneStorageFull` | 手机空间不足 | 否 | 提示清理空间 |
| `firmwareUnverified` | 固件不在已验证表 | — | 只是警告，不阻断（§2.4） |

M2 起后端错误使用 §7.3 的统一结构，不和这张表混用。

---

## 7. 后端接口契约（M2～M4，模块级）

技术栈：Python + FastAPI + PostgreSQL，任务队列放在 PostgreSQL 里（ADR-002）；腾讯云 COS 存音频（ADR-003）。具体库和版本见 ADR-012（2026-11-22，Proposed）：SQLAlchemy 2（异步，psycopg 3）+ Alembic、Pydantic v2、argon2-cffi、PyJWT；任务队列自己写，一张 `tasks` 表（ADR-013，2026-11-22，Proposed）。代码在 `backend/`，第一片（账号、设备登记、意见反馈）、第二片（录音与上传）、第三片（任务队列与转写骨架）、第四片（AI 生成）已做，见 `backend/README.md`。

### 7.1 通用约定

- 前缀 `/v1`；JSON；时间用 ISO 8601 带时区；id 用 UUID。
- 鉴权：`Authorization: Bearer <access token>`。access token 15 分钟有效；refresh token 30 天有效，每次刷新换新，旧的立即作废。
- **未登录时 App 不调用任何接口**（`backend-design.md` §4.6）。
- 写操作带 `Idempotency-Key` 头，服务端保存 24 小时，重复请求返回第一次的结果（响应头 `Idempotent-Replayed: true`）。键按调用方区分：已登录时是令牌里的用户（access token 换新后仍是同一个调用方），没登录时是匿名；同一个键配不同的请求返回 `422 idempotency_key_reused`，第一次还没处理完时返回 `409 idempotency_in_progress`。服务器错误（5xx）和标了 `retryable` 的错误（比如 `401 token_expired`、`429 code_too_frequent`）不保存：App 刷新令牌后用同一个键重发，要能真正执行，而不是拿回之前那个 401。保存的响应加密存放（刷新令牌的响应里有令牌）。
- **刷新令牌时一定要带 `Idempotency-Key`**：已作废的刷新令牌再次出现会被当成被盗用，整条登录链吊销；带了键，网络断开后的重试拿到的是同一对新令牌。

### 7.2 接口分组

| 模块 | 里程碑 | 接口（示意） | 说明 |
|---|---|---|---|
| 账号 | M2 | `POST /auth/sms/send`、`POST /auth/sms/login`、`POST /auth/email/register`、`POST /auth/email/verify`、`POST /auth/password/login`、`POST /auth/password/reset/send`、`POST /auth/password/reset`、`POST /auth/refresh`、`POST /auth/logout`、`GET /me`、`POST /me/password`、`DELETE /me` | K1；`DELETE /me` 是 App 内注销，删除账号及全部数据。**已做**（2026-11-22）。手机号第一次登录即建号；邮箱先注册再验证；验证码 6 位、10 分钟有效、最多试 5 次、同一目标 60 秒一条、每天 10 条；找回密码不论邮箱有没有注册都回同样的结果；改密码、重置密码后其他设备都要重新登录 |
| 设备登记 | M2 | `GET /devices`、`PUT /devices/{sn_hash}`、`DELETE /devices/{sn_hash}` | A4b；上传 bondId（服务端加密存储），换手机时取回。`sn_hash` 是 App 算的 SHA-256(sn)（64 位十六进制）。**已做**（2026-11-22） |
| 录音与上传 | M2 | `POST /recordings`（建元数据，返回预签名分片上传地址）、`POST /recordings/{id}/upload`（断点续传：新地址和已传的分片）、`POST /recordings/{id}/upload-complete`、`GET /recordings/{id}/audio-url`、`GET /recordings`、`GET /recordings/{id}`、`DELETE /recordings/{id}` | 音频直传对象存储，不经过应用服务器。**已做**（2026-11-22），COS 暂用本机替身。同一账号里同一 `audio_sha256` 只建一条，再提交返回已有的那条（未传完时带续传地址）；分片 8 MiB，地址 1 小时有效；完成时服务端按声明的大小核对每个分片再合并；7 天没传完的上传作废；删除留墓碑（`deleted_at`）供 M4 同步，音频从存储删除；没有音频的录音（文字导入）不上传 |
| 转写 | M2 | `POST /recordings/{id}/transcribe {language, speakers}` → 任务；`GET /recordings/{id}/transcript`；`PATCH /recordings/{id}/speakers {speakers: {标签: 名称}}`；`PUT /recordings/{id}/transcript {engine, language, segments}`：App 自己的文字稿（本机或用户的服务转出的），存为 `asr_provider = app:<engine>`，用来不上传录音就生成纪要（`product-spec.md` §7.3b），录音可以没有音频，服务器转写在排队或进行中时 `409 transcription_running` | F1；说话人重命名。**骨架已做**（2026-11-22）：音频传完才能转写；同一条录音已有排队或进行中的转写时返回那个任务（200），否则新建（202）；结果是 `segments`（`start_ms`、`end_ms`、`speaker`、`text`）和 `speakers`（用户起的名字，只能给文字稿里出现的标签起名，空名删除，重新转写后清空）；转写成功记一条 `asr_seconds` 用量。识别引擎是可替换接口，现在是开发用替身（生产拒绝启动），真引擎等 ASR 对比和账号 |
| AI 生成 | M2 | `POST /recordings/{id}/summaries {template_id, profession}` → 任务；`GET /recordings/{id}/summaries`；`GET /templates` | G1、G2a。**已做**（2026-11-22），大模型暂用开发替身（生产拒绝启动）。提示词、场景、长文分段（超过 9000 字先每 6000 字压缩一次）和回复解析与 App 的 `Summarizer` 完全相同（ADR-009「提示词只有一份来源」）：App 的 Swift 代码是来源，后端 `revive_api/summaries.py` 照它移植，`app/ReviveKit/Tests/AssistantTests/Fixtures/prompts` 里的样本两边的测试都逐字比对，改了一边不改另一边 CI 就失败。`template_id` 是场景代号，不给则由模型判断；职业截到 40 字。要先有文字稿（`409 no_transcript`）；同一条录音已有排队或进行中的生成时返回那个任务。每次生成都保留，列表新的在前；回复读不出来（`bad_reply`）按可重试处理。记一条 `llm_tokens` 用量。模板就是 10 种内置场景，从代码读，不建表（G2b 自定义模板不做）。换一个角度重起标题：`POST /recordings/{id}/retitle {current_title}` → 任务，成功后任务的 `result` 是 `{title, model}`；内容取最新纪要的标题和摘要，没有纪要用文字稿（都没有 `409 no_content`），提示词、用户消息和标题解析与 App 的 `Summarizer.retitle` 相同；后端不改录音标题，换不换由 App 按 `applyAITitle` 的规则决定；计入 `llm_tokens` 额度 |
| 任务 | M2 | `GET /tasks/{id}` | 状态见 §7.4。**已做**（2026-11-22）：返回 `status`、`attempts`、`error {code, message}`（重试等待中也带上一次的错误）、`finished_at`；只能读自己的任务 |
| 意见反馈 | M2 | `POST /feedback` | O1b。**已做**（2026-11-22） |
| 用量 | M2 | `GET /me/usage` | X2；超额返回 `quota_exceeded`。**骨架已做**（2026-11-22）：按北京时间的自然月统计，返回本月起止、转写秒数（已用、排队中预占、额度、剩余）和大模型 token（已用、额度、剩余），额度为空表示不限。提交转写时，本月已用 + 排队中的录音时长 + 这一条超过额度就 `429 quota_exceeded`（不可重试），失败的任务把预占退回；纪要的 token 事先算不出，本月用完才拒绝，最后一次可能略超。每个账号同时排队和进行中的任务最多 10 个（`429 too_many_tasks`，可重试）。检查和入队在锁住用户行之后进行，并发请求不会一起钻空子。额度是配置项 `REVIVE_ASR_MONTHLY_SECONDS`、`REVIVE_LLM_MONTHLY_TOKENS`，**多少还没定**；生产环境没设就拒绝启动 |
| 实时转写 | M3 | `WS /realtime?codec=opus&sample_rate=16000&language=zh` | H1；App 发 Opus 帧，服务端推流式文字；断线后 App 补传本地音频 |
| AI 对话 | M4 | `POST /chat`（`recording_id` 可选，不带即全局），SSE 返回 | G3 |
| 同步 | M4 | `GET /sync?since=<cursor>`、`POST /sync` | N1；见 §7.5 |
| 笔记 | M4 | 走同步接口；图片用预签名上传 | I1 |

### 7.3 错误结构

```json
{"error": {"code": "quota_exceeded", "message": "本月转写时长已用完", "retryable": false}}
```

`code` 为稳定的小写英文标识，App 按 `code` 处理，`message` 只用于展示。HTTP 状态码按语义使用（400/401/403/404/409/422/429/5xx）。`401 token_expired` 时 App 用 refresh token 换新后重试一次。

### 7.4 异步任务状态

```
queued ──▶ running ──▶ succeeded
               │
               └──▶ failed（retryable=true 时服务端自动重试，最多 3 次）
```

实现（ADR-013）：一次执行算一次尝试，最多 4 次（第一次加 3 次重试），重试前分别等 30、60、120 秒，等待中 `status` 回到 `queued` 并保留上一次的错误；工作进程取任务时拿 15 分钟租约，进程挂了租约过期由别的进程接手（算一次新的尝试），4 次都没回来就 `failed`（`worker_lost`）；写结果时要求任务仍在这一次尝试中，过期的那次结果丢弃。删除录音时，它没完成的任务改为 `failed`（`recording_deleted`），进行中的那次结果不写入。

App 先轮询 `GET /tasks/{id}`（间隔 2 s 起，指数退避到 30 s）；推送通知在 M2 内再决定是否做。后端或网络故障时，App 本地记录待提交的任务，恢复后补交（§7.1 第 5 条）。

### 7.5 同步模型（M4）

- 每条记录有 `id`、`updated_at`、`version`、`deleted`（软删除墓碑）。
- 拉取：`GET /sync?since=<cursor>` 返回 cursor 之后变化的记录和新 cursor。
- 推送：`POST /sync` 带上本地改动及其 `base_version`；版本冲突时以 `updated_at` 较新的为准（最后修改者胜），被覆盖的一方写入冲突日志。
- 首次登录（X3）：本地录音和设备全部作为新增推送；同一 `audio_sha256` 已存在的录音不重复上传。

## 8. 后端数据模型（M2～M4）

| 表 | 主要字段 | 里程碑 |
|---|---|---|
| `users` | id、phone（唯一，可空，`+86` 开头）、email（唯一，可空，小写）、email_verified_at、password_hash（Argon2id，手机号账号为空）、created_at；phone 和 email 至少有一个 | M2 |
| `refresh_tokens` | id、user_id、token_hash（SHA-256）、family_id（同一次登录换出来的都属于一条链）、expires_at、revoked_at、replaced_by、created_at | M2 |
| `verification_codes` | id、target（手机或邮箱）、purpose（sms_login、email_verify、password_reset）、code_hash（HMAC）、expires_at、attempts、consumed_at、created_at | M2 |
| `devices` | id、user_id、sn_key（对 App 给的 SHA-256(sn) 再做服务端 HMAC，只用来查找）、secret（SHA-256(sn) 和 bondId 一起加密）、name、firmware、created_at、updated_at | M2 |
| `recordings` | id、user_id、device_id（设备删掉后置空）、source（card、phone、import、realtime）、started_at、duration_ms、title、audio_sha256、audio_size、audio_content_type（没有音频时三项都为空）、audio_object_key（每次开始上传换一个新键）、upload_id（进行中的分片上传）、uploaded_at、version、created_at、updated_at、deleted_at；（user_id, audio_sha256）在未删除的行里唯一。folder_id 等 M4 | M2 |
| `object_deletions` | id、object_key、upload_id（有值表示取消这次分片上传，空表示删除对象）、attempts、last_error、created_at；和删掉引用的那一步在同一个事务里写入，不属于任何用户，所以注销后仍在；请求结束后立即清，存储不可用时由 `maintenance` 重试 | M2 |
| `transcripts` | recording_id（主键，一条录音一份，重新转写覆盖）、language、segments（JSONB：`start_ms`、`end_ms`、`speaker`、`text`）、speakers（JSONB：标签 → 用户起的名称）、asr_provider、created_at、updated_at | M2 |
| `summaries` | id、recording_id、scene（用的模板，即场景代号）、content（JSONB：title、summary、sections、todos、tags、people、outline、quotes，和 App 的纪要同样的栏目，一次生成全部）、model、created_at；每次生成一行 | M2 |
| `templates` | 暂不建表：内置模板就是 10 种场景，在代码里（`summaries.SCENES`，和 App 的 `RecordingScene` 一致）；有用户自定义模板时再建 | M2 |
| `tasks` | 队列和业务状态是同一张表（ADR-013）：id、user_id、recording_id、kind（`transcribe`、`summarize`、`retitle`）、params（JSONB）、status、attempts、max_attempts、run_after、lease_until、error_code、error_message、result（JSONB，没有自己的表的任务把小结果放这里，如 retitle 的新标题）、created_at、updated_at、started_at、finished_at | M2 |
| `usage_records` | id、user_id（注销后置空，记录保留）、kind（asr_seconds、llm_tokens）、amount、occurred_at | M2 |
| `feedback` | id、user_id、content、app_version、created_at | M2 |
| `idempotency_records` | id、scope（调用方）、key、request_hash、status_code（处理中为空）、content_type、body（加密）、created_at；24 小时后清掉 | M2 |
| `notes` | id、recording_id、offset_ms、text、image_keys、version、updated_at、deleted | M4 |
| `folders` | id、user_id、name、version、updated_at、deleted | M4 |
| `chat_messages` | id、user_id、recording_id（可空）、role、content、created_at | M4 |

- 服务端只存 `sn` 哈希的 HMAC，不存原值，也不存裸哈希：序列号能被枚举，裸的 SHA-256 在数据库泄露时能反推出 sn，再加上仓库里公开的 `DEVICE_KEY_SECRET` 就能算出这张卡的音频密钥（ADR-006、ADR-012）。bondId 和 App 给的哈希一起用 AES-256-GCM 加密存储；现在密钥来自环境变量，上线前换成云厂商密钥管理服务托管的信封加密。
- 原始音频是唯一的事实来源；转写和总结都能重算，所以保留 `asr_provider`、`model` 字段，便于换模型后批量重跑（`backend-design.md` §4.5）。
- 注销账号（`DELETE /me`）：删除该用户的全部数据库记录和 COS 对象；用量记录匿名化后保留。现在的做法：用户表一行删除，令牌、设备、反馈、录音通过 `ON DELETE CASCADE` 一起删掉（不留 `deleted_at`）；存储里的音频在同一事务里记入 `object_deletions`，响应后立即删除，删不掉的稍后重试。用量记录的 user_id 置空后保留（`ON DELETE SET NULL`）；任务、文字稿随录音一起删掉。

## 9. 待决定与待验证

| 项 | 类型 | 何时解决 |
|---|---|---|
| App 本地数据库库选型（候选 GRDB） | 待决定 | M1 开工时，写 ADR |
| 后端具体库与版本 | ADR-012 已提出（Proposed），等确认 | 2026-11-22 |
| 任务队列用库还是自己写 | ADR-013 已提出（Proposed）：自己写，一张 `tasks` 表；等确认 | 2026-11-22 |
| 任务完成是否用推送通知 | 待决定 | M2 |
