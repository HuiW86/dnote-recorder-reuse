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

实现（#39）：`app/ReviveKit/Tests/SyncEngineTests/`，每个用例结束时断言写帧里没有 `0x93`/`0x94`/`0xB0`/`0xB1`（§3.5 第 2 道检查）。

- T-M1-23 的「被杀」：在提交前的钩子里挂起，永不返回；随后在同一个数据库和目录上新建 SyncEngine，相当于重启。
- T-M1-27 分两种：`FakeCard.Fault.disconnectAfter(.deleteFile)` 表示删除已生效后断开，`disconnectInsteadOf(.deleteFile)` 表示断开时删除未生效。
- 另有失败自动重试，以及录音中不同步两个用例。
- T-M1-33（#79，PR #80）：`absentFailedFileDoesNotCauseEmptyRetryLoop`、`removedFailedFileReturningCanBeSynced`、`replacedSizeDoesNotKeepOldFailureRetrying`、`manualPassCancelsObsoleteRetryTimer`、`failedManualListDoesNotLoseScheduledRetry`；同时加了脱敏的同步诊断（`syncDiagnosticsExposeReasonAndCounts`：请求来源、是否排队、列表数、候选数、可重试数）。真机观察记录在 `evidence/v79-sync-retry/`，计时器边界修复之后的版本尚未真机复验。

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

T-M15-50、54 会删除卡上文件，只用测试录音，不用有价值的录音。T-M15-56 的录音音频不入库，只记 sha256（硬规则 4）。

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
| M2 | 转写与总结质量 | #12 前置任务：≥ 30 分钟、≥ 3 人的测试集，人工校对参考文本；字错率和说话人区分先测基线，再在门禁定门槛；总结按统一评分表打分 |
| M2 | 接口契约 | 由 FastAPI 生成 OpenAPI 文档，App 侧用它做契约测试 |
| M2 | X11 用户自配服务（ADR-009）：同一段录音走自配服务和走后端，结果的结构一致；填错地址或密钥时提示清楚；不配置也不登录时，设备功能和本机转写照常 | App 侧对 OpenAI 兼容接口的模拟服务做集成测试（不联网）；端到端用一家真实服务商；提示词两条路径共用一份，用同一组样本比对输出结构 |
| M3 | §7.1 第 3 条：实时录音 1 分钟，App 上持续出现文字 | 端到端；首字延迟和文字滞后先测基线（#13 前置任务） |
| M3 | WiFi 快传 | 真机：sha256 与蓝牙下载一致；吞吐 ≥ 蓝牙基线 2 倍；首次加入热点的引导 |
| M4 | §7.1 第 4 条：另一台 iPhone 登录同一账号，录音、转写、总结、笔记、设备全部恢复 | 端到端，两台手机 |
| M4 | 同步冲突 | 后端集成测试：两端同时修改同一记录，以较新的为准，冲突日志有记录 |
| M4 | §7.1 六条全部回归 | 按本文件全部真机与端到端用例 |

## 7. 持续集成

- GitHub Actions（`.github/workflows/app-ci.yml`）：macOS 运行器先跑 §3.5 第 1 道检查（`scripts/check-m1-rules.sh`），再跑 `swift test --disable-xctest`（单元 + 模拟卡集成），最后用 `xcodebuild build` 编译 App。只在 `app/`、检查脚本或工作流文件有改动时触发。
- M2 起增加后端：`pytest`，数据库用 PostgreSQL 服务容器。
- M1.5 起 `scripts/check-m1-rules.sh` 的不联网检查也覆盖 `Transcription` 模块（T-M15-13）。
- #74 起 CI 在 `swift test` 之前还跑 `scripts/check-theme.sh`（T-M15-15）。
- 计时（2026-11-19）：`swift test` 并行跑所有套件，主线程隔离的测试共用一个主线程，CI 上开头约 5 s 都很忙。所以「等一个应该到的回包或状态」一律用宽松上限：模拟卡请求超时 30 s、`waitUntil` 30 s，条件一满足就返回，测试不会变慢。只有专门测超时的用例（注入 `noResponse`、`dropReply`）在连上卡之后才把要测的那个超时缩短（`Harness.shortenRequestTimeouts()`、`service.timing`），连接本身不受影响。此前 100 ms、200 ms、2 s、3 s 的上限都在 CI 上超时过（`e962290`、PR #90）。
- 真机与端到端不进 CI；结果以证据目录和 PR 记录为准。
