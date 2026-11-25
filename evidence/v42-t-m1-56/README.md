# T-M1-56 真机覆盖升级

对应 #42。判据来自 `docs/test-spec.md` §3.4。测试从手机现有的 TestFlight 构建开始。

## 环境

| 项目 | 记录 |
|---|---|
| 目标源码 | `2a638e8591406459a4f4232e3d1044474d44579c`（远端 main），仅调整 `CURRENT_PROJECT_VERSION` |
| 构建工具 | Xcode 27.0 (`27A266a`)，Release，iOS 真机目标 |
| 目标 TestFlight 构建 | `0.1.0 (109)`。2026-11-25 核对 App Store Connect 的上传历史和 iOS 内部测试构建列表，最新为 `0.1.0 (108)` |
| 升级来源 | `0.1.0 (108)`，用户在旧版闻笺「设置 → 关于」核对，iPhone Use 复核并截图。本机同号归档标记源码 `b130ab8`，其迁移到 `v15` |
| iPhone 型号、iOS 版本、电量与充电状态 | iPhone 16，iOS 27.0，通过 USB 连接 Mac 并充电。旧版关于页 35%，升级后诊断导出时 56% |
| 卡固件、电量与充电状态、脱敏标识 | 固件 v1.50、硬件 v0.1，卡序列号 SHA-256 前 8 位 `7036aa3b`。备份前广播 100%，升级前后日志分别为 99% 和 98%，恢复蓝牙后 97%。卡的充电状态未取证 |
| 卡上录音备份 | `client/dnote.py pull` 退出码 0；48 段均下载完成，每段下载字节数与卡的文件清单一致，FFmpeg 全量解码 48/48。录音保存在本机仓库外；[备份文件校验值](card-backup-sha256.txt) 每行是排序序号、文件字节数、SHA-256 |

## 步骤及判据

1. 确认卡的固件为 v1.50 后运行 `python client/dnote.py pull --out <本机备份目录>`，核对下载结果。保留旧版安装，记录旧版构建号、同一条已有录音的时长与可播放性、已有星标、文件夹、文字稿、纪要及现有的录音卡配对关联。本轮在 108 的既有测试文档 `dnote-long-pagination` 上加星标并移入新建的「验收 T-M1-56」文件夹。
2. 在 TestFlight 直接更新闻笺。确认新构建号，打开原有录音，复核第 1 步所记各项。同一张卡能沿用原配对连接。
3. 新建一条手机测试录音，加一个重点，保存后重新打开详情，确认可播放且重点仍在。目标构建在 `v16` 加入 `phone_mark` 表。原有数据仍可读以及新表可写可读，作为数据库迁移成功的真机观察。
4. 在「录音卡 → 设置」导出 `revive-diagnostics.txt`，核对新构建号、连接和数据库打开失败记录。当前诊断格式只在打开数据库失败时记原因，以第 2、3 步验证正常路径。

通过需同时满足原位升级、原有录音可播放、数据和配对保留、迁移后可读写，以及已留取可核对证据。旧版无某种样本时，单独记录该覆盖缺口。

## 构建检查和结果

| 命令 | 结果 |
|---|---|
| `cd app && xcodegen generate` | 退出码 0 |
| `cd app/ReviveKit && swift test --disable-xctest` | 退出码 0，13 份运行报告共 516 个通过 |
| `scripts/check-m1-rules.sh` | 退出码 0，输出 `OK: M1 static rules pass` |
| `xcodebuild archive -project app/Revive.xcodeproj -scheme Revive -configuration Release -destination 'generic/platform=iOS' -archivePath <本机归档路径>` | 退出码 0，输出 `ARCHIVE SUCCEEDED` |
| `codesign --verify --strict <归档>/Products/Applications/Revive.app` | 退出码 0；归档内 Bundle ID 为 `com.huiw86.revive`，版本为 `0.1.0 (109)` |
| `xcodebuild -exportArchive -archivePath <归档> -exportPath <本机目录> -exportOptionsPlist <上传选项> -allowProvisioningUpdates` | 退出码 0，输出 `Upload succeeded.`、`Uploaded Revive`、`EXPORT SUCCEEDED` |

归档内签名后二进制 `Revive` 的 SHA-256 为 `100fe7a16076898e14f29361b4decf1990cf700a04069db15ecf4621147cd34c`。Apple 分发时会重新签名。

上传选项为 `method=app-store-connect`、`destination=upload`、`signingStyle=automatic`、`manageAppVersionAndBuildNumber=false`、`testFlightInternalTestingOnly=false`。2026-11-25 07:52（Mac 本地时间）Xcode 确认上传成功。随后在 App Store Connect 确认 109 已处理并关联现有内部测试群组。

## 真机结果

| 检查 | 原始观察 |
|---|---|
| 原位升级 | iPhone 上的 TestFlight 最初显示 `0.1.0 (108)` 和「打开」。刷新列表后显示 `0.1.0 (109)` 和「更新」，点击「更新」，等到「打开」后启动。App 直接进入标签栏。版本截图：[108](build-108-about.jpg)、[109](build-109-about.jpg) |
| 旧录音库、文字稿和纪要 | 新录音写入前，108 和 109 均显示 `录音 (58)`。同一条 8 分 25 秒录音的旧文字稿保留在 `00:08:21`，纪要仍可打开。旧版播放控件读回 `0.725 → 2.990 → 4.105 s`，新版读回 `0 → 2.267 → 3.628 s`。用播放器状态和进度核对，未单独听验音质 |
| 星标与文件夹 | 测试文档仍显示星标和同一文件夹。截图：[升级前](build-108-fixture.jpg)、[升级后](build-109-fixture.jpg) |
| 设备与配对 | 同一张 v1.50 卡在旧版 00:03:12 连上，在新版首次打开时 00:17:12 连上。为手机录音暂时关闭蓝牙，恢复后 00:26:17 再次连上，全程沿用原配对。时间来自手机日志（UTC+08:00）。[本轮诊断节选](diagnostics-109.txt) |
| 数据库迁移 | 新版保存一条 34 秒手机测试录音，退出录音页后从总览重新打开，「文字稿 → 重点」仍显示 `00:00:32`，点它后播放位置为 `32.633 s`。[重点截图](build-109-phone-mark.jpg)；Mac 组件测试 `v15LibraryUpgradesToV16`、`v1LibraryUpgradesToTheLatest` 均通过 |

在「录音卡 → 设置 → 导出诊断信息」通过隔空投送取得完整诊断。文件首行为 `闻笺 0.1.0 (109), iOS 27.0, iPhone`，635 行，未出现 `library unavailable`。完整文件保存在本机，SHA-256 为 `e7513fa07c20aea9c8f944929a2f9c9fc843832fb16326fa9a92953453ed7bcb`。[入库节选](diagnostics-109.txt)保留本轮配对、断开和重连原始记录。

**结论：通过。** 适用于 iPhone 16 / iOS 27.0、TestFlight `0.1.0 (108) → 0.1.0 (109)`、一张固件 v1.50 卡。从构建 1 直接升级仍待真机验证。
