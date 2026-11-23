# 测试策略

**范围**　M1、M1.5 到用例级；M2～M4 到方法级，进入里程碑时细化
**上游**　`backend-design.md` §7.1（六条验收）、`features.md`（范围）、`prd.md`（契约与状态机）、`product-spec.md`（页面与文案）、`design-spec.md`（视觉）
**日期**　2026-11-06（#28）；M1.5 用例 2026-11-17（#70、#74）

用例编号 `T-<里程碑>-<序号>`，回填到 `features.md` 的「测试覆盖」一栏。M1.5 写作 `M15`（`T-M15-01`）；序号 01～49 是自动用例，50 起是真机用例，和 M1 一样。

---

## 1. 测试分层

| 层 | 测什么 | 怎么跑 | 何时跑 |
|---|---|---|---|
| 单元 | 帧编解码、命令白名单、解密、OGG 封装、广播解析、错误码映射 | `swift test --disable-xctest`（`app/ReviveKit`，在 macOS 上跑，不需要模拟器）；后端 `pytest` | 每次提交 |
| 集成（模拟卡） | 同步状态机、配对流程、断线与重试；在 CardLink 层换成模拟卡 | 同上 | 每次提交 |
| 真机 | 与真卡的完整流程、后台与锁屏、吞吐、多卡 | 人工按脚本执行，证据入库（§4） | 每个里程碑验收前；协议层改动后 |
| 端到端（M2 起） | App + 后端 + 云服务 | TestFlight 构建 + 测试环境后端 | 每个里程碑验收前 |
| AI 评测（M2 起） | 转写字错率、说话人区分、总结质量 | 固定测试集 + 评分表（§6） | 换模型或改提示词时 |

原则：**能在模拟卡上复现的，不靠真机测**。真机时间有限（目前只有 1 张卡），留给模拟卡做不到的部分：时序、射频、系统后台行为、固件差异。

## 2. 模拟卡

在 CardLink 层实现一个模拟卡，行为按 `PROTOCOL.md` 和真机证据编写：

- **数据**：可配置的文件列表，`FakeCard` 本身不带样本，文件内容由各测试传入（`FakeCard(files:)`）。同步测试（`Tests/SyncEngineTests/`）读 `app/ReviveKit/Tests/CardProtocolTests/Fixtures/` 的 `encrypted.bin`，并与同目录的 `expected_ogg.bin` 比对；其余用例在测试代码里现场构造字节；播放器测试用 `CardTestSupport` 的 `SyntheticOpus` 现场编码 Opus 包。样本由 `app/ReviveKit/scripts/make_fixtures.py` 生成，它同时把三个音频样本写进 `ios-prototype/Tests/Fixtures/`（原型工程用的副本）。
- **行为**：录音中 `0x90` 返回空列表；未配对时 `0x51` 回 `{"name":"NULL"}`，`0x90`、`0x70`、`0x91` 照常执行（#38）；`0xA0`、`0xA2`、`0x91` 回 `0x01`；按键录音的主动推送序列。
- **回放**：能按 `evidence/` 下的真机日志（如 `v1-live/*/notify.jsonl`）原样回放通知。
- **故障注入**：在第 N 个分片后断开；某条命令不响应；分片返回 `0x40` 或 `0xF0`；分片长度不足；通知乱序到达；`0x70` 只回 1 字节 `0x40`（拒绝传输）；`0xA2` 回 `0x00`。

模拟卡与真卡的行为不一致时，以真卡为准，修模拟卡并补一条回归用例。

实现（#37）：`app/ReviveKit/Tests/CardTestSupport/`，独立 target，不在产品里，不会打进 App。

- `FakeCard`：实现 `CardLink` 协议，回包在 `send` 内同步入队，测试结果确定。故障注入见 `FakeCard.Fault`；`advertise()` 模拟卡重新广播，完成挂起连接。
- `EvidenceLog`：读取 `evidence/` 下两种 jsonl 格式（`event` 或 `kind` 为 `notify` 的行），按原顺序回放，不保留时间间隔。
- 第 2 道检查（§3.5）：`FakeCard.wroteOnlyWhitelistedCommands`，模拟卡集成用例结束时断言。
- 故障注入另有 `ignoreBondWrites`：`0xA0` 回 `0x01` 但不改变绑定，用于 T-M1-13。
- #38 真机联调核对了原先的假设（`evidence/v38-card-link/README.md`）：`0xA2` 回 1 字节 `0x01`，与假设一致；以下与假设不一致，模拟卡已按真卡修正并补了回归用例：未配对时 `0x51` 回 JSON `{"name":"NULL"}`（不是 ASCII `NULL`）；未配对时 `0x90`、`0x70`、`0x91` 照常执行；`0x91` 回 `0x01`；`0x90` 结束帧带 `"name":"","size":0`；分片状态字节首片 `0x00`、之后 `0x1N`、末片 `0x2N`。`0xA3` 的回包仍是假设。

## 3. M1 与 M1.5 用例

§3.1～§3.5 是 M1，§3.6 是 M1.5。

### 3.1 协议层（单元）

| 编号 | 用例 | 通过线 |
|---|---|---|
| T-M1-01 | 白名单之外的命令字（含 `0x93`、`0x94`、`0xB0`、`0xB1`、`0x89`）无法构造帧 | 编译期不存在对应常量；遍历 0x00～0xFF 只有白名单内的能构造 |
| T-M1-02 | 帧编解码：长度边界 0、255；PID 错误；长度字段大于实际 | 与 `client/dnote_protocol.py` 输出逐字节一致；非法帧返回空 |
| T-M1-03 | 解密：加密样本解出与期望一致；篡改 1 字节后校验失败 | 解出 `plain.bin`；篡改后报 `decryptFailed` |
| T-M1-04 | OGG 封装：输出与 `expected_ogg.bin` 一致，且能被系统播放器解码 | 逐字节一致；`AVAudioPlayer` 能读出时长。系统不能直接打开 OGG 时，改走解码回退（`OggOpusDecoder` 解成 PCM CAF）：时长与直接播放的误差 < 2 ms，不是静音。播放器与导出见 `Tests/PlayerTests/`，ffprobe 检查见 `evidence/v40-player/`（#40） |
| T-M1-05 | 广播解析：公司 ID 不符的被忽略；固件版本、电量解析正确 | 与原型单元测试一致 |
| T-M1-06 | 固件版本：`1.50` 无警告；其他版本发出 `firmwareUnverified` 且不阻断 | — |
| T-M1-07 | 设置命令：每项 M1 设置生成的帧与 `PROTOCOL.md` §4.1 一致；增益和降噪档位超出 1～9 时拒绝 | — |

### 3.2 配对（模拟卡）

| 编号 | 用例 | 通过线 |
|---|---|---|
| T-M1-10 | 新卡配对：命令顺序为 `0x80 → 0xA1 → 0x87 → 0xA2 → 0xA0 → 0xA1`（`prd.md` §3） | 顺序一致；bondId 写入 Keychain |
| T-M1-11 | 已配对的卡再次配对 | 只发 `0x80`、`0xA1`，不发任何写命令 |
| T-M1-12 | 卡已被其他 bondId 绑定 | 先提示；确认后先 `0xA0 [0]` 再绑定；不确认则不发任何写命令 |
| T-M1-13 | `0xA1` 返回的 bondId 不一致 | 报 `pairVerifyFailed`，本地不保存 |
| T-M1-14 | 配对全程不出现 `0x94` | 记录到的所有写帧中没有 `0x94` |
| T-M1-15 | 解绑 | 发 `0xA0 [0]` 后 `0xA1` 为未绑定；Keychain 中的 bondId 删除；本地录音保留 |

实现（#38）：`app/ReviveKit/Tests/CardServiceTests/` 的 `PairingTests`；同一文件的 `CardServiceTests` 覆盖 `prd.md` §2.3 的业务操作、主动推送事件和下载故障。

### 3.3 同步（模拟卡，故障注入）

对应 `prd.md` §4，也是 #11 验收里「不重复、不丢失」的主要证据。

| 编号 | 用例 | 通过线 |
|---|---|---|
| T-M1-20 | 正常同步 3 个文件 | 3 条 Recording；每个 OGG 可解码；SyncItem 全部 `stored` |
| T-M1-21 | 下载到一半断开，重连后重试 | 从断点续传（请求的 offset 等于已收字节数）；最终 1 条 Recording，OGG 与不中断时一致；无残留临时文件 |
| T-M1-22 | 解密失败 | 状态 `failed`；卡上文件未删；原始字节存入诊断目录 |
| T-M1-22b | 解密失败后换 App 构建号重启（#59） | 同一构建重启不重新下载；换构建后重新下载一次，仍失败则记下新构建号、不再下载；能解密时存入且只有 1 条 Recording；全程不向卡发 `0x91`；无构建号的旧行（迁移 `v2` 前）也会重试 |
| T-M1-23 | 写库前 App 被杀（在写 OGG 和提交事务之间注入崩溃） | 重启后该文件重新下载；最终只有 1 条 Recording |
| T-M1-24 | 已存入的文件再次出现在列表里 | 不重复下载 |
| T-M1-25 | 文件名相同、大小不同 | 当作两个文件，各存一条 |
| T-M1-26 | 开启「同步后删除」：`0x91` 只在 `stored` 之后发出 | 记录到的写帧里，每个 `0x91` 之前，该文件对应的事务已提交 |
| T-M1-27 | `0x91` 发出后断开 | 下次列表不在则记为已删除；还在则重新删除；不出现重复 Recording |
| T-M1-28 | 关闭「同步后删除」（默认） | 全程没有 `0x91` |
| T-M1-29 | 同步中开始录音 | 当前文件完成后暂停；收到 `recordingStopped` 后继续；空列表不导致任何删除或标记 |
| T-M1-30 | 手机空间不足 | `phoneStorageFull`；卡上文件不动 |
| T-M1-31 | 分片返回 `0xF0` 文件不存在 | `fileNotFound`；重新列表 |
| T-M1-32 | 在 App 里删除一条本地录音 | OGG 文件与数据库记录都删除；不向卡发送任何命令；SyncItem 保留为 `stored`，不会被重新下载 |
| T-M1-33 | 下载失败的文件随后从卡上消失（#79） | 自动重试只针对本轮列表里还在、名字和大小都相同的失败项：文件消失后不再反复列表（不出现空重试循环）；同名文件再出现时能同步；同名不同大小时旧的失败项不再重试；新一轮检查成功拿到列表后才替换旧的重试计时器，检查失败时原计时器保留；计时器醒来时卡已断开或换了卡就不触发 |
| T-M1-34 | 录音状态的三路来源乱序到达（#47、#53，`prd.md` §2.5） | 命令回包丢失、`0x56` 无回答或迟到、按键推送与 `0x80` 交错时，界面状态都以更新的来源为准；读 `0x56` 期间到达的 `0x80`（包括与界面一致的）使该回答不改状态；被超过的回答与界面状态相同时仍补上卡的已录时长；全程不重发录音命令 |
| T-M1-35 | 同步只通过与设备无关的接口（ADR-010，`prd.md` §2.6） | 静态：`SyncEngine`、`DeviceSource` 不 import CardProtocol、CardLink、CardService（`check-m1-rules.sh`），`Package.swift` 里 SyncEngine 只依赖 DeviceSource 和 Library。D·NOTE：T-M1-20～33 的用例和断言不变，经 `CardSyncSource` 全部通过；每个卡错误都换成保留原失败码的 `SourceError`；只有「连上」和「录音停止」两个事件触发同步；转换结果与 `expected_ogg.bin` 逐字节一致。另一种设备（内存里的假设备，没有帧和解密）：每个文件只存一条、存入后才删、断点续传不重复 |

实现（#39）：`app/ReviveKit/Tests/SyncEngineTests/`，每个用例结束时断言写帧里没有 `0x93`/`0x94`/`0xB0`/`0xB1`（§3.5 第 2 道检查）。

- T-M1-23 的「被杀」：在提交前的钩子里挂起，永不返回；随后在同一个数据库和目录上新建 SyncEngine，相当于重启。
- T-M1-27 分两种：`FakeCard.Fault.disconnectAfter(.deleteFile)` 表示删除已生效后断开，`disconnectInsteadOf(.deleteFile)` 表示断开时删除未生效。
- 另有失败自动重试，以及录音中不同步两个用例。
- T-M1-33（#79，PR #80）：`absentFailedFileDoesNotCauseEmptyRetryLoop`、`removedFailedFileReturningCanBeSynced`、`replacedSizeDoesNotKeepOldFailureRetrying`、`manualPassCancelsObsoleteRetryTimer`、`failedManualListDoesNotLoseScheduledRetry`；同时加了脱敏的同步诊断（`syncDiagnosticsExposeReasonAndCounts`：请求来源、是否排队、列表数、候选数、可重试数）。真机观察记录在 `evidence/v79-sync-retry/`，计时器边界修复之后的版本尚未真机复验。

- T-M1-34（#47 的 13 个用例，#53 issue 里记为 12 个，实际 13 个都保留；#53 另补 3 组）：`HomeModelTests` 的 `unansweredStartThatDidNothingAsksToRetry`、`lostPauseReplyFollowsTheCard`、`lostStartReplyFollowsTheCard`、`unansweredStatusKeepsToastUntilTheNextDeviceInfo`、`deviceInfoStateIsUsedWhenStatusStaysSilent`、`unknownStatusCodeKeepsTheCommandUnconfirmed`、`newerStateBeatsTheDeviceInfoFallback`、`newerStateBeatsALateStatusAnswer`、`buttonPressBeatsALateReconcileAnswer`、`newerDeviceInfoBeatsAnOlderFallback`、`stopAfterARecoveredStartIsReported`、`stopFoundWithoutItsPushStillSyncs`、`deviceInfoSendsNothingWhileDebugScreenIsOpen`；#53 新增 `agreeingDeviceInfoBeatsALateStatusAnswer`（PR #51 留下的一处）、`DeviceStatusTests` 的 `overtakenStatusAnswerStillRestoresTimer`，以及规则本身的 `RecordingStateOrderTests`。

- T-M1-35：`CardServiceTests` 的 `CardSyncSourceTests`（`cardErrorsMapToSourceErrors`、`onlyConnectAndStopStartASync`、`converterDecryptsAndWrapsInOgg`、`startDateComesFromTheFileName`、`handsOverTheCardsFilesAndState`、`missingFileIsASourceError`），`SyncEngineTests` 的 `OtherDeviceTests`（`storesEachFileOnceThenDeletesIt`、`cutOffDownloadResumesWithoutDuplicates`）。

用变异检查确认过用例有效：分别让已存入的文件重新下载、去掉启动恢复、在提交前发 `0x91`，T-M1-24、23、26 都会失败。

### 3.4 真机（M1 验收前）

| 编号 | 用例 | 通过线 |
|---|---|---|
| T-M1-50 | §7.1 第 1 条：新装 App，开飞行模式（蓝牙开），不注册，完成配对 → App 控制录音 → 按键录音 → 同步 → 播放 → 导出 OGG | 全部成功；全程抓包无网络请求 |
| T-M1-51 | 后台与锁屏：按键录音停止后自动同步 | 前台、后台、锁屏各 3 次，均在 10 s 内开始同步 |
| T-M1-52 | 断线恢复：同步中把卡带离到断开，再带回 | 自动重连并完成同步；不重复、不丢失 |
| T-M1-53 | 长录音：≥ 30 分钟的录音蓝牙同步 | 完成；吞吐与基线（约 24 KB/s）偏差 ≤ 20% |
| T-M1-54 | 暂停与继续 | 可用则验证录音连续；不可用则确认界面已隐藏 |
| T-M1-55 | 多卡回归（#8）：至少 3 张卡跑 T-M1-50 | 每张卡记录 sn 哈希与固件版本；有差异逐项列出 |
| T-M1-56 | 从上一个 TestFlight 构建升级 | 录音、设备、配对保留；数据库迁移成功 |
| T-M1-57 | 设置项真机生效：逐项切换后用 `0x81` 读回 | 读回值与设置一致（同时验证 `0x81` 字段，`prd.md` §9） |

### 3.5 不做不可逆变更（§7.1 第 6 条）

三道检查，任一不过即不能发版：

1. **静态**：T-M1-01；CI 里搜索源码中 `0x93`、`0x94`、`0xB0`、`0xB1` 的字面量，出现即失败（测试代码中的白名单断言除外）。
2. **运行时**：模拟卡记录所有写帧，所有集成用例结束时断言其中没有这四个命令字。M1.5 新增的同步用例（T-M15-06～08）同样断言。
3. **真机**：T-M1-50 全程开启协议日志，检查写帧。

### 3.6 M1.5 用例（#70）

范围是 `features.md` 的 D1b、E1b、X6～X10，加界面改版第一步（#74）。页面和文案以 `product-spec.md` 1.2 为准。**以下真机用例都还没有执行**；自动用例在 CI 上跑。`evidence/v79-sync-retry/` 的真机记录里顺带点过一次「留着」、打开过一条已有文字稿的录音，那是 #79 的观察，不算这里任何一条用例的结论。

#### 3.6.1 自动用例（单元与模拟卡集成）

| 编号 | 用例 | 通过线 |
|---|---|---|
| T-M15-01 | D1b 最近删除（库）：移入、恢复、到期清除 | 移入后行和音频都在，启动恢复不把音频当孤儿删掉，仍算本机副本；恢复后 `trashed_at` 为空；截止时间早于删除时间时清除 0 条，等于删除时间时清除 1 条；清除后行和音频都没有；SyncItem 仍是 `stored`、不再关联录音，不会重新下载 |
| T-M15-02 | D1b 首页删除与撤销 | 列表里消失；Toast「已移到最近删除」带「撤销」；没有新的 `0x91`，卡上文件还在；音频在最近删除里；撤销后回到列表，Toast「已恢复」，最近删除为空 |
| T-M15-03 | D1b 详情页删除 | 页面标记为已删除并关闭；播放器停止；录音的 `trashed_at` 非空（仍在库里） |
| T-M15-04 | X6 重命名 | 去掉首尾空白（「  周会  」→「周会」），算改过名；200 字截成 80 字；全空白恢复为默认标题，不算改过名；不存在的 id 返回空；详情页显示新标题，`editableTitle` 在默认标题时为空 |
| T-M15-05 | X7 重点按卡上文件记 | 录音入库前就能记；2 s 内的第二个被丢弃；按位置排序；入库后只返回不超过录音时长的；删除一个后少一个；没有卡上来源的录音没有重点 |
| T-M15-06 | X10 同步前选了「不要」 | 两个文件都入库，「不要」的那条 `trashed_at` 非空、音频在；只有这一个文件被删，且它的下载请求在删除请求之前；它的 SyncItem 为 `deletedOnCard`、请求已清除；另一个仍是 `stored`；「同步后删除」关着；没有禁发命令 |
| T-M15-07 | X10 已入库后「不要」，再撤销 | 请求后录音进最近删除、SyncItem 为 `deletePending`；撤销后回到列表、SyncItem 回到 `stored`，下一轮同步不发 `0x91`；再请求一次不撤销，下一轮删除卡上文件，手机上那份在最近删除里；卡上删完后撤销返回 false |
| T-M15-08 | X10 手机上没有这份时不删卡（硬规则 2） | 请求后把录音彻底删除，再同步：不发 `0x91`，卡上文件还在 |
| T-M15-09 | E1b 导出 M4A | 文件名「2026-11-01 09.00.m4a」；系统能读出时长，与 2 s 相差 < 0.2 s；导出目录里只剩这个文件；音频丢失时报 `audioMissing`。文件名规则（冒号换点、非法字符换 `_`、全空白用 `recording`）另有参数化用例 |
| T-M15-10 | X9 本机转写的页面状态（假识别器） | 开关关时不能转写；转写后存入，重新打开页面能读到；时间显示「00:00:01」；失败时 Toast「这部手机不支持离线识别这种语言」，之前的文字稿保留；删除录音时文字稿一并删除 |
| T-M15-11 | X9 分句 | 句末标点断句；停顿超过 1.2 s 断句；没有标点时满 60 字断句；拉丁词之间才加空格；空输入没有句子 |
| T-M15-12 | #66 Opus 帧头（TOC）解析 | 各字段解析正确，32 种配置都能解；只接受「一包一帧、20 ms、单声道」；60 ms、立体声、一包多帧都拒绝；随机字节不通过；系统编码器按卡的参数产生的包通过。与 `client/tests/test_opus_toc.py` 同一组用例 |
| T-M15-13 | X9 不联网（静态） | `scripts/check-m1-rules.sh` 的不联网检查覆盖 `Transcription` 模块；CI 通过 |
| T-M15-14 | 迁移 `v3`～`v5` | 新建数据库时所有迁移都已应用，外键开启 |
| T-M15-15 | 界面颜色只来自 `Theme`（#74） | `scripts/check-theme.sh` 在 `app/Revive/` 下（`Common/Theme.swift` 和 `Debug/` 除外）找不到具体颜色值、被 `Theme` 取代的系统背景和填充、黑色阴影和彩色淡底；系统警告色 `.red`、`.orange` 允许；CI 通过 |
| T-M15-16 | X21 星标（库与页面状态） | 标星记下时间，再标一次不改时间；取消后为空；不存在的 id 返回空；移入最近删除再恢复后星标还在；详情页「标星」「取消星标」的 Toast 分别是「已标星」「已取消星标」；首页右滑标星后「星标」筛选只列这一条，取消后为空 |
| T-M15-17 | 迁移 `v7` | `v6` 的库升级后 `recording` 多出 `starred_at`，原有录音都未标星，纪要和待办保留；从 `v1` 一路升到最新时所有迁移都已应用 |
| T-M15-18 | #89 跨录音的待办与纪要 | 只列未勾的待办，录音新的在前、同一条按纪要顺序；最近删除里的不列；「最近整理好的」按纪要生成时间倒序、`limit` 生效、没有纪要的录音不列；没转文字的条数不含最近删除，存入文字稿后减一；「有待办」筛选在待办勾完后不再列这条 |
| T-M15-19 | #89 总览页状态 | 待办超过 5 条时只列前 5 条，并显示「还有 N 件，在各条录音的纪要里」；勾掉一条后 Toast「已完成」，列表和「还有」随之更新，纪要里对应待办已勾；「还有 N 条没转成文字」在存入文字稿后消失 |
| T-M15-21 | #85 标重点、留着 / 不要（页面状态） | 没在录音时标重点 Toast「现在还不能标重点」；录音中 2 s 内点两次只记一个，入库后列表行计 1；「不要」先存入、再进最近删除并删卡上文件，Toast「这条不会保留」带「撤销」，撤销后回到列表；10 s 不理当作留着，最近删除为空、卡上文件还在 |
| T-M15-22 | #85 断开期间结束的录音 | 录音中断开，卡上停止（推送丢失）后重连：补问「留着 / 不要」，时长未知；重连时仍在录：重连当时不问，停止后问一次且带时长 |
| T-M15-23 | #85 通知文案、转写开关、导出文件名 | 只计这一轮新存的卡上录音（不含最近删除、导入）；只有一条时带它的 id，多条时不带；转写开关在打开的 P06 上立即生效；导出文件名按页面显示的标题（「11月7日 14.02.ogg」，改名后用新名字） |
| T-M15-20 | #89 列表按天分组的合计、正在播放的句子、外观 | 组标题「今天」「昨天」「3月2日」「2025年11月7日」；合计「2 条 · 1 小时 6 分钟」；正在播放的句子是起点不晚于当前位置的最后一句，第一句之前和没有句子时为空；详情页开始播放某句后，当前句就是这一句；外观默认跟随系统，选择后重新读取仍是所选 |
| T-M15-24 | 先不连卡（P01，2026-11-20） | 选择存进偏好，重开仍在，可清掉；`NoCardLink` 状态是 `idle`，不连接、不写；在它上面的 `HomeModel` 没有当前卡、状态是 `noDevice`（不是 `bluetoothUnavailable`），导入的文字文件照常进列表；什么时候创建蓝牙：没配对、没有蓝牙、iOS 没问过时，启动和标签栏都不创建（不弹权限框）；有卡、系统为卡重新启动、已允许时启动就创建；标签栏在已有蓝牙、有卡或 iOS 已经回答过（允许或拒绝）时用真实蓝牙；有卡或选过「先不连卡」时显示标签栏 |

实现：

| 编号 | 测试 |
|---|---|
| T-M15-01 | `Tests/LibraryTests/AppDatabaseTests.swift` `trashRestoreAndPurge` |
| T-M15-02 | `Tests/AppModelTests/HomeModelTests.swift` `deleteRemovesRowWithoutTouchingTheCard` |
| T-M15-03 | `Tests/AppModelTests/RecordingDetailModelTests.swift` `playSkipPauseThenDelete`（后半段） |
| T-M15-04 | `AppDatabaseTests` `renameRecording`；`RecordingDetailModelTests` `playSkipPauseThenDelete`（中段） |
| T-M15-05 | `AppDatabaseTests` `marksFollowTheCardFile` |
| T-M15-06 | `Tests/SyncEngineTests/SyncEngineTests.swift` `discardedFileIsStoredThenTrashedThenDeletedFromCard` |
| T-M15-07 | `SyncEngineTests` `discardAfterStoreAndUndo` |
| T-M15-08 | `SyncEngineTests` `discardNeverDeletesWithoutALocalCopy` |
| T-M15-09 | `Tests/PlayerTests/PlayerTests.swift` `exportsM4A`、`exportM4AReportsMissingAudio`、`fileNames` |
| T-M15-10 | `RecordingDetailModelTests` `transcribesStoresAndReportsFailures` |
| T-M15-11 | `Tests/TranscriptionTests/TranscriptGrouperTests.swift`（5 个） |
| T-M15-12 | `Tests/CardProtocolTests/OpusTOCTests.swift`（7 个） |
| T-M15-13 | `scripts/check-m1-rules.sh`（CI 第一步） |
| T-M15-14 | `AppDatabaseTests` `inMemoryDatabaseOpensAndMigrates` |
| T-M15-15 | `scripts/check-theme.sh` |
| T-M15-16 | `AppDatabaseTests` `starRecording`；`RecordingDetailModelTests` `playSkipPauseThenDelete`（标星段）；`HomeModelTests` `filtersByMarksAndTranscripts`（星标段） |
| T-M15-17 | `AppDatabaseTests` `v6LibraryUpgradesToV7`、`v1LibraryUpgradesToTheLatest` |
| T-M15-18 | `AppDatabaseTests` `openTodosAndRecentSummaries`；`HomeModelTests` `filtersByMarksAndTranscripts`（有待办段） |
| T-M15-19 | `Tests/AppModelTests/OverviewTests.swift` `OverviewModelTests` |
| T-M15-21 | `HomeModelTests` `marksFollowTheRunningRecording`、`discardStoresThenTrashesAndDeletesFromCard`、`unansweredOfferKeepsTheRecording` |
| T-M15-22 | `HomeModelTests` `recordingThatEndedWhileAwayIsOfferedOnReconnect`、`recordingStillGoingAfterReconnectIsOfferedWhenItStops` |
| T-M15-23 | `SyncNoticeTests`；`RecordingDetailModelTests` `transcriptionSwitchAppliesToAnOpenPage`、`exportsUnderTitle` |
| T-M15-20 | `OverviewTests` `RecordingDayTests`、`TranscriptPositionTests`、`AppearanceTests`；`RecordingDetailModelTests` `transcribesStoresAndReportsFailures`（当前句段） |
| T-M15-24 | `Tests/AppModelTests/CardlessTests.swift`（2 个）、`Tests/CardLinkTests/NoCardLinkTests.swift`、`Tests/AppModelTests/BluetoothStartTests.swift`（4 个） |

**没有自动用例覆盖的部分**（代码已合并，靠 §3.6.2 和界面走查）：

- 本地通知的投递和点按跳转（`SyncNotifier`、`NotificationRouter` 在 App 目标里；文案和带哪条录音由 T-M15-23 覆盖）
- `TrashModel` 的剩余天数文字（「还剩 N 天」「今天到期」）、清空
- 真实的系统语音识别 `OnDeviceTranscriber`（T-M15-10 用的是假识别器）
- 从 `v2` 的旧库升级到 `v5` 的迁移（现有升级用例只到 `v2`）；真机上随 T-M1-56 一起验
- 录音页 P13 的自动打开和关闭
- #89 的界面层：底部标签栏和录音键的三种状态、各标签各自的导航栈、P06 三栏和「⋯」、文字稿跟随滚动与「减弱动态效果」、标签与人物的换行排布、P07 作为标签根页面、外观对整个 App 生效。靠 `product-spec.md` §9 的 1.3 检查项和 T-M15-59

#### 3.6.2 真机用例

每条按 §4 留证据，目录 `evidence/v70-<用例序号>/`（如 `evidence/v70-52/`）。测试前先按 §4 末尾用 `client/dnote.py pull` 备份卡上录音。通过线是二值的：全部满足才算通过。

| 编号 | 用例 | 步骤 | 通过线 |
|---|---|---|---|
| T-M15-50 | 卡上那份已删后，从最近删除恢复 | ① P07 打开「同步后删除」，录一条 ≥ 30 s 的录音并等它同步；② `python dnote.py list` 确认卡上已没有这个文件；③ 在 P05 删除这条，再到 P14 恢复；④ 播放、导出 OGG；⑤ 再删除一次，在 P14「彻底删除」后下拉刷新 | ③ 后这条回到列表，标题、时长不变；④ 能完整播放，导出的 OGG 的 sha256 与删除前导出的一致；⑤ 后列表里没有它，下拉刷新后也没有重新出现，协议日志里没有新的 `0x70` 下载 |
| T-M15-51 | M4A 在微信和「文件」里能打开 | ① 选一条 ≥ 5 分钟的真实录音，分享 →「M4A（微信等大多数 App 可播放）」；② 发到微信「文件传输助手」，在另一台手机（iOS 和安卓各一台，有就测）的微信里点开；③ 存到「文件」App 后点开；④ 在电脑上 `ffprobe` 读时长 | ② ③ 都能直接播放、有声音、能拖动进度；④ 时长与 App 显示的时长相差 ≤ 1 s；记录导出耗时和文件大小 |
| T-M15-52 | 重点落在说话的那一刻（含暂停） | ① App 里开始录音；② 在第 10 s、第 60 s 各说一句「标记一」「标记二」并同时点「标重点」；③ 暂停 ≥ 20 s 再继续；④ 继续后约 30 s 说「标记三」并点「标重点」；⑤ 停止、同步，在 P06 逐个点重点播放；另做一遍用卡上按键开始录音 | 每个重点开始播放的位置与对应那句话的开头相差在 ±2 s 内（在电脑上看波形或听，记下每个的差值）；暂停之后的「标记三」同样在 ±2 s 内；两种开始方式都满足 |
| T-M15-53 | 录音中报的文件名等于同步后的文件名（X7、X10 的前提） | ① App 里开始录音，记下录音中卡报的文件名（卡上按键开始时诊断日志有 `recording started <名>`；App 开始时取 `0x51` 回包，用 DEBUG 构建的协议日志看）；② 停止；③ `python dnote.py list` 和 App 同步后的 `card_file_name` 对照；④ 用卡上按键再做一遍；⑤ 录音中断开连接再重连，再做一遍（重连后的文件名来自 `0x56`） | 三种情况下，录音中拿到的文件名与卡上列表、同步后的记录逐字一致；不一致时 X7 的重点和 X10 的「不要」都会对不上，X7、X10 不能验收 |
| T-M15-54 | 「不要」只在手机有这份之后删卡（硬规则 2） | ① 「同步后删除」保持关；② 录一条，停止后点「不要」；③ 同步完成前、完成后各跑一次 `python dnote.py list`；④ 在 P14 找到这条并播放；⑤ 另录一条，点「不要」后在 5 s 内点「撤销」，同步后再 `list`；⑥ 再录一条，点「不要」后立即把卡带离到断开，等 1 分钟再带回 | ③ 同步完成前卡上还有这个文件，完成后没有；协议日志里这个文件的 `0x70` 下载在 `0x91` 之前；④ 能完整播放；⑤ 卡上文件还在，列表里有这条；⑥ 断开期间卡上文件还在，重连同步后才删；全程没有其他文件被删 |
| T-M15-55 | 后台同步后的通知 | ① P09 打开「同步完成时通知」并允许；② App 退到后台、锁屏，各按卡上按键录一条 ≥ 30 s 的再停止；③ 再做一遍但 App 在前台；④ 在系统设置里关掉闻笺的通知，再做一遍后台 | ② 后台、锁屏各 3 次，每次在同步完成后出现「录音已同步」/「1 条新录音已存入手机」，记下从停止到通知的时间；③ 前台时不出现通知；④ 不出现通知，App 不崩溃 |
| T-M15-56 | 本机转写：5 分钟和 30 分钟真实录音，飞行模式 | ① 开飞行模式（蓝牙可开）；② P09 打开「本机转写（试验）」；③ 对一条约 5 分钟、一条 ≥ 30 分钟的多人中文录音点「转成文字」，计时；④ 转写期间锁屏一次再解锁 | 记录：每条耗时、是否完成、手机型号和 iOS 版本、识别出的字数。通过线：两条都完成（出现文字稿或明确的失败 Toast，不卡死、不崩溃），文字稿每句的时间点击后跳到的位置与那句话相差 ≤ 3 s（抽查 5 句）；全程抓包无网络请求。字错率不在本用例判定，交给 #67 |
| T-M15-57 | 浅色、深色模式的界面走查 | 按 `product-spec.md` §9 的「M1.5 和改版第一步」逐项，在浅色、深色两种模式下各走一遍，对照 `design-spec.md` §2、§3 截图 | 每项都有截图；颜色与 `design-spec.md` §2.1 的变量一致；正文对比度 ≥ 4.5:1（用取色工具量 `ink`/`inkMuted` 与 `paper`/`surface`）；P13 在浅色模式下也是深色底；`product-spec.md` §7.5 第 7 条列的未实现部分不算失败，但要在截图里标出 |
| T-M15-58 | Opus 帧头真机统计（#66） | 按 `evidence/v66-opus-toc/README.md`：用 `pull` 留下的 `.raw` 跑 `python dnote.py toc`，输出存为 `toc-v1.50.txt`；样本至少 3 个文件（1 分钟以内、30 分钟以上、按键发起各一条；至少一条有人说话、一条基本安静）；#8 的其他卡各取一条 | 每个文件都是 `matches 20 ms mono: yes` 才算通过；有 `NO` 时按该 README 的判据表分情况处理，结论写进 README。注意 `backend-design.md` §7.2 H2 记录实时流里见过 TOC `0x4b`，它的帧数码是 3，而现行检查（Swift `OpusTOC.isCardFormat` 和 Python `opus_frames_match_card_format`）只接受帧数码 0；文件里若也出现 `0x4b`，会被判为不符，按判据表第 2 行处理 |

| T-M15-59 | #89 界面走查与截图 | ① 在 Mac 上跑 `scripts/shots.sh`（模拟器，示例数据，不连卡）；② 真机上连卡，按 `product-spec.md` §9「界面改版第二步」逐项走一遍，浅色、深色各一遍；③ 走查时打开「减弱动态效果」和最大号动态字体各一次 | ① 浅色、深色各 7 张截图都生成，放进 `evidence/v89-ui/` 并与改版稿并排；② 每项都有截图或录屏；③ 文字稿播放时不滚动但仍高亮，标签和人物换行、没有单字竖排；全程没有 App 崩溃 |

| T-M15-60 | 先不连卡（P01，2026-11-20） | 删掉 App 重装，不配对卡，按 `product-spec.md` §9「先不连卡」逐项：P01 点「先不连卡，直接用」后**不弹**蓝牙权限框；手机录音、导入、本机转写可用；「添加录音卡」回到 P01，点「继续」后才弹权限框，配对后录音都在；重启后直接进入标签栏；拒绝蓝牙时也能进入。通过线：蓝牙权限框只在点「继续」之后出现（录屏为证） |

T-M15-50、54 会删除卡上文件，只用测试录音，不用有价值的录音。T-M15-56 的录音音频不入库，只记 sha256（硬规则 4）。

#### 3.6.3 M2 先做的部分（用户自配服务）

| 编号 | 用例 | 通过线 |
|---|---|---|
| T-M2-01 | G1、X6 AI 标题（库） | 空标题不改；AI 标题替换默认标题和上一个 AI 标题；改名后标为用户的，AI 标题不替换，除非明确要求；改名留空回到时间标题、来源为空；`v9` 前改过名的行仍算用户的；`v8` 升到 `v9` 后原有行来源为空 |
| T-M2-02 | G1、G2a 页面状态 | 生成纪要后默认标题换成纪要标题；用户改过名时保留用户的；按指定场景重新生成后场景是所选的；「让 AI 重新起标题」替换用户标题并 Toast「已换成「…」」；新标题的回复解析（JSON 的 `title`、单行文字、去引号、最多 30 字、空标题报错） |

| T-M2-03 | G1 大纲、金句、思维导图 | 回复里的大纲按顺序读出，最多 8 个话题、每个 6 条，空标题的话题丢掉；金句最多 5 句、去掉引号；没有这两项的回复照常解析；存取往返不变，搜索能搜到大纲和金句里的词；`v9` 的纪要升到 `v10` 后两项为空、其余不变；Markdown 导出有「大纲」「金句」两节 |

| T-M2-04 | 纠错词库（#75） | 「汇款率…」改成「回款率…」记下「汇款→回款」；单字差异向后补字成「张经→章经」，句末向前补成「老王→老汪」；单字整句、纯插入、纯删除、整句改写不记；替换时长词优先；越界、空文字不改；之后新转写的文字稿已改正；删除后不再替换；`v10` 升到 `v11` 后有 `correction` 表 |

| T-M2-05 | 转写剩余时间（#75） | 没测过时按本机 0.5、服务 0.15（秒工作 / 秒音频）估计；成功的一次按 0.6 旧值 + 0.4 实测更新，本机和服务分开；失败的不更新；剩余时间不小于 0；文案「预计还要 N 分钟」（向上取整）、「预计还要不到 1 分钟」、「快好了」；同一条不能同时开两次 |

| T-M2-06 | 逐句润色（#75） | 每批 40 句、请求带 `json_object`；回复句数对上时逐句替换，回显的「3. 」序号去掉（原句本身以序号开头时保留）；某一批对不上时那一批保持原文、Toast 说明有几句没能润色；全部对不上报「润色后的句数对不上」；没有句子不发请求、没设置服务不发；库：时间不变、空的一句保留原文、再次润色保留第一次的原文、恢复原文后与转写结果一致；`v11` 升到 `v12` 后原有文字稿 `original_segments` 为空；页面：没设置服务时不能润色，润色后 Toast「已润色，可以随时恢复原文」，恢复后 Toast「已恢复原文」 |

| T-M2-07 | G1 职业设定 | 空白职业时提示词不变；有职业时加一句「用户的职业是「…」」，写明职业只影响顺序和说法、每条都要在文字稿里找得到原话、不写「没有异议」这类推断（v105 真机发现模型补了「没有提出异议」），最多 40 字；生成纪要的请求带上它；设置页保存成一行、截到 40 字，重开还在，清除服务不清职业 |

| T-M2-08 | #85 密钥只留在本机 | 钥匙串项的可访问性是 `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`；旧版本存下的项在读取时改成这个属性（真机：升级后打开 AI 服务页，密钥仍在；用加密备份恢复到另一台手机后，密钥为空） |
| T-M2-09 | X22 录完自动整理 | 默认关，新录音不转写；打开后新存入的录音依次转写、生成纪要、换上纪要标题，打开前已有的不动；没有服务时只转写；文字录音只整理不转写；失败的同一次运行里不再试；关掉再打开从新的时间算起。实现：`AutoProcessorTests`（真机：开着开关录一条，同步后不点任何按钮，详情页出现文字稿和纪要） |

| T-M2-10 | X11 没有网络或关了「无线数据」 | `notConnectedToInternet`、`dataNotAllowed`、`internationalRoamingOff` 报 `offline`，其余网络错误（连不上主机、超时、找不到主机、TLS）仍是 `unreachable`；整段和流式请求都一样；用自配服务转文字时同样报 `offline`，不报「转写失败，请重试」；设置页「测试」和各处 Toast 显示「这部手机连不上网，请检查网络或「设置 › 闻笺 › 无线数据」」（真机：系统设置里把闻笺的「无线数据」设为关闭，录音卡、录音、同步、播放、导出照常；生成纪要、转成文字时出现这句提示；打开后再试能用。iOS 在这种情况下报的是不是 `-1009` 只能真机确认） |

实现：T-M2-10 是 `ChatClientTests` `noConnectionIsOffline`、`onlyConnectionErrorsCountAsOffline`，`CloudTranscriberTests` `noConnectionIsOffline`，`AssistantSettingsModelTests` `errorsReadAsAdvice`，`RecordingDetailModelTests` `transcribesStoresAndReportsFailures`；「无线数据」关闭时 iOS 报哪个错误只能在真机上验证。T-M4-10 另有 `PolishAndLoopTests` `regeneratedSummaryKeepsADeletedTagOut`；T-M4-11 另有 `StreamTests` `streamWithoutAnEndIsCutOff`、`streamThatStopsEarlyThrows`。T-M2-08 是 `KeyStoreTests` `keychainKeyStaysOnThisDevice`（属性值）；读取时改属性、备份恢复后为空只能在真机上验证。T-M2-07 是 `SummarizerTests` `promptMentionsTheProfession`、`shortTranscriptIsOneRequest`，`AssistantSettingsModelTests` `professionIsSavedWithTheService`。T-M2-06 是 `PolisherTests`（4 个）、`AppDatabaseTests` `polishingKeepsTimesAndTheOriginal`、`v11LibraryUpgradesToV12`，`PolishAndLoopTests` `polishesAndRestores`。T-M2-05 是 `TranscriptionJobsTests`。T-M2-04 是 `AppDatabaseTests` `correctionsAreShortWordSwaps`、`editingALineLearnsTheCorrection`、`v10LibraryUpgradesToV11`，`RecordingDetailModelTests` `correctedWordsFixLaterTranscripts`。T-M2-03 是 `SummarizerTests` `readsOutlineAndQuotes`、`AppDatabaseTests` `summaryIsStoredAndFollowsTheRecording`、`v9LibraryUpgradesToV10`、`MarkdownExportTests`。T-M2-01 是 `AppDatabaseTests` `aiTitlesNeverReplaceTheUsersTitle`、`v8LibraryUpgradesToV9`；T-M2-02 是 `RecordingDetailModelTests` `summarizesWithTheUsersServiceAndTicksTodos`、`aiTitleKeepsTheUsersTitleUnlessAsked`，`SummarizerTests` `readsANewTitle`。

#### 3.6.4 M4 先做的部分

| 编号 | 用例 | 通过线 |
|---|---|---|
| T-M4-01 | D1c 文件夹（库） | 空名字不建；名字去首尾空白；按名字排序；移入、移出、改名（空名字不改）；删除文件夹后录音还在、不在任何文件夹里；`v7` 的库升级到 `v8` 后有 `folder` 表，原有录音不在文件夹里、星标保留 |
| T-M4-02 | D1c 文件夹（页面状态） | 列表的文件夹筛选叠加在筛选项之上；删除文件夹后 Toast「已删除文件夹，里面的录音还在」、筛选取消、录音都回到列表；详情页「移到文件夹」可新建并移入、换文件夹、移出，Toast 分别是「已移到「名字」」「已移出文件夹」 |

| T-M4-03 | G3 全局对话 | 回答里的 [n] 只取存在的编号、按首次出现排序（支持「[1，3]」）；资料按编号排列，超出上限的不发、第一条总会发（截断）；只发纪要，问题在末尾；没有纪要报错；没设置服务时不发请求；页面状态：和问题共有词语的较早纪要排在 [1]，回答引用 [1] 时列出它；空问题不发；清除后回答为空。挑选（`QuestionSourcesTests`）：中文按两字切分、去掉「什么」「时候」等问法用词，英文和数字按词、不分大小写；命中多的在前，同样多时新的在前，余下用最新的补足，总数不超过上限；没有可匹配的词或都不命中时就是最新的几条 |

| T-M4-04 | X15、#75 回复的 Markdown | 「** 重点 **」整理成「**重点**」；标题行变粗体；不成对的 `**` 去掉；空粗体去掉；渲染后看不到星号，粗体范围正确 |

| T-M4-05 | D1c 按来源筛选 | 只有一种来源时没有来源筛选项；有卡录音和手机录音时依次给出「录音卡」「手机录音」；选来源后只列这一来源，叠加星标等筛选；非卡录音的副标题末尾是「· 手机录音」或「· 导入」 |

| T-M4-06 | X20 单句循环 | 一句的范围是从它的开头到下一句开头，最后一句到录音结束，越界或长度为 0 不循环；播到范围末尾（含 1.5 秒内的超出）或播完时回到这句开头；位置远离这句时停止；页面：循环第一句时播过下一句开头后回到开头；再点同一句、点另一句播放、拖动进度或快进快退都停止循环；暂停不停止循环 |

| T-M4-07 | E1c 导出 WAV | 文件名是显示的标题加 `.wav`；文件头是 `RIFF…WAVE`，16 位线性 PCM，时长与录音相差不到 0.2 秒；导出目录里只剩这个文件；手机录音（M4A）同样能导出 WAV |

| T-M4-08 | J1 导出 PDF | 页面是 A4；能从 PDF 里读出标题、日期时间、场景、人物、摘要、栏目、待办、大纲、金句、文字稿和它的时间；文档标题是纪要标题；300 句的文字稿分成多页，第一句和最后一句都在；详情页导出的文件名是显示的标题加 `.pdf`，内容以 `%PDF-` 开头 |

| T-M4-09 | P08 上次同步 | 同步完整跑完后这张卡的 `last_synced_at` 有值且不早于 `last_seen_at`，P08 副标题是「已连接 · 上次同步 …」；未知的卡不写；`v12` 升到 `v13` 后原有的卡 `last_synced_at` 为空 |

| T-M4-10 | D1c 标签管理 | 详情页重新生成纪要后显示的标签已按规则处理（v105 真机发现删掉的标签重新出现在页面上）；条数不含最近删除，按条数从多到少、同条数按名字；按标签列录音新的在前；改名去掉空白和 `#`，空名字、同名不改；改成已有的名字时合并为一个；改名接力（A→B→C 后再来的 A 变成 C）；删除后之后的纪要也不带它；改回被改掉的名字后，那个名字的规则作废；`v13` 升到 `v14` 后有 `tag_rule` 表；页面：Toast「已改名为「…」」「已并入「…」」「已删除标签「…」，录音还在」，删除后录音还在 |

| T-M4-11 | G3 流式回复 | 读 `data:` 事件的 `delta.content`，跳过注释行、空行、只有角色的事件，`[DONE]` 后不再读；没有 `[DONE]` 也没有 `finish_reason` 就结束的流算中断并报错（v105 真机断网后显示「完成」）；流式请求静默 60 秒即超时；事件里带错误时报出服务的错误；服务不支持流式、整段返回 JSON 时一次给出全文，看不懂的内容报错；`<think>` 部分不显示，没结束的思考截掉；请求带 `stream: true` 和 `Accept: text/event-stream`；401 等错误码照常报；没设置服务时不发请求；页面：改写后 Sheet 立刻打开（空、接收中），收完后显示正文、不是接收中，关掉后清空；知识库提问后立刻有回答（空、接收中），收完后列出引用的录音，`answerStream` 发的消息与整段请求相同 |

| T-M4-12 | J1 思维导图 | OPML 2.0，录音标题是根，话题和要点按顺序嵌套，没有要点的话题是单个节点；`&`、`<`、`>`、`"` 转义；XML 解析器能读完；没有大纲时不提供；文件名按页面标题，扩展名 `.opml` |

| T-M4-13 | X20 难句解析 | 只发这一句和前后各一句（没有就不写），系统提示是解释用的；页面：越界不发请求，Sheet 标题「解释这一句」，收完显示回复 |

| T-M4-14 | J1 导出 Word | ZIP 的 CRC-32 与标准校验值一致；包里只有内容类型、包关系、`word/document.xml` 三项，都不压缩，每项 CRC 正确，结束记录指向中央目录；正文有标题、日期时间 · 时长 · 场景、人物、摘要（换行变 `<w:br/>`）、栏目、待办、大纲、金句、文字稿和时间，`&` `<` `>` 转义，控制字符去掉；A4 页面；三个 XML 都能解析；详情页导出的文件名是标题加 `.docx`，以 `PK\3\4` 开头 |

| T-M4-15 | X20 单词分级 | 等级宽松读取（「 b2 」「C1 高级」），读不出的丢掉；空词、行号越界的丢掉，行号可以是字符串；只发含拉丁字母的句子并在批内编号，词放回文字稿的原句，同一个词只留一次，按出现先后；全是中文时不发请求；读不懂的回复报错；外语判断（拉丁字母多于其他且至少 20 个）；库：存取、替换、随录音删除，`v14` 升到 `v15` 后有 `word_list`；页面：没设置服务时不提供，列出后 Toast「找到 N 个生词」、按等级从高到低分组、按最低等级筛选、重开页面还在，点词从那句播放 |

| T-M4-16 | E2 文字文件 | 段落成为文字稿（CRLF、空行、首尾空白去掉），长段落在句末断开、没有句末时每 200 字断开，时间都是 0；UTF-8（含 BOM）、UTF-16、GB 18030 都能读；空文字不建录音；建出的录音没有音频、时长 0、来源「导入」，能被搜索；`removeAudio` 对空路径、`audio/`、含 `..` 的路径什么都不删，删除文字录音不影响其他音频；播放、导出原始文件、M4A、WAV、解码都报 `audioMissing`；详情页：没有音频、不算找不到音频、不能转写，时长「文字」，播放和循环都不动，导出原始文件为空但 Markdown 照常；列表副标题以「文字 · 导入」结尾；从「文件」导入一个 .txt 和一个空 .md，Toast「已导入 1 个，1 个无法识别」 |
| T-M4-17 | X18 手机录音被打断 | 录音中收到打断：状态变成已暂停，带上原因；不在录音时、已经暂停时不变；自己点暂停不带原因（真机：来电接听再挂断，页面是「已暂停」和打断说明，「继续」后接着录，来电前后的话都在） |
| T-M4-18 | X18 录音中 App 被关掉 | 文件名带开始时间（毫秒），读得回来，别的名字读不出；数据块大小未知（`-1`）、最后一个样本只写了一半的 CAF 能存成 M4A 录音，开始时间按文件名、时长约 1 s、来源是手机，CAF 删掉，Toast「找回了 1 条…」，再跑一次不重复；读不了的改名 `.unreadable` 保留、不进列表、不提示；没有声音的删掉（真机：录音中从后台划掉闻笺，再打开时找回，能播放；30 分钟以上的录音停止后能存好） |
| T-M4-19 | X7 手机录音的重点 | 没在录音时不能标，Toast「现在还不能标重点」；2 秒内的第二次不算；标记写在 CAF 旁边，App 被关掉后找回的录音带着标记，旁边的文件随后删掉；库：和录音在同一事务里存入，去重、按时间排、超过时长的不显示，不算卡的标记；「有重点」筛选算它；删除录音后标记随之删除；`v15` 升到 `v16` 后有 `phone_mark` 表（真机：录音中标两处，存入后在详情页能点着播放） |
| T-M4-20 | X18 手机录音的存储空间 | 不到 100 MB 时不开始、不请求麦克风权限，Toast 说明，`phone/` 里不留文件；录音中或暂停时不到 30 MB 算空间不足，正好 30 MB 和不在录音时不算（真机：空间快满时自动停止并保存，页面关闭，录音能播放到结尾） |
| T-M4-21 | X18 手机录音意外中断 | 不在录音时收到录音器失败（包括我们自己停止后的回调）不改变任何状态、不提示、不存录音（真机：录音中在开发者设置里重置媒体服务，录到的部分被保存，页面关闭，Toast 说明） |

实现：T-M4-21 是 `PhoneRecorderTests` `failureWhenNotRecordingChangesNothing`；录音中失败的那一半要麦克风，只能真机验证。T-M4-20 是 `PhoneRecorderTests` `startNeedsRoom`、`lowSpaceOnlyMattersWhileRecording`；每 10 秒的检查和自动保存只能真机验证。T-M4-19 是 `PhoneRecorderTests` `marksAreKeptThroughRecovery`，`AppDatabaseTests` `phoneMarksStayWithTheRecording`、`v15LibraryUpgradesToV16`。T-M4-17 是 `PhoneRecorderTests` `interruptionPausesAndSaysWhy`、`pausingByHandIsNotAnInterruption`，通话打断只能真机验证。T-M4-18 是 `PhoneRecorderTests` `fileNameCarriesTheStartTime`、`cutOffRecordingIsStoredNextTime`、`unreadableLeftoverIsKeptAndNotRetried`、`emptyLeftoverIsRemoved`；`AVAudioRecorder` 被杀掉时留下的 CAF 是否真的可读，只能真机验证。T-M4-16 是 `TextImportTests`（4 个）、`PlayerTests` `textRecordingHasNoAudioToPlayOrExport`、`PolishAndLoopTests` `textOnlyRecordingHasNoAudio`、`HomeModelTests` `importsTextFilesAsRecordingsWithoutAudio`。T-M4-15 是 `WordGraderTests`（4 个）、`AppDatabaseTests` `wordListFollowsTheRecording`、`v14LibraryUpgradesToV15`，`PolishAndLoopTests` `listsWordsByLevel`。T-M4-14 是 `DOCXExportTests`（2 个）、`RecordingDetailModelTests` `exportsUnderTitle`。T-M4-13 是 `RewriterTests` `rewriteAndAnswerSendTheRightPrompts`、`PolishAndLoopTests` `explainsALine`。T-M4-11 是 `StreamTests`（6 个）、`RewriterTests` `rewriteAndAnswerSendTheRightPrompts`、`LibraryAskerTests` `answersWithItsCitationsAndSendsOnlySummaries`、`LibraryQuestionModelTests`、`PolishAndLoopTests` `rewriteOpensTheSheetAndFillsIt`。T-M4-12 是 `MindMapExportTests`、`PolishAndLoopTests` `exportsTheMindMap`。T-M4-10 是 `AppDatabaseTests` `tagsRenameMergeAndDeleteAcrossSummaries`、`v13LibraryUpgradesToV14`，`TagsModelTests`。T-M4-09 是 `HomeModelTests` `lastSeenFollowsEachPass`、`AppDatabaseTests` `markSyncedStampsTheCard`、`v12LibraryUpgradesToV13`。T-M4-08 是 `PDFExportTests`（2 个，只在 macOS 上跑）、`RecordingDetailModelTests` `exportsUnderTitle`。T-M4-06 是 `PolishAndLoopTests` `loopRangeAndSteps`、`loopsALine`（「暂停不停止循环」只在代码里，没有测试）。T-M4-07 是 `PlayerTests` `exportsWAV`。T-M4-05 是 `HomeModelTests` `sourceChipNarrowsTheList`、`subtitleNamesTheSourceOfNonCardRecordings`。T-M4-04 是 `RichTextTests`（2 个，只在 macOS 上跑：Linux 的 Foundation 没有 Markdown 解析）。T-M4-03 是 `LibraryAskerTests`（3 个）、`LibraryQuestionModelTests`。T-M4-01 是 `AppDatabaseTests` `foldersHoldRecordings`、`v7LibraryUpgradesToV8`；T-M4-02 是 `HomeModelTests` `folderChipNarrowsTheList`、`RecordingDetailModelTests` `movesBetweenFolders`。

#### 3.6.5 M5 先做的部分（Mac 版，ADR-011）

| 编号 | 用例 | 通过线 |
|---|---|---|
| T-M5-01 | Mac 窗口的录音列表与导入 | 开始时为空；导入一个 .md 和一个不是音频的 .mp3，提示「已导入 1 个，1 个无法识别」，列表出现一条，标题是文件名，副标题以「文字 · 导入」结尾；搜索词在文字稿里时只列出它，搜不到时为空，空白搜索回到全部；导入提示四种文案；iPhone 和 Mac 用同一套文字扩展名。实现：`LibraryBrowserModelTests`（2 个）。Mac 目标能编译由 CI 的「Build Mac app」一步保证；窗口本身（选中、播放、拖放导入）要在 Mac 上手动走一遍 |
| T-M5-02 | Mac 和 iPhone 选用转写方式的规则 | 什么都没设置时没有转写；有 AI 服务但没填转写模型时也没有（不上传音频）；填了转写模型（去掉首尾空白）时用这个服务，地址和密钥与纪要用的相同，会联网；打开本机转写时优先用本机，不联网。实现：`TranscriberChoiceTests`。转文字、生成纪要的按钮状态沿用 iPhone 详情页的模型和测试（`RecordingDetailModelTests`）；Mac 上的语音识别权限和实际转写要在 Mac 上手动试 |

### 3.7 M5 链接导入（X12，iPhone 部分，#72）

自动用例都不联网：页面、RSS 和 Apple 查询的回复是测试里手写的，下载用 `URLProtocol` 桩。编号 10～49 是自动用例，60 起是要真手机、真网络的检查（01～09 留给 Mac 版）。

| 编号 | 对象 | 判据 |
|---|---|---|
| T-M5-10 | 从分享文字里找链接 | 播客 App 分享的整段文字（含中文标点、尾随的句号括号）里取出第一个 http(s) 链接；没有链接、`ftp:` 不算；视频网站（B 站、YouTube、抖音等，含子域名）认出来，不发任何请求，提示「暂时不能导入视频网站的链接」 |
| T-M5-11 | 读 RSS、Atom、单集网页、Apple 播客 | RSS：节目名、每期标题（含 CDATA）、`<enclosure>` 的地址（相对地址补全）、大小、`itunes:duration` 三种写法、`pubDate`；图片附件和没有音频的条目丢掉；按日期从新到旧。Atom 读 `rel="enclosure"`。网页：`og:audio` 优先（`&amp;` 解码，空的 `<audio src="">` 不算），其次 `<audio>`、带音频类型的 `<source>`，视频的 `<source>` 不算；没有音频时跟着 `<link rel="alternate">` 去读 RSS。Apple 播客：链接里取节目编号、`i=` 单集编号和国家代码，查询只带这几个值；单集在查询结果里就直接导入，不在就退回节目的 RSS 让用户挑，节目链接列出查询结果 |
| T-M5-12 | 打不开、不让下载时的提示 | 401/402/403 是「要登录或付费」，404/410 是「页面不存在了」，其他状态带错误码；没联网和关了「无线数据」（`-1009`、`dataNotAllowed`）提示去哪里打开；页面里没有音频时说明能粘贴哪几种链接；音频地址就是文件时解析阶段不发请求；`http://` 的链接改用 `https://` 访问（App 不开 ATS 例外） |
| T-M5-13 | 下载 | 边收边写进文件，扩展名先看地址、再看 `Content-Type`；进度按 `Content-Length` 报、只增不减；收到网页（`text/*`）、401/403 时不存；超过上限立即停止并提示「超过 1 GB」；`Content-Length` 显示放不下（留 200 MB 余量）时不下载；取消后不留文件 |
| T-M5-14 | 「从链接导入」页 | 一期节目直接下载并存成来源为「导入」的录音，标题是这一期的标题，时间是导入时间，临时文件清掉；节目列出最多 100 期，选一期才下载；解析失败、下载的不是音频时显示原因，录音库里不多出任何东西；下载中取消回到空闲，不存录音；取消后马上换一个链接，取消的那次晚到的结果不改新的状态；列表里连点两期只下载第一期 |
| T-M5-60 | 真手机、真网络 | 小宇宙、Apple 播客的单集链接各导入一次（从这两个 App 里「分享 › 拷贝链接」再粘贴）；一个节目的 RSS 地址列出单集，选一期导入；导入的录音能播放到结尾、能本机转写；30 分钟以上的一期导入后时长正确 |
| T-M5-61 | 关掉「无线数据」 | 「设置 › 闻笺 › 无线数据」关掉后粘贴链接，提示去哪里打开，没有转圈不停；打开后同一个链接能导入 |
| T-M5-62 | 下载中离开 | 下载中点「取消」、下拉关闭不了（下载中不能拖动关闭）；切到后台再回来，下载继续或给出失败原因，不留下半截录音 |

实现：T-M5-10 是 `LinkTextTests`（6 个）和 `LinkResolverTests` `failuresReadAsAdvice` 里的视频网站一项。T-M5-11 是 `FeedParserTests`（4 个）、`PageScannerTests`（5 个）、`ApplePodcastsTests`（3 个）、`LinkResolverTests` 的前 9 个。T-M5-12 是 `LinkResolverTests` `failuresReadAsAdvice`、`everyErrorHasText`。T-M5-13 是 `EpisodeDownloaderTests`（6 个）。以上 35 个在 `LinkImportTests`，只用 Foundation，Linux 上也能跑。T-M5-14 是 `LinkImportModelTests`（6 个，要 `AudioImporter`，只在 macOS 上跑）。2026-11-21 另用同一个模块对真实的小宇宙单集页、Apple 播客的节目和单集链接、一个 RSS 地址各解析了一次，结果都对（不是自动用例，没有入库）。

### 3.8 M5 接入 AI 助手（X19，#72）

自动用例在临时文件夹里的录音库上跑，不启动任何助手。编号接着 §3.7：20～49 自动，70 起要真的 Mac 和助手。

| 编号 | 对象 | 判据 |
|---|---|---|
| T-M5-20 | 读 | 搜索按标题、文字稿、纪要找，所有词都要出现，最新的在前，「最近删除」里的不出现；取一条按 8 位或完整编号，未知、太短、重复、已删除的编号给出原因；Markdown 里有时间、时长、来源、标签、人物、摘要、要点、待办（打勾的是 `[x]`）、大纲、金句、带时间的文字稿（文字录音不带时间），可以不要文字稿；待办只列没打勾的，按录音分组；概况的条数不含「最近删除」 |
| T-M5-21 | 写 | 存入文字成为没有音频的一条，空文字拒绝；存入音频按「文件」导入转换，来源「导入」、标题默认用文件名、时间是存入时间，文件不存在或转换不了给出原因；只读时两项都拒绝，库里不多东西 |
| T-M5-22 | 打开录音库 | 文件夹里没有录音库时不新建、给出提示；能打开另一个进程建的库；库被更新的版本迁移过时能读、标为只读 |
| T-M5-23 | MCP 协议 | 每条回复一行；`initialize` 回应客户端要的版本（认识的），不认识时给最新的；通知不回；`ping`；`tools/list` 按能否写入、有没有音频转换列出工具，每个有 `inputSchema`；`tools/call` 返回文字，工具出错时 `isError` 为真而不是协议错误；解析错误 -32700、未知方法 -32601、参数错误或未知工具 -32602、不是请求 -32600 |
| T-M5-70 | 真实助手 | 一台装了闻笺 Mac 版的 Mac 上，Claude 桌面版按 `assistant-tools.md` §3 配好后：问「有哪些没完成的待办」列出的和闻笺「总览」一致；按关键词找到一条并总结；让它存一段文字，重开闻笺后能看到；`--read-only` 时它说不能存 |

实现：T-M5-20 是 `LibraryToolsTests` 的 `searchSkipsTheTrashAndShowsShortIds`、`getRendersSummaryTodosAndTimedTranscript`、`idsMustBeKnownUniqueAndNotTrashed`、`todosAreOpenOnesByRecording`、`overviewCountsWhatTheListShows`、`formatting`。T-M5-21 是 `addingTextAndAudio`、`readOnlyRefusesWrites`。T-M5-22 是 `ExistingLibraryTests`（2 个）。T-M5-23 是 `MCPServerTests`（4 个）。共 14 个，只依赖 Library，Linux 上也跑（`scripts/linux-test.sh`）。2026-11-22 另在 Linux 上对编译出的 `revive` 做过一次端到端：找不到录音库时退出码 1；`add-text`（文件和标准输入）、`overview`、`search`；`mcp` 用管道走完 `initialize`、`tools/list`、`tools/call`。

## 4. 真机测试方法与证据

每次真机测试在 `evidence/<编号>/` 下留一份 README，写明：

| 项 | 内容 |
|---|---|
| 环境 | 手机型号、iOS 版本、App 构建号或提交号、卡的固件版本、电量与是否在充电 |
| 设备 | `sn` 只写 SHA-256 前 8 位；`btaddr` 只留后两段；不写 bondId（ADR-006） |
| 命令或步骤 | 能让别人照着复现 |
| 原始结果 | 日志、校验值；录音音频不入库，只记 sha256 |
| 判据 | 预先写好的通过线 |
| 结论 | 通过 / 不通过 / 部分通过，并写明适用范围（例如「仅 v1.50」） |

真机测试会改变卡的状态（配对、删除文件）。测试前先用 `client/dnote.py pull` 把卡上录音备份到本地。

## 5. 多卡样本

- 目前只有 1 张卡（固件 v1.50）。#8 要求在 **TestFlight 外部测试前**补齐至少 3 张卡（#8 决定；2026-11-11 改为外部测试前，内部测试构建已先上传，#58）。
- 卡的来源：向首批 TestFlight 用户征集，或另行购买。
- 每张卡跑 T-M1-55；固件版本不同时，额外跑 T-M1-10 和 T-M1-20 的真机版本。
- 发版后的补充：App 记录连接过的固件版本（只记版本号，不记 sn），意见反馈时附带，用来发现未验证的版本。

## 6. M2～M4 方法

| 里程碑 | 主要验证 | 方法 |
|---|---|---|
| M2 | §7.1 第 2 条：5 分钟多人对话自动出现带说话人的转写和总结 | 端到端，用真卡录音 |
| M2 | §7.1 第 5 条：关停后端后，离线功能不受影响；恢复后排队任务自动补做 | 端到端，在测试环境停掉后端 |
| M2 | 账号：注册、登录、找回、注销；注销后数据全部删除 | 后端集成测试（`pytest` + 真实 PostgreSQL）+ 端到端 |
| M2 | 后端第一片的自动用例（2026-11-22，`backend/tests/`，30 个，CI 为 `backend-ci`） | 见下表 |
| M2 | 转写与总结质量 | #12 前置任务：≥ 30 分钟、≥ 3 人的测试集，人工校对参考文本；字错率和说话人区分先测基线，再在门禁定门槛；总结按统一评分表打分 |
| M2 | 接口契约 | 由 FastAPI 生成 OpenAPI 文档，App 侧用它做契约测试 |
| M2 | X11 用户自配服务（ADR-009）：同一段录音走自配服务和走后端，结果的结构一致；填错地址或密钥时提示清楚；不配置也不登录时，设备功能和本机转写照常 | App 侧对 OpenAI 兼容接口的模拟服务做集成测试（不联网）；端到端用一家真实服务商；提示词两条路径共用一份，用同一组样本比对输出结构 |
| M3 | §7.1 第 3 条：实时录音 1 分钟，App 上持续出现文字 | 端到端；首字延迟和文字滞后先测基线（#13 前置任务） |
| M3 | WiFi 快传 | 真机：sha256 与蓝牙下载一致；吞吐 ≥ 蓝牙基线 2 倍；首次加入热点的引导 |
| M4 | §7.1 第 4 条：另一台 iPhone 登录同一账号，录音、转写、总结、笔记、设备全部恢复 | 端到端，两台手机 |
| M4 | 同步冲突 | 后端集成测试：两端同时修改同一记录，以较新的为准，冲突日志有记录 |
| M4 | §7.1 六条全部回归 | 按本文件全部真机与端到端用例 |

### 6.1 M2 后端第一片：账号、设备登记、意见反馈

测试连真实 PostgreSQL（CI 用服务容器），时钟可拨，验证码发到内存里。

| 编号 | 对象 | 判据 |
|---|---|---|
| T-M2-20 | 手机号验证码登录 | 号码按「+86」规范化，只收大陆手机号；第一次登录建号，再登录是同一个账号；验证码只能用一次、10 分钟过期 |
| T-M2-21 | 验证码防滥用 | 同一目标 60 秒内不重发（`429 code_too_frequent`，可重试），24 小时最多 10 条；连错 5 次后连对的也不收（错的次数在请求失败时也记下）；短信发送失败时不留下验证码（`502 code_send_failed`） |
| T-M2-22 | 邮箱注册与密码登录 | 邮箱不分大小写；没验证前重新注册会换密码、再发验证码；没验证时密码对也不能登录（`403 email_not_verified`）；邮箱不存在和密码错回一样的结果；已验证的邮箱不能再注册（`409`）；密码少于 8 位、邮箱格式不对返回 `422 invalid_request` |
| T-M2-23 | 找回密码 | 邮箱有没有注册都回同样的 `202`，只给注册过的发邮件；重置后旧的登录全部失效，新密码能登录、旧密码不能 |
| T-M2-24 | 刷新令牌 | 每次刷新换新；作废的令牌再出现，整条登录链吊销（`401 refresh_reused`），别的登录不受影响；带同一个 `Idempotency-Key` 重试拿到同一对令牌、不算盗用；30 天过期；退出后不能再刷新 |
| T-M2-25 | access token | 15 分钟过期（`401 token_expired`，可重试），刷新后可用；没带、伪造的令牌分别是 `unauthorized`、`invalid_token` |
| T-M2-26 | 修改密码 | 当前密码不对 `401`；改完后其他登录全部失效，返回的新令牌可用；手机号账号没有密码可改（`password_not_set`） |
| T-M2-27 | 注销 | `DELETE /me` 后这个账号的设备、反馈、令牌全部删除，别的账号不受影响；旧 access token 失效 |
| T-M2-30 | 设备登记 | 上传后取回的 `sn_hash`、`bond_id` 和上传的一致；数据库里既没有 `sn_hash` 也没有绑定码的明文，查找用的键也不等于 `sn_hash`；同一张卡在两个账号下各存各的；格式不对返回 `422`，删不存在的返回 `404 device_not_found`；密文换到别的账号下打不开 |
| T-M2-31 | 意见反馈 | 登录后能提交；空内容 `422`；没登录 `401` |
| T-M2-32 | 通用约定 | 错误都是 `{"error": {"code", "message", "retryable"}}`；`Idempotency-Key` 重复时返回第一次的结果并带 `Idempotent-Replayed`，换了内容 `422`，按用户区分（换了 access token 仍算同一个人），24 小时后失效，键过长 `400`；保存的响应是加密的；生产环境没有真实短信和邮件发送、没有真实对象存储时拒绝启动；密钥太短拒绝启动；迁移与模型一致，能降级再升级 |
| T-M2-33 | 录音上传（§7.2） | 按 8 MiB（测试里 1 KiB）分片，每片一个预签名地址，传完后合并，下载回来的字节和 SHA-256 一致，文件名用标题加扩展名；只传了一部分时完成返回 `409 upload_incomplete`，续传接口标出已传的分片和 ETag，补传后能完成；ETag 不对 `409 upload_mismatch`；分片大小不对不合并；完成两次不报错；存储忘了这次上传时 `409 upload_expired`，再取地址从头开始；没有音频的录音不上传（`409 no_audio`、`409 audio_not_uploaded`）；音频过大 `413`，来源、时间没有时区、时长为负、哈希格式、类型不是 `audio/*` 返回 `422` |
| T-M2-34 | 去重与归属 | 同一账号同一 `audio_sha256` 只建一条：传完前再提交返回同一条和同一次上传，传完后返回不带上传地址的同一条，元数据不被覆盖；另一个账号同样的音频各建各的；别人的录音读不到、删不了（`404 recording_not_found`）；登记过的卡在录音上显示 `device_sn_hash`，没登记的为空，卡删掉后变空；列表按开始时间从新到旧分页，游标不对 `422`；带 `Idempotency-Key` 重复建没有音频的录音只建一条 |
| T-M2-35 | 删除与清理 | 删除后读不到、存储里的音频没了、留下墓碑（`deleted_at`、版本加 1），同样的音频能再传成新的一条；传到一半删除，已传的分片删掉，之后再传分片 `404`；注销后这个账号的音频和未完成的分片全部删掉，别的账号的不动；存储不可用时删除仍成功，待删记录留下（次数、错误），恢复后 `drain_deletions` 删掉；存储不可用时开始上传 `502 storage_unavailable`（可重试）且不留下录音；7 天没传完的上传作废，再取地址换新键从头传；`/dev-storage` 的地址改了分片号、改了路径、过期都是 `403`，分片超过大小 `413` |
| T-M2-36 | 转写任务（F1） | 音频传完才能转写（`409 audio_not_uploaded`）；新建返回 `202 queued`，已有排队或进行中的返回同一个（200），完成后再转写是新任务；工作进程执行后 `succeeded`、尝试 1 次；引擎拿到的地址能下载到这条录音的音频，语言和说话人参数照传；文字稿的分句、说话人、引擎名正确；记一条 `asr_seconds`（按秒向上取整）；别人的录音、任务、文字稿都是 `404`；语言格式不对 `422`；替身引擎的文字稿写明是替身；生产环境没有真引擎拒绝启动 |
| T-M2-37 | 任务队列（§7.4，ADR-013） | 可重试的失败回到 `queued` 并带上错误，分别等 30、60、120 秒才再执行，第 4 次仍失败就 `failed`；中间一次成功则错误清空；不可重试的失败直接 `failed`；意外异常按 `internal` 可重试处理；拿了任务的进程消失，15 分钟后别的进程接手，迟到的那个写不进结果（`LostLease`）；连续 4 次都消失则 `failed worker_lost`；删除录音时排队的和进行中的任务都是 `failed recording_deleted`，进行中的结果不写入；工作进程循环能跑完排队的任务并在收到停止后退出 |
| T-M2-38 | 说话人命名与注销 | 只能给文字稿里出现的标签起名（`422 unknown_speaker`），名字去掉首尾空白，最多 32 字（`422 speaker_name_too_long`），空名删除；重新转写后名字清空；注销后任务、文字稿删除，用量记录保留但不再指向用户 |
| T-M2-39 | 一份提示词（ADR-009） | App 的 `Summarizer` 和后端的 `summaries.py` 生成的提示词与 `Fixtures/prompts` 的 8 个样本逐字一致：自动判断场景、指定会议、带职业的系统提示词，第 2 段的分段提示词，分段笔记的拼法，65 分钟录音的用户消息，换角度起标题的提示词和用户消息；样本目录里没有多余的文件；改动样本里一个字，后端测试失败 |
| T-M2-40 | 后端读纪要回复 | 与 App 的 `SummaryParsingTests` 同样的用例：正常回复、包在说明文字和 `<think>` 里的 JSON、大纲最多 8 个话题各 6 条、金句最多 5 句去引号、没有摘要或不是 JSON 报错、场景按代号或中文名读、未知的算 other、用户选的场景优先、标题 30 字、标签 6 个去 #、人名 12 个；分段与 App 一致；时长读法一致 |
| T-M2-41 | 生成纪要任务 | 有文字稿才能生成（`409 no_transcript`），未知模板 `422 unknown_template`；请求的系统提示词是所选场景加职业的那一份，用户消息是录音时长加文字稿；超过 9000 字时先按 6000 字分段压缩，再用分段笔记生成；结果的栏目、标签和模型名正确；再生成保留旧的，新的在前；`llm_tokens` 按所有请求合计；回复读不出来时重试，模型拒绝（不可重试）时直接失败；排队中再提交返回同一个任务；别人的录音 `404`；`GET /templates` 是 10 种场景且要登录；替身模型能跑通整条流程；注销后纪要删除、用量保留；生产环境没有真模型拒绝启动 |
| T-M2-42 | 用量（X2） | 自然月从北京时间 0 点开始（UTC 前一天 16:00）；`GET /me/usage` 没有用量时都是 0、额度为空；排队的转写计入预占，完成后转为已用（按秒向上取整），纪要记 token；下个月从 0 开始；没登录 `401`；生产环境没设两项额度拒绝启动 |
| T-M2-43 | 额度与限流 | 已用 + 预占 + 这一条超过转写额度时 `429 quota_exceeded`（不可重试，提示下个月 1 日恢复），已在排队的再提交不重复计算，别的账号不受影响，下个月恢复；失败的转写把预占退回；纪要 token 用完后 `429 quota_exceeded`；同时排队和进行中的任务到上限时 `429 too_many_tasks`（可重试），完成一个后可以再提交；额度只够一条时两个并发请求只有一个成功（去掉用户行锁后这个测试失败） |
| T-M2-44 | 换角度重起标题（G1） | 标题解析与 App 的 `readsANewTitle` 一致（JSON 的 title、单行文字、去引号和空白、最多 30 字、空标题报错），坏 JSON 取第一行；内容超过 9000 字截断；没有纪要时用文字稿，有纪要时用最新一份的标题和摘要；不给当前标题时用录音存的标题；结果在任务的 `result` 里，录音标题不变；没有文字稿和纪要 `409 no_content`；排队中再提交返回同一个；别人的录音 `404`；读不出标题重试，模型拒绝直接失败；计入 `llm_tokens`，用完后 `429 quota_exceeded`；删除录音后排队的任务 `failed recording_deleted` |


实现：T-M2-20～27 在 `tests/test_auth.py`（15 个）和 `test_account_data.py` 的前 3 个；T-M2-30、31 在 `test_account_data.py`；T-M2-32 分散在 `test_account_data.py`、`test_config.py`、`test_migrations.py`。T-M2-33～35 在 `tests/test_recordings.py`（17 个）；T-M2-36～38 在 `tests/test_transcripts.py`（12 个）和 `test_config.py` 的 1 个；T-M2-39～41 在 `tests/test_summaries.py`（17 个）、`test_config.py` 的 1 个，App 端是 `PromptFixtureTests`（2 个，只在 macOS 上跑）；T-M2-42、43 在 `tests/test_usage.py`（7 个）和 `test_config.py` 的 1 个；T-M2-44 在 `tests/test_retitle.py`（5 个），App 端 `PromptFixtureTests` 多比对一个样本；同一天起真实的 API 和工作进程走了一遍：上传、转写、轮询到 `succeeded`、读到文字稿，工作进程收到 SIGTERM 后退出，对象存储用 `LocalStore` 放在临时目录里，分片真的经由 `/dev-storage` 地址上传。2026-11-22 另用 uvicorn 起了真实服务，curl 走完健康检查、发验证码、登录、`/v1/me`；同一天第二到四片也对真实服务用 httpx 脚本走了一遍（第四片：转写后生成纪要，读到替身模型写的纪要，`GET /templates` 返回 10 种）：20 MB 音频分 3 片上传、完成、下载回来哈希一致、删除后存储目录为空，`python -m revive_api.maintenance` 能跑。腾讯云 COS 的实现要等账号，到时用同一组用例加一次真 COS 的手动检查。

## 7. 持续集成

- GitHub Actions（`.github/workflows/app-ci.yml`）：macOS 运行器先跑 §3.5 第 1 道检查（`scripts/check-m1-rules.sh`），再跑 `swift test --disable-xctest`（单元 + 模拟卡集成），最后用 `xcodebuild build` 编译 App。只在 `app/`、检查脚本或工作流文件有改动时触发。
- M2 起增加后端：`pytest`，数据库用 PostgreSQL 服务容器。
- M1.5 起 `scripts/check-m1-rules.sh` 的不联网检查也覆盖 `Transcription` 模块（T-M15-13）。
- #74 起 CI 在 `swift test` 之前还跑 `scripts/check-theme.sh`（T-M15-15）。
- 2026-11-21 起 `scripts/check-m1-rules.sh` 还检查 `SyncEngine`、`DeviceSource` 不引用 D·NOTE 的模块（T-M1-35，ADR-010），不联网检查也覆盖 `DeviceSource`。
- 计时（2026-11-19）：`swift test` 并行跑所有套件，主线程隔离的测试共用一个主线程，CI 上开头约 5 s 都很忙。所以「等一个应该到的回包或状态」一律用宽松上限：模拟卡请求超时 30 s、`waitUntil` 30 s，条件一满足就返回，测试不会变慢。只有专门测超时的用例（注入 `noResponse`、`dropReply`）在连上卡之后才把要测的那个超时缩短（`Harness.shortenRequestTimeouts()`、`service.timing`），连接本身不受影响。此前 100 ms、200 ms、2 s、3 s 的上限都在 CI 上超时过（`e962290`、PR #90）。
- 真机与端到端不进 CI；结果以证据目录和 PR 记录为准。
