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
  ├─ CardService ──── 设备业务：配对、录音控制、设置、文件列表与下载
  │     └─ CardProtocol ── 帧编解码、命令白名单、固件差异适配
  │           └─ CardLink ──── CoreBluetooth：扫描、连接、写、通知、断线恢复
  │
  ├─ SyncEngine ───── 卡上文件 → 本地录音库，按 §4 状态机
  │
  ├─ Library ──────── 本地数据库与音频文件（§5）
  │
  └─ Player / Exporter ── 解密后的 OGG 播放与分享
```

规则：

- **M1 各层不引用任何网络库**。M2 的同步与 AI 模块单独成层，只读写 Library，不被设备层调用（`CLAUDE.md` 硬规则 3）。
- 协议细节（命令字、帧格式、JSON 字段）只出现在 CardProtocol，上层只看到 Swift 类型。固件版本差异也在这一层处理。
- 协议层从 `ios-prototype/Sources/DNoteProtocol.swift` 起步，原型的单元测试和样本一并迁移。
- 代码位置：每层是 `app/ReviveKit/` 里的一个 Swift Package 目标，依赖方向在 `Package.swift` 里声明；App 目标 `app/Revive/` 只负责界面（#36）。

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
| `listFiles()` | `0x90`，收到 `end=1` 结束 | `[CardFile(name, size)]` | 已配对；**录音中卡会回空列表，不代表卡上没有文件**：列表为空时再查 `0x56`，录音中或已暂停则报 `cardBusyRecording`（#38） |
| `download(name, size, from)` | `0x70 {cmd:1, name, offset:from}`，拼接分片直到 EOF | 从 `from` 开始的原始文件字节 | 已配对；超时 = (size − from) ÷ 15 KB/s + 10 s；每个分片的 `offset` 必须等于已收到的位置（#34 证实是分片在文件中的绝对位置），跳号或总长不符报 `transferFailed` |
| `delete(name)` | `0x91 {name}` | — | 已配对；**只由 SyncEngine 调用**（§4） |

**设备主动推送**（转成事件流 `events`）：

| 推送 | 事件 | 用途 |
|---|---|---|
| `0x54 {name}` | `recordingStarted(name)` | 按键开始录音 |
| `0x56 {rec:0}`、`0x55` | `recordingStopped` | 触发 SyncEngine 刷新列表 |
| `0x80`（约每 4 分钟一次） | `deviceInfo(DeviceInfo)` | 更新电量与空间 |
| 断开 | `disconnected(reason)` | 进入挂起连接 |

**未配对的识别**：`0x51` 回 `NULL`，或 `0x90` 在 8 s 内无响应，都映射为 `notPaired` 错误，引导用户重新配对。

**下载断点续传**：`0x70` 的 `offset` 可以是任意值，跨连接续传结果与完整下载一致（#34 已验证）。下载中途断开时，保留已收到的字节，重连后从该位置续传。

### 2.4 固件版本适配（X1）

- 每次连接后读 `0x80` 的 `v`。已验证版本表：`["1.50"]`。
- 版本不在表内时：照常工作，按 v1.50 的行为处理；设备页显示「此固件版本未经验证，如遇问题请反馈」；日志记录版本号。不阻断使用。
- 发现某个版本的行为不同，在 CardProtocol 里按版本分支处理，并把该版本加入已验证表（#8）。

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
| 设置密钥 | `0xA2 [1] + HMAC-SHA256(DEVICE_KEY_SECRET, sn)` | 无回包则终止，提示重试。回包内容尚无真机证据，收到任何 `0xA2` 回包都算成功（解密用文件头里的密钥材料，不依赖这一步）；真机确认后收紧（`test-spec.md` §2） |
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
  - `decryptFailed`：不再重试，原始字节已留在诊断目录。
- 下载中途断开（App 仍在运行）：保留临时文件，重连后按其长度续传（§2.3）。
- App 被杀或崩溃后重启：`downloading` 一律回到 `discovered`，临时文件清掉，从头下载。临时文件可能没有完整落盘，不拿它续传。
- **在 App 里删除本地录音不会让它重新同步回来**：删除 Recording 和 OGG 文件，但 SyncItem 保持 `stored`，列表比对时照常跳过；也不向卡发任何命令（`test-spec.md` T-M1-32）。
- 删除只在 `stored` 之后发生。`0x91` 发出后连接断开、不确定是否删成功的，下次列表里不在就记为已删除，还在就重新删。
- 实现（#39）：下载中的字节写到 `tmp/<SyncItem id>.part`，OGG 先写到 `staging/` 并 `fsync`，再原子移动到 `audio/`。启动恢复（`RecordingLibrary.recoverAfterLaunch`）会清空 `tmp/` 和 `staging/`，并删掉 `audio/` 里没有 Recording 记录的 OGG：这是「写完 OGG、事务未提交时崩溃」留下的孤儿文件。

### 4.4 触发时机

- 连接成功并完成校时后；
- 收到 `recordingStopped` 后等待 1 s；
- 用户下拉刷新。

录音中或已暂停（`rec` 不为 0）不触发，因为录音中列表为空（H5）；暂停时的列表行为未测，按录音中处理。同步过程中开始录音：当前文件下载完后暂停，等录音停止再继续。实现上，每下载一个文件前查一次 `0x56`（#39）。

CardService 的事件流只有一个消费者，SyncEngine 不直接订阅：由消费事件流的一方（App 层）把事件转给 `SyncEngine.handle(_:)`。

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
| `last_seen_at` | DATETIME | — |
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
| `started_at` | DATETIME | 从文件名解析，按设备时间；解析失败用同步时间 |
| `duration_ms` | INTEGER | 由 OGG 帧数计算 |
| `audio_path` | TEXT | 相对路径 |
| `audio_sha256` | TEXT | OGG 文件的哈希 |
| `title` | TEXT | 默认按开始时间生成 |
| `created_at` / `updated_at` | DATETIME | — |
| `folder_id` / `trashed_at` | — | M4 预留 |
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

迁移：用版本化的迁移脚本，只增不改；每次发版前在旧版本数据上跑一遍升级测试。

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
| `requestTimeout(cmd)` | 命令无响应 | 是 | 重试 1 次后提示 |
| `notPaired` | 卡未配对或配对失效 | 否 | 引导重新配对 |
| `pairVerifyFailed` | 绑定或解绑后查询不一致 | 是 | 提示重试配对 |
| `pairCancelled` | 卡已被其他设备绑定，用户没有确认重新绑定 | — | 不提示错误，回到设备页 |
| `cardBusyRecording` | 录音中，不能列表或下载 | 是 | 等录音停止后自动继续 |
| `fileNotFound` | `0x70` 回 `0xF0` | 否 | 标记该 SyncItem，重新列表 |
| `transferFailed` | `0x70` 回 `0x40`，或长度不符 | 是 | 自动重试 |
| `decryptFailed` | 文件头校验不通过 | 否 | 保留卡上文件，原始字节存到诊断目录，提示反馈 |
| `unexpectedReply(cmd)` | 回包格式不符合协议，或设置写入后读回不一致 | 是 | 重试 1 次后提示反馈 |
| `invalidArgument` | 参数非法（如增益超出 1～9），没有发出任何命令 | 否 | 程序错误，记日志 |
| `bondStorageFailed` | Keychain 读写 bondId 失败 | 是 | 提示重试配对 |
| `storeFailed` | 写库失败（OGG 已删回，卡上文件不动） | 是 | 自动重试 |
| `phoneStorageFull` | 手机空间不足 | 否 | 提示清理空间 |
| `firmwareUnverified` | 固件不在已验证表 | — | 只是警告，不阻断（§2.4） |

M2 起后端错误使用 §7.3 的统一结构，不和这张表混用。

---

## 7. 后端接口契约（M2～M4，模块级）

技术栈：Python + FastAPI + PostgreSQL，任务队列放在 PostgreSQL 里（ADR-002）；腾讯云 COS 存音频（ADR-003）。具体库和版本在 M2 工程初始化时用 ADR 确认，候选：SQLAlchemy 2 + Alembic、Pydantic v2、procrastinate（基于 PostgreSQL 的任务队列）。

### 7.1 通用约定

- 前缀 `/v1`；JSON；时间用 ISO 8601 带时区；id 用 UUID。
- 鉴权：`Authorization: Bearer <access token>`。access token 15 分钟有效；refresh token 30 天有效，每次刷新换新，旧的立即作废。
- **未登录时 App 不调用任何接口**（`backend-design.md` §4.6）。
- 写操作带 `Idempotency-Key` 头，服务端保存 24 小时，重复请求返回第一次的结果。

### 7.2 接口分组

| 模块 | 里程碑 | 接口（示意） | 说明 |
|---|---|---|---|
| 账号 | M2 | `POST /auth/sms/send`、`POST /auth/sms/login`、`POST /auth/email/register`、`POST /auth/email/verify`、`POST /auth/password/login`、`POST /auth/password/reset`、`POST /auth/refresh`、`POST /auth/logout`、`DELETE /me` | K1；`DELETE /me` 是 App 内注销，删除账号及全部数据 |
| 设备登记 | M2 | `GET /devices`、`PUT /devices/{sn_hash}`、`DELETE /devices/{sn_hash}` | A4b；上传 bondId（服务端加密存储），换手机时取回 |
| 录音与上传 | M2 | `POST /recordings`（建元数据，返回 COS 预签名分片上传地址）、`POST /recordings/{id}/upload-complete`、`GET /recordings/{id}/audio-url` | 音频直传 COS，不经过应用服务器 |
| 转写 | M2 | `POST /recordings/{id}/transcribe` → 任务 id；`GET /recordings/{id}/transcript`；`PATCH /recordings/{id}/speakers` | F1；说话人重命名 |
| AI 生成 | M2 | `POST /recordings/{id}/summaries {template_id}` → 任务 id；`GET /recordings/{id}/summaries`；`GET /templates` | G1、G2a |
| 任务 | M2 | `GET /tasks/{id}` | 状态见 §7.4 |
| 意见反馈 | M2 | `POST /feedback` | O1b |
| 用量 | M2 | `GET /me/usage` | X2；超额返回 `quota_exceeded` |
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

App 先轮询 `GET /tasks/{id}`（间隔 2 s 起，指数退避到 30 s）；推送通知在 M2 内再决定是否做。后端或网络故障时，App 本地记录待提交的任务，恢复后补交（§7.1 第 5 条）。

### 7.5 同步模型（M4）

- 每条记录有 `id`、`updated_at`、`version`、`deleted`（软删除墓碑）。
- 拉取：`GET /sync?since=<cursor>` 返回 cursor 之后变化的记录和新 cursor。
- 推送：`POST /sync` 带上本地改动及其 `base_version`；版本冲突时以 `updated_at` 较新的为准（最后修改者胜），被覆盖的一方写入冲突日志。
- 首次登录（X3）：本地录音和设备全部作为新增推送；同一 `audio_sha256` 已存在的录音不重复上传。

## 8. 后端数据模型（M2～M4）

| 表 | 主要字段 | 里程碑 |
|---|---|---|
| `users` | id、phone（唯一，可空）、email（唯一，可空）、password_hash、created_at、deleted_at | M2 |
| `refresh_tokens` | id、user_id、token_hash、expires_at、revoked_at、replaced_by | M2 |
| `verification_codes` | id、target（手机或邮箱）、purpose、code_hash、expires_at、attempts | M2 |
| `devices` | id、user_id、sn_hash、bond_id（加密存储）、name、firmware、updated_at | M2 |
| `recordings` | id、user_id、device_id、source、started_at、duration_ms、audio_object_key、audio_sha256、title、folder_id、version、updated_at、deleted | M2 |
| `transcripts` | id、recording_id、language、segments（JSONB：开始、结束、说话人、文本）、speakers（JSONB：说话人名称）、asr_provider、created_at | M2 |
| `summaries` | id、recording_id、template_id、kind（总结、大纲、思维导图、金句、标签）、content（JSONB）、model、created_at | M2 |
| `templates` | id、name、category、prompt、is_builtin | M2 |
| `tasks` | 由任务队列库管理；业务侧另记 kind、recording_id、user_id、status、error_code | M2 |
| `usage_records` | id、user_id、kind（asr_seconds、llm_tokens）、amount、occurred_at | M2 |
| `feedback` | id、user_id、content、app_version、created_at | M2 |
| `notes` | id、recording_id、offset_ms、text、image_keys、version、updated_at、deleted | M4 |
| `folders` | id、user_id、name、version、updated_at、deleted | M4 |
| `chat_messages` | id、user_id、recording_id（可空）、role、content、created_at | M4 |

- 服务端只存 `sn` 的哈希，不存原值。bondId 加密存储，密钥由云厂商密钥管理服务托管。
- 原始音频是唯一的事实来源；转写和总结都能重算，所以保留 `asr_provider`、`model` 字段，便于换模型后批量重跑（`backend-design.md` §4.5）。
- 注销账号（`DELETE /me`）：删除该用户的全部数据库记录和 COS 对象；用量记录匿名化后保留。

## 9. 待决定与待验证

| 项 | 类型 | 何时解决 |
|---|---|---|
| App 本地数据库库选型（候选 GRDB） | 待决定 | M1 开工时，写 ADR |
| 后端具体库与版本 | 待决定 | M2 工程初始化，写 ADR |
| 任务完成是否用推送通知 | 待决定 | M2 |
