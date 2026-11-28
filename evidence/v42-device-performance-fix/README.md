# 本机转写与长录音同步修复验证

修复基线 `2a638e8`。本地 Swift 测试用 Xcode 27.0，在 Mac 上运行。真机为 iPhone 16、iOS 27.0，测试包为 DEBUG 0.1.0 (110)，通过本地 `CURRENT_PROJECT_VERSION=110` 构建。真机包编译时切片函数为私有，提交将可见性改为包内供 AAC 回归测试使用，运行逻辑相同。

## 本机转写 X9

判据为旧版失败的长语音样本能实际存入本机文字稿，多个切片保留全局时间，后半段有结果。T-M15-56 的两条真卡样本、锁屏、点击五句计时和全过程抓包仍以 `test-spec.md` §3.6.2 为准。

1. 在同一台手机原有的独立「闻笺验收」上原位装 DEBUG 110。保留时长 3,536.960 秒的 [公开中文节目](https://www.xiaoyuzhoufm.com/episode/671a25828326ba58067f27df)，SHA-256 为 `abb0903681dcf631c9c8a3a3ba31f2c617b463950f3f44f01ea6971be357d784`。此前 DEBUG 109 在同一输入未生成稿。[验收基线](https://github.com/HuiW86/dnote-recorder-reuse/tree/docs/42-device-acceptance/evidence/v72-link-import-device)
2. 从系统设置[关闭独立验收版的「无线数据」](wireless-data-off.png)，保留已启用的麦克风和语音识别，进入该音频的「文字稿」点「转成文字」。设备时间 2026-11-27 07:58:35（UTC+08:00）观察到本机转写中，保持 App 在前台。
3. 任务中通过 `xcrun devicectl device info files --domain-type appDataContainer --domain-identifier com.huiw86.revive.acceptance --subdirectory tmp` 观察到起点 `2,745,000 ms` 的中间 CAF，说明已进入 45:45 的片段。完成后用 `xcrun devicectl device copy from --source 'Library/Application Support/library'` 复制独立验收库，用只读 SQLite 查询 `transcript` 联接 `recording`，审计片段数与时间戳，并复算原 M4A 的 SHA-256。

**本样本通过。** 数据库有 `on-device`、`zh-CN` 的文字稿，08:05:50.356 入库，约 7 分 15 秒。193 段、8,341 字符，时间有序，首段 00:32.790、末段开始于 58:25.040，30 分钟之后有 85 段。此次核对了该样本的生成和时间覆盖。逐句听辨、字错率和网络抓包仍待验证。卡未参与这次转写。

原先短录音失败的 71.921 秒手机样本也复点一次。DEBUG 110 在 08:25:26 显示「没有识别到说话声」，详情页和「转成文字」按钮仍可用。该结果只验证了这个样本的提示和页面状态。

原实现把整文件交给一次识别。新版用 45 秒有效窗口，最多带前后各 1 秒的重叠上下文，各段保留原始录音时间。静音段不会抵消其他段的结果。系统请求仍强制在设备上识别。[Apple 的旧接口时长约束](https://developer.apple.com/documentation/speech/sfspeechrecognizer) · [本机识别设置](https://developer.apple.com/documentation/speech/sfspeechrecognitionrequest/requiresondevicerecognition)

## 长录音同步 T-M1-53

通过线为 ≥30 分钟的录音完整同步，吞吐在 19.2–28.8 KB/s。DEBUG 109 基线实测 15.7 KB/s。[基线日志及证据](https://github.com/HuiW86/dnote-recorder-reuse/tree/docs/42-device-acceptance/evidence/v42-long-card-recording)

- 本机 I/O 回放使用基线协议日志的 18,884 行及 18,811 个下载分片长度。用合成字节按原分片长度重放临时文件写入，交替执行 4 对。原逻辑每帧打开日志、每分片写临时文件。新版保留日志文件句柄，临时文件按 32 KiB 批写。两种路径的日志和数据字节完全一致。[实际回放输出](ble-io-replay.txt)
- 录音临时文件写入从 18,811 次降为 115 次，日志打开从 18,884 次降为 1 次。已有模拟卡用例仍通过断线后从准确偏移续传、只入库一份、清理临时文件与禁发命令检查。
- DEBUG 110 真机蓝牙速率以该轮实测结果为准。本机 I/O 回放只量了文件写入开销。

DEBUG 110 保留原 App 数据和同一张 v1.50 卡配对，iPhone 在 USB 供电下操作。确认「同步后删除卡上录音」关闭后，2026-11-27 08:12:41（UTC+08:00）用 App 发起录音。卡电量从 19% 降到 10%，08:38:41.743 报 `0x56 rec=0`，08:38:46.951 断开。断开前未发出这条文件的 `0x70` 下载。这条约 26 分钟的录音未达到 T-M1-53 的时长要求。[停录原始日志](card-low-battery.log)

接电后 App 自动重连并同步同一文件 `20261127081241.opus`。协议窗口 08:12:41.106–08:47:32.991，下载从 08:43:57.849 到 EOF，共 215.142 秒。完整收到 3,118,060 B 和 15,591 个连续分片，与卡清单一致。整次吞吐为 **14.153 KB/s**（用 1024 B 换算），最长连续前台段为 **14.100 KB/s**。434 个分片标为后台，15,157 个标为前台。窗口内没有四种禁发命令，也没有 `0x91`。[逐帧日志](card-reconnect-download.log)

手机 SQLite 仅有一条对应记录，时长 1,559 秒。OGG 完整解码，文件 SHA-256 与库一致，均为 `cfd9e8b405522cec04b1e2dd867ca9d64f8a8e47fdfc1c74a0a0787e7ebb8197`。协议原始节选 SHA-256 为 `db43a28066a71a0e40340e7d492ceee5ae6972d8a17798bfdaf7f84eb95cb858`。去除行尾空白后的入库节选为 `397bceb31d4efbfa66c9bfe588f25385a4df4fc826dfdefd92d9c0c89a4b214f`。

**T-M1-53 仍未通过。** 这次低电提前停止，续上的完整下载仍低于吞吐通过线。减少文件 I/O 的改动已验证，继续保持此用例的原判据。

同文件的 Mac 对照未测得速率。iPhone 暂时断开后，`client/dnote.py scan --timeout 8` 发现一张 v1.50 卡，电量 15%，RSSI −78 dBm。用 `client/dnote.py --address <本机扫描地址> pull --name 20261127081241.opus --out <本机临时目录>` 连接时返回 `BleakDeviceNotFoundError`，未开始下载。随后复扫没有发现卡。已在闻笺重新登记等待重连，见到状态 `connecting` 后退出调试页。这组观察还不能区分 iPhone 链路、录音卡链路参数和无线环境因素。

## 构建与回归

`xcodegen generate`、Xcode DEBUG 110 签名构建、`swift test --disable-xctest` 共 520 项，以及 `scripts/check-m1-rules.sh` 均通过。新增覆盖窗口边界、重叠区去重和时间偏移、实际 AAC 切片，以及断线后保存完整批次和未满批次并从准确字节偏移恢复。
