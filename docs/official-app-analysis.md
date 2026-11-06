# 官方 D·NOTE App 功能盘点与复刻范围建议

- 分析对象：D·NOTE App 1.0.11（build 45，`com.dnote.dreame`，sha256 `53ec0e4a…48f9f9`）
- 方法：REA（rea-agents 6.8.0）静态分析 + 主 bundle 定向检索交叉核对
- 原始产出与复现步骤：`~/WeChatProjects/REA/outputs/dnote-app-20261105/`
- 日期：2026-11-05

本文只记录结论和代码位置，不复制官方源码。

---

## 1. 总览

| 项 | 结论 |
|---|---|
| 技术栈 | Capacitor + Vue 3 + Ionic，业务全部在 JS；安卓原生层只是 Capacitor 插件（Capacitor 具体版本未能从产物中确认） |
| 页面 | 42 条路由，对应 41 个页面组件（REA 路由清单与主 bundle 路由表 42/42 一致） |
| 云端接口 | 54 个，base URL `https://api.dreamenote.cn`；电子名片另走 `me.dreamenote.cn` |
| 后台状态 | **2026-11-05 实测：`api.dreamenote.cn`、`me.dreamenote.cn` 的 HTTPS 证书均已过期**，App 的所有云端请求都会在 TLS 握手阶段失败 |
| 本地存储 | SQLite（TypeORM），实体：`Record`、`Transcription`、`Summary`、`Folder`、`GenerateTask`、`RecordNote`、`GoldenMoment`；音频按用户目录存放 `<user>/audio/<id>.<ogg\|mp3\|wav>` |
| 原生能力 | 蓝牙 LE、SQLite、文件系统、WiFi 连接、TCP Socket、内购、相机、通讯录、分享/接收分享、文件选择、常亮、定位等 30 个插件 |

## 2. 功能清单

依赖：**设备** = 只需录音卡（BLE/WiFi）；**本地** = 只需手机；**云** = 依赖已失效的追觅后台。

| # | 模块 | 功能 | 入口（路由/组件） | 依赖 | 代码证据 | 复刻建议 |
|---|---|---|---|---|---|---|
| A1 | 设备接入 | 扫描、连接引导、选择设备 | `/device/scan` `/device/connect-tutorial` `/device/select` | 设备 | `DeviceScan-*.js`、`ConnectTutorial-*.js` | **必须** |
| A2 | 设备接入 | 绑定/配对 | `DeviceScan` → `bindNewDevice` | 设备 + 云（取 bondId） | `postRecorderActive`、`setChaCha20Key`、`bondDevice` | **必须**，bondId 改本地生成（已真机验证） |
| A3 | 设备管理 | 设备信息与设置：LED、马达、降噪及档位、增益、VAD、保存 WAV、自动关机、USB 存储、蓝牙名 | `/device/info` | 设备 | `DeviceInfo-*.js`；`recordingDevice.set*` | **必须**（设置项可分批） |
| A4 | 设备管理 | 解绑、已绑定设备列表、多设备切换、自动重连 | `/device/unbind` `/profile/bound-device-list` | 设备 + 云（同步绑定列表） | `DeviceUnbind-*.js`、`BoundDeviceList-*.js`、`getRecorderActive` | **必须**，绑定列表改存本地 |
| A5 | 设备管理 | 恢复出厂、格式化、关机 | `/device/info` | 设备 | `restoreFactorySettings`、`formatDisk`、`shutdown` | 可选 |
| A6 | 设备管理 | 固件升级（APK 内置固件） | `/device/info` | 设备 | `startFirmwareUpgrade`、`transferFirmwareData`、`Firmware-DVJaG6Rm.lz` | 可选，风险高，后期 |
| B1 | 录音控制 | 开始/停止/暂停/继续、录音状态 | `/tabs/home` | 设备 | `startRecording` 等，通知 `0x51`/`0x56` | **必须** |
| C1 | 文件同步 | BLE 拉取录音、解密、转 OGG | 首页自动同步 | 设备 | `DeviceFileTransferService`、`decryptAudioFile` | **必须**（已真机验证） |
| C2 | 文件同步 | WiFi 快传（热点 `FastUpload`，TCP `192.168.88.1:6718`） | 首页"快传" | 设备 | `FAST_TRANSFER`、`CapacitorWifi`、`TcpSocket` | 可选，长录音体验关键，TCP 协议待逆向 |
| D1 | 录音库 | 录音列表、文件夹、回收站（自动清理）、按来源筛选（设备/导入/通话/笔记）、移动、删除 | `/tabs/home` | 本地 | `HomePage-*.js`、`MoveToFolderModal-*.js`、实体 `Record`/`Folder` | **必须**（基础列表 + 删除；文件夹/回收站可后置） |
| D2 | 录音库 | 全局搜索 | `/search/global` | 本地 | `GlobalSearchPage-*.js` | 可选 |
| E1 | 音频 | 播放、格式转换（OGG/MP3/WAV） | `/record/detail/:id` | 本地 | `opus-decoder`、`ogg-opus-to-pcm-worker`、`pcm-to-mp3-worker` | **必须** |
| E2 | 音频 | 导入外部音频、接收系统分享 | 首页"导入" | 本地 | `capacitor-file-picker`、`capacitor-share-target` | 可选 |
| F1 | 转写 | 云端转写（语言、说话人区分、模板），说话人重命名 | `/record/detail/:id` | **云** | `create_audio_task`、`get_audio_task_result`、`support_langs` | 需替代：第三方或自建 ASR |
| G1 | AI 生成 | 总结、大纲、思维导图、金句、标签、重新生成、额度提示 | `/record/detail/:id` | **云** | `create_summary`、`create_async_summary`、`create_golden_moments`、`get_ai_summary_model_list` | 需替代：LLM API |
| G2 | AI 生成 | 总结模板库、模板分类、模板社区 | `/profile/template-community` `/profile/category-template/:id` | **云** | `template_list`、`template_categories`、`template_info` | 需替代：内置少量模板 |
| G3 | AI 对话 | 针对单条录音提问、全局 AI 对话（SSE 流式） | 详情页、首页 | **云** | `llm/chat`、`global_ai/chat` | 需替代：LLM API；可后置 |
| H1 | 实时 | 实时录音 → `0x68` Opus 块 → 解码 16kHz PCM → Socket 推流实时转写 → 实时总结 | 首页"实时笔记" | 设备 + **云** | `startRealTimeRecording`、`realtimeOpusChunk`、`initSocket`、`realtime_summary` | 二期；设备侧 `0x54` 真机未跑通 |
| I1 | 笔记 | 录音笔记（文字 + 图片），按时间标记 | 详情页"笔记"页签 | 本地 + 云同步 | `RecordDetailNotesTab-*.js`、`save_notes`、`upload_note_image` | 可选，改纯本地 |
| J1 | 导出 | 导出 PDF、DOCX、Markdown、XMind、思维导图，WPS 打开 | 详情页 | 本地 | `pdf-*.js`、`docx-*.js`、`marked.esm`、`xmind-*.js`、`html2canvas` | 可选（先做文本 + 音频分享） |
| K1 | 账号 | 登录、注册、验证码、改密/找回、注销 | `/auth/*`（8 页）、`/profile/settings/account-*` | **云** | `/users/*` 15 个接口 | **放弃**（本地优先，无需账号） |
| L1 | 会员 | 会员页、购买、权益对比、账单、用量、新人试用 | `/membership/*`（6 页） | **云** + 应用内购 | `/subscription/*` 7 个接口、`NativePurchases` | **放弃** |
| M1 | 电子名片 | 创建/编辑名片、公开名片页 `/card/:sn`、存通讯录 | `/business-card/*` `/card/:sn` | **云**（`me.dreamenote.cn`） | `business-card.api-*.js`（`/api/card`、`/api/user/card`） | 放弃（与录音无关，可另议） |
| N1 | 云同步 | 录音上传云端、云端文件列表、云端音频下载 | 后台 | **云** | `upload_file`、`get_file_list`、`get_audio_download_url` | **放弃** |
| O1 | 通用 | 设置、语言、关于、权限说明、隐私、反馈 | `/profile/*` | 本地（反馈走云） | `SettingPage-*.js` 等 | 精简保留 |

## 3. 云端接口清单（54 个）

| 分组 | 数量 | 接口 | 背后能力 | 替代思路 |
|---|---|---|---|---|
| 设备登记 | 3 | `GET/POST /recorder/active`、`POST /recorder/inactive` | 绑定码发放、账号下设备列表 | 本地生成 bondId，设备列表存本地 |
| 转写 | 6 | `create_audio_task`、`get_audio_task_result`、`get_audio_task_list`、`delete_audio_task`、`support_langs`、`get_audio_download_url` | 云端 ASR（多语言、说话人区分） | 第三方 ASR API，或端侧/自建 Whisper |
| AI 生成 | 6 | `create_summary`、`create_async_summary`、`get_async_summary`、`create_golden_moments`、`get_golden_moments`、`get_ai_summary_model_list` | LLM 总结 | LLM API + 本地提示词模板 |
| 模板 | 5 | `template_list`、`template_list_snapshot`、`template_categories`、`template_info`（另有一个带查询参数的 `template_list`） | 模板库 | 内置模板 |
| AI 对话 | 4 | `llm/models`、`llm/chat`、`global_ai/chat`、`realtime_summary` | LLM 对话、实时总结 | LLM API |
| 笔记/文件 | 7 | `save_notes`、`get_task_notes`、`upload_note_image`、`upload_file`、`get_file_list`、`add_file_to_list`、`update_file_list` | 云同步 | 放弃，本地存储 |
| 账号 | 15 | `/users/*` | 账号体系 | 放弃 |
| 订阅 | 7 | `/subscription/*` | 会员、内购校验 | 放弃 |
| 其他 | 1 | `/app_info` | 版本检查 | 放弃或改为自有版本检查 |

另：电子名片接口在 `business-card.api-*.js`，路径 `/api/card`、`/api/user/card`、`/api/dnote/upload`。

## 4. 蓝牙协议核对（与 `PROTOCOL.md` 对照）

App 导出的设备命令共 35 个（不含 UUID 常量和帧/广播解析函数），`PROTOCOL.md` §4 已全部覆盖。以下内容此前未记录，需要补进 `PROTOCOL.md`：

| 项 | 说明 |
|---|---|
| `0x68` 实时音频通知 | 设备→App，实时录音时的 Opus 数据块；App 用 16kHz 单声道解码 |
| `0x54` 握手 | App 收到 `0x54` 响应后会**再次**调用 `startRealTimeRecording(true)`，疑似两段式启动；可解释真机上 `0x54` 无响应后断开的现象，待验证 |
| `0x93` 响应 | 恢复出厂成功（`[1]`）后，App 自动重新初始化（查信息→开关→录音状态→校时） |
| `0x56` 状态值 | `rec`：0 空闲、1/2 录音中、3 结束；结束或空闲时 App 自动刷新文件列表 |
| WiFi 快传参数 | 连热点超时 60s，开热点后等 3s，TCP 连接最多重试 6 次（间隔 2s），读超时 10s，单文件最多重试 3 次；**TCP 层协议尚未逆向** |
| 绑定时格式化 | 新卡绑定流程会先发 `0x94` 格式化 |

## 5. 复刻范围建议

官方后台已经失效，所以凡是标"云"的功能，要么放弃，要么换成我们自己的方案。按工作量从小到大有三个方案：

| 方案 | 范围 | 需要后端吗 | 判断 |
|---|---|---|---|
| **A. 录音卡伴侣** | A1–A4、B1、C1、D1（基础）、E1、O1 | 不需要 | 最快让卡"能用"：配对、录音、同步、播放、导出音频。全部依赖已真机验证 |
| **B. A + AI 整理** | A 方案 + F1 转写 + G1 总结 + G2 少量内置模板 | 需要 ASR/LLM 能力（第三方 API 或轻量自建） | 恢复这张卡的核心卖点"AI 录音名片"的 AI 部分 |
| **C. 接近全复刻** | B 方案 + C2 WiFi 快传、H1 实时转写、I1 笔记、J1 导出、G3 AI 对话、D2 搜索 | 需要，含实时 ASR | 工作量大，还有两个未逆向的协议（WiFi TCP、`0x54`） |

**建议**：MVP 按方案 A 做，架构上给方案 B 预留接口（转写/总结作为可插拔服务）。方案 A 跑通后再接 B。账号、会员、名片、云同步四块直接放弃。

### 需要拍板的问题

1. 选哪个方案作为第一版？
2. 方案 B 的 ASR/LLM：用户自己填 API Key，还是我们提供统一的服务？这决定是否要做后端。
3. App 技术栈：官方 App 本身是 Capacitor，我们沿用 Capacitor 可以直接移植大量交互逻辑和插件选型（蓝牙、SQLite、文件系统）；也可以选 Flutter、React Native 或原生。
4. 平台：先做安卓、iOS，还是双端？官方安装包只拿到了安卓版。

## 6. 局限

- 纯静态分析，未运行官方 App 观察动态行为。
- REA 的路由清单置信度为 low，已与主 bundle 路由表逐条核对。
- 未反编译安卓原生层（只看了插件清单）；未分析内置固件。
- 功能的界面细节（布局、交互流程）没有逐页记录，进入设计阶段时再按页面展开。
