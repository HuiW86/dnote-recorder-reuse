# craft-anything 评估：对官方 App 1.0.11 的二次分析

- 工具：[craft-anything](https://github.com/storytold/craft-anything) 0.4.0（2026-11-06 发布，仓库 2026-10-31 创建，作者标注 early alpha）
- 分析对象：与 REA 同一个 APK，D·NOTE App 1.0.11（`com.dnote.dreame`，sha256 `53ec0e4a…48f9f9`）
- 范围：只做分析，**没有使用它的 `rebuild`（自动重写）能力**，没有配置 AI backend
- 原始产出与复现步骤：`~/WeChatProjects/REA/outputs/craft-anything-dnote-20261106/`
- 日期：2026-11-06

本文只记录结论和代码位置，不复制官方源码。

---

## 1. 结论先行

| 问题 | 结论 |
|---|---|
| 这个工具值得用吗 | **值得，作为 REA 的补充**。它补上了 REA 没做的安卓原生层（DEX 字节码），由此定位到官方用的第三方插件及其确切版本 |
| 对复刻有帮助吗 | **有，且有一项是关键帮助**：#6 快传 TCP 协议的命令集被挖出来了（来自固件，不是来自这个工具，见 §5） |
| 能替代 REA 吗 | **不能**。两者覆盖面不同，REA 的 JS 分析更贴合本项目（业务全在 JS），craft-anything 的价值在原生层 |
| 固件分析补上了吗 | **没有**。它不识别这个固件容器，固件发现全部来自 `strings`（§4.3） |

---

## 2. 能力实测

### 2.1 实际可用的部分

| 工具 | 结果 | 耗时 |
|---|---|---|
| `triage` | 正确识别 APK，给出下一步建议 | < 1 s |
| `android-package-show` | 清单、19 项权限、21 个组件（2 个导出）、3 个 DEX、4 个 ABI 的原生库、v2 签名**并做了密码学校验** | < 1 s |
| `android-app-graph-build` | 识别出 cordova-or-capacitor / kotlin / webview-content 三个运行时特征 | < 1 s |
| `android-classes-find` | 17577 个类可按名检索，支持分页和空查询全量列举 | < 1 s |
| `android-class-show` / `android-method-show` | 字段、方法清单；方法级 Dalvik 字节码（smali 风格，含解析好的字符串和调用目标） | < 1 s |
| `js-app-map` | 220 个源文件、4372 个 bundle 模块、28764 个函数、51 条路由、258 个端点 | 2.4 s |

内置引擎全程够用，没有装 JADX / Apktool / Ghidra。速度是优势：REA 那轮 JS 分析约 3 分 44 秒、241 MB 输出，这里 2.4 秒、22 MB。

### 2.2 踩到的坑

- **默认节点上限会静默丢数据**：`js-app-map` 默认 25000 节点，本应用超了，`limitations` 里报 "12847 graph nodes were dropped"。必须 `--max-nodes 100000` 重跑
- **zsh 下不能用字符串变量存命令**：要用数组，否则参数不拆分、报 exit 127
- **参数名不统一**：`native-strings-find` 用 `--pattern`，不是别处的 `--query`
- `coverage` 始终是 `partial`（examined 220 / total 332），差额是 `*-legacy-*.js` 等未解析文件，和 REA 一样没单独分析

### 2.3 没用的部分

- `rebuild`：按约定没跑。它会拉起 Claude Code 另起一个项目，与本项目已定的 iOS + 自建后端路线不一致，且作者标注 app 行为比对"只做了一部分"
- `firmware-regions-list`、`native-strings-find`：对本项目的固件完全不可用，见 §4.3

---

## 3. 与 REA 的异同

### 3.1 定位差异

| | REA | craft-anything |
|---|---|---|
| 做什么 | 只做逆向分析 | 分析 + 自动重写 + 与原版比对 |
| 实现 | TypeScript / Node，MCP | Rust，CLI + MCP + 桌面 App |
| 本项目用到的 | JS bundle 深度分析 | 安卓 DEX 字节码 |
| 输出 | evidence JSON，241 MB | evidence JSON，带 `confidence` / `coverage` / `limitations` 三件套 |

craft-anything 每条结果都自带 `limitations` 字段，签名校验那条还明确写了"校验了什么、没校验什么"（没查吊销、没验证书是否可信）。这种自我限界比 REA 更严谨，值得我们在自己的证据包里借鉴。

### 3.2 结论一致的部分

两边独立得出同样结果，互相印证：

- 技术栈 Capacitor + WebView，业务全在 JS，原生层只是插件壳
  - craft-anything 旁证：`com.dnote.dreame` 包下**只有 12 个类**，其中 7 个是 `R$*` 资源类，唯一有逻辑的是 `MainActivity`（继承 `BridgeActivity`，8 个方法，只做了 `injectSafeAreaTop`）
- 云端域名 `https://api.dreamenote.cn`
- 路由 42 条（craft-anything 报 51 条，去重后 42 条，与 REA 完全重合；差异只是 `/` 和 `/engine.io` 两条非页面路径，以及 REA 多报的 `/card/`、`/tabs/profile` 两条前缀）

### 3.3 craft-anything 新增的发现

**① 官方用的第三方插件及确切版本**（REA 只有插件名清单，没有版本）

| 能力 | 插件 | 版本来源 |
|---|---|---|
| Wi-Fi 连接 | `@capgo/capacitor-wifi`（`ee.forgr.plugin.capacitor_wifi`） | **8.3.1**，从 `getPluginVersion` 方法的字节码常量读出 |
| TCP Socket | `com.svend.plugins.tcp.socket` | 未内嵌版本号 |
| BLE | `@capacitor-community/bluetooth-le`（`com.capacitorjs.community.plugins.bluetoothle.BluetoothLe`） | 未内嵌版本号 |

完整插件清单 35 个（含 Capacitor 官方、capgo、capawesome、Cordova 兼容层），比 REA 的 30 个多，差额是 Cordova 兼容层和 `com.getcapacitor.Plugin` 基类等非业务项。

**② 原生层确认没有自研逻辑**：见 §3.2。这对复刻是个好消息 —— 不存在"藏在 Java 层的协议实现"，BLE / Wi-Fi / TCP 全靠通用开源插件，协议逻辑都在 JS 里，REA 那轮已经覆盖。

**③ 依赖与基础设施细节**（REA 未报告）

- 原生库只有 5 个，全是通用库：`libsqlcipher.so`（5.2 MB，**数据库是加密的**）、`libsentry.so`（崩溃上报）、CameraX 的两个 JNI 库
- `io.sentry.android.*` 三个组件 + Google Play Billing + GMS，印证了订阅和崩溃上报
- 两个导出组件：`MainActivity` 和 `androidx.profileinstaller.ProfileInstallReceiver`（AndroidX 标准件）
- SDK 24–36，v2 签名，证书是自签占位（`CN=1, OU=1, O=1...`），有效期到 2123 年

**④ 它没覆盖到的**：云端接口清单。REA 那轮靠对主 bundle 定向检索整理出 54 个接口并分组；craft-anything 的 `js-app-map` 报了 258 个 endpoint，但绝大多数是 docx/XML 命名空间之类的噪声，有效的只有 `https://api.dreamenote.cn` 这一个基址和几条模板字符串（`{De}/recorder/chat_stream` 等）。**这块 REA 明显更好用。**

---

## 4. 固件：工具失效，改用 strings

### 4.1 craft-anything 在这里完全没用上

| 尝试 | 结果 |
|---|---|
| `triage Firmware-DVJaG6Rm.lz` | "isn't a format we recognise yet" |
| `triage firmware.bin`（解压后） | 同上 |
| `firmware-regions-list` | **0 个区段，0.0% 识别率**，只给出 30 个高熵段 |
| `native-strings-find` | 直接报错：`Couldn't read this as a program (Unknown file magic)` |

`native-strings-find` 这条值得注意：它的字符串检索只对 ELF / PE / Mach-O 生效，对识别不了的二进制直接拒绝 —— 这正是逆向固件最需要它的时候。

### 4.2 容器识别

文件名是 `.lz`，但文件头是 `78 da`，是 **zlib**，不是 lzip。用 Python 一行解压得到 4,063,232 字节镜像，文件头 `RKFP` = Rockchip 固件包。
固件自己的日志里也有 `ml_lzip.c` / `ml_decompress_file success`，说明这个 `.lz` 命名是厂商自定的。

### 4.3 固件画像（来自 `strings`）

- SoC / RTOS：Rockchip + RT-Thread（`2006-2019 Copyright by rt-thread team`）+ lwIP 2.0.2
- Wi-Fi：Infineon/Cypress WHD（`wiced_*`、`__cmd_cywifi*`），双槽固件（`Boot FW1` / `Boot FW2`，`running slot A/B Fw`）
- 构建痕迹：`/home/felix/Work/1.2.0/GP3/compare/wifirecorder/`，版本时间戳 `2026-04-25 17:19:53`
- 音频：Opus 编码，录音存 `/sdcard/record/<name>.opus`
- 还有一整套 AT 命令（`AT+WIFIINFO`、`AT+BINF`、`AT+BATINF`、`AT+SETRESN=`、`AT+FACTORY` 等），走串口，不在 BLE 协议内

---

## 5. 对复刻的具体帮助

### 5.1 【关键】#6 快传 TCP 协议的命令集

#6 一直卡在"TCP 层协议尚未逆向"。固件的 `recpen_file_server` 把协议结构摊开了：

| 固件字符串 | 含义 |
|---|---|
| `start tcp file server` / `TCP File Server started on port %d` | 服务端由 BLE 侧命令拉起 |
| `wait cmd` → `recv_len = %d` | 连接后等待明文命令 |
| `list_files` | 列目录，范围是 `/sdcard/record`，过滤 `.opus` |
| `pull ` / `pull_file %s` / `pull:%d` | 拉取文件（`%d` 疑为 offset） |
| `send_file %s` / `send offset:%d,size:%d,total:%d` | 分片发送与进度 |
| `delete ` / `delete %s` | 删除 |
| `unknown %s,len=%d` | 未知命令的回复，**可用来探测命令边界** |

返回体 JSON 形态（与 BLE 侧 0x90 的 `{index, name, size, end}` 不同，字段更多）：

```
{"name":"%s","size":%d,"recd":%d,"rec":%d,"upload":%d}      // 列表项
{"name":"%s","size":%d,"index":%d,"end":%d}                 // 分片
{"name":"","size":0,...}                                    // 结束哨兵
```

**这把 #6 从"协议未知、要靠抓包猜"降级为"按已知命令集逐条验证"。** 建议把 §5.1 写进 #6 的方法部分。
注意：以上是静态字符串推断，命令的确切分隔符、大小写、是否带换行、`pull` 后参数格式都**没有实测**，必须在 #6 里用真机验证。

### 5.2 热点自动加入（#7 遗留问题）

查到官方用的是 `@capgo/capacitor-wifi` **8.3.1**。看它的 iOS 实现（开源，GitHub 可直接读）：

- 8.3.1 的 `connect()` 极其朴素：构造 `NEHotspotConfiguration`、`joinOnce = false`、`apply()`，回调无错就 `resolve()`。**没有校验是否真的连上，没有重试，没有处理 `alreadyAssociated`**
- 当前最新 8.5.9 的 `connect()` 加了三样东西：处理 `alreadyAssociated` 错误、带 deadline 轮询校验当前 SSID（默认超时 30 s，轮询间隔 0.5 s）、串行化并发连接请求

两条可用结论：

1. **我们的实现方向是对的**。V7 原型已经做了 `joinOnce=false` + 结果校验 + 重试 + `alreadyAssociated` 处理，和插件 8.5.x 的修复方向一致。插件演进本身就是"`apply()` 回调成功不等于真的连上"这一事实的佐证
2. **有一个我们没用的技术点**：插件用 `NEHotspotNetwork.fetchCurrent()?.ssid == expectedSsid` 来判定是否连上；我们的原型是**检查 Wi-Fi 地址是否落在卡的网段**。两者各有盲区 —— 加上 `fetchCurrent()` 可以区分"iOS 根本没切网"和"切了网但路由不通"，对定位 14 轮只成功 2 轮的原因有直接价值

**另外：官方 App 在 iOS 上大概率有同样的不稳定问题**（它用的 8.3.1 没有任何校验和重试），只是它的失败会被上层的"连热点超时 60 s + TCP 重试 6 次"兜住。这降低了"官方能稳连、我们不能"的担忧。
注意：APK 只能证明安卓侧用了这个插件，iOS 侧同版本是推断（Capacitor 插件跨平台同版本，`capacitor.config.json` 共用），未经证实。

### 5.3 协议文档可补的字段

固件里的 JSON 模板比我们 `PROTOCOL.md` 记的更完整，可以补：

| 位置 | 固件里的完整形态 | 我们现在记的 |
|---|---|---|
| 0x80 设备信息 | `{"sn","v","time","rec","recmode","usb","bat","df","total_df","bt","btaddr","wifiap"}` | `{sn, btaddr, bt, recmode, ...}`（省略号） |
| 0x81 开关状态 | `{"ms","led","motor","nc","wav","vad","gain","nn","autoff"}` | 只写了 "JSON" |
| 热点状态查询 | `{"on","ssid","connect","rssi","ip","mac"}` | **缺**，我们只记了 0x88 的设置方向 |
| 0x89 STA 上传 | 固件侧解析 `wifi_ssid` + `wifi_password` + `url` 三段 | 只记了 `{url}` |

另外固件证实了 BLE 侧的文件传输是 `ml_BleTransferFile name:%s offset:%d`，**支持 offset 续传** —— 与我们 0x70 的实现一致。

### 5.4 技术选型参考

- 官方把录音库存在 **SQLCipher**（加密 SQLite）里。我们的"离线优先"设计如果也要加密本地库，有现成先例可循
- 卡的固件支持 Wi-Fi STA 模式直传到 URL（`0x89`）。这是除 BLE 和热点快传之外的**第三条传输路径**，官方 App 用它配合云端；我们的自建后端理论上可以复用，值得记一笔

---

## 6. 风险与注意事项

固件里有几处**硬编码的敏感常量**（两个 32 字节十六进制密钥、`/private/aes_key` 路径、出厂测试用的热点密码、一个第三方云网关 `aurum-iot.rcrai.com` 及疑似凭据）。

- 具体值**不写入本仓库**，只留在证据目录 `firmware/firmware-strings.txt`（该目录不入 git）
- 复刻不需要这些值：热点密码是 App 每次随机生成后通过 `0x88` 下发的（V7 原型已实现 `generateWifiPassword(12)`），不依赖固件里的出厂默认值
- 本项目范围内不碰固件刷写和 OTA（`0xB0`/`0xB1`、`/sdcard/ota/`），固件分析仅用于理解设备行为

---

## 7. 结论

| 判断 | 结论 |
|---|---|
| 是否继续用 craft-anything | **保留，按需使用**。它的 Android DEX 工具快且准，适合"查某个类/方法怎么实现"这类定向问题。不替代 REA |
| 是否试它的 rebuild | 暂不。与既定路线冲突，且作者自标未成熟 |
| 本轮最大收获 | §5.1 的快传 TCP 命令集 —— 但这来自固件 `strings`，不是 craft-anything 的功劳。它的功劳是 §5.2 的插件版本定位 |
| 方法论教训 | 固件分析不要指望通用工具的签名识别。本轮两个专用固件工具 0 产出，而 `strings` 一条命令解决了卡了两个 issue 的问题 |

### 待办

- [ ] #6：按 §5.1 的命令集实测快传 TCP 协议
- [ ] 热点 issue：按 §5.2 第 2 点加入 `NEHotspotNetwork.fetchCurrent()` 判定
- [ ] `PROTOCOL.md`：按 §5.3 补全 JSON 字段（本 PR 不改，避免与 #17 / #18 的改动冲突）
