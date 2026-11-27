# 本机转写与长录音同步修复验证

修复基线 `2a638e8`。本地 Swift 测试用 Xcode 27.0，在 Mac 上运行。真机为 iPhone 16、iOS 27.0，测试包为 DEBUG 0.1.0 (110)，通过本地 `CURRENT_PROJECT_VERSION=110` 构建。真机包编译时切片函数为私有，提交将可见性改为包内供 AAC 回归测试使用，运行逻辑相同。

## 本机转写 X9

判据为旧版失败的长语音样本能实际存入本机文字稿，多个切片保留全局时间，后半段有结果。T-M15-56 的两条真卡样本、锁屏、点击五句计时和全过程抓包仍以 `test-spec.md` §3.6.2 为准。

1. 在同一台手机原有的独立「闻笺验收」上原位装 DEBUG 110。保留时长 3,536.960 秒的 [公开中文节目](https://www.xiaoyuzhoufm.com/episode/671a25828326ba58067f27df)，SHA-256 为 `abb0903681dcf631c9c8a3a3ba31f2c617b463950f3f44f01ea6971be357d784`。此前 DEBUG 109 在同一输入未生成稿。[验收基线](https://github.com/HuiW86/dnote-recorder-reuse/tree/docs/42-device-acceptance/evidence/v72-link-import-device)
2. 从系统设置关闭独立验收版的「无线数据」，保留已启用的麦克风和语音识别，进入该音频的「文字稿」点「转成文字」。设备时间 2026-11-27 07:58:35（UTC+08:00）观察到本机转写中；保持 App 在前台。
3. 任务中通过 `xcrun devicectl device info files --domain-type appDataContainer --domain-identifier com.huiw86.revive.acceptance --subdirectory tmp` 观察到起点 `2,745,000 ms` 的中间 CAF，说明已进入 45:45 的片段。完成后用 `xcrun devicectl device copy from --source 'Library/Application Support/library'` 复制独立验收库，用只读 SQLite 查询 `transcript` 联接 `recording`，审计片段数与时间戳，并复算原 M4A 的 SHA-256。

**本样本通过。** 数据库有 `on-device`、`zh-CN` 的文字稿，08:05:50.356 入库，约 7 分 15 秒。193 段、8,341 字符，时间有序，首段 00:32.790、末段开始于 58:25.040，30 分钟之后有 85 段。此次核对了该样本的生成和时间覆盖。逐句听辨、字错率和网络抓包仍待验证。卡未参与这次转写。

原实现把整文件交给一次识别。新版用 45 秒有效窗口，最多带前后各 1 秒的重叠上下文，各段保留原始录音时间。静音段不会抵消其他段的结果。系统请求仍强制在设备上识别。[Apple 的旧接口时长约束](https://developer.apple.com/documentation/speech/sfspeechrecognizer) · [本机识别设置](https://developer.apple.com/documentation/speech/sfspeechrecognitionrequest/requiresondevicerecognition)

## 长录音同步 T-M1-53

通过线为 ≥30 分钟的录音完整同步，吞吐在 19.2–28.8 KB/s。DEBUG 109 基线实测 15.7 KB/s。[基线日志及证据](https://github.com/HuiW86/dnote-recorder-reuse/tree/docs/42-device-acceptance/evidence/v42-long-card-recording)

- 本机 I/O 回放使用基线协议日志的 18,884 行及 18,811 个下载分片长度。用合成字节按原分片长度重放临时文件写入，交替执行 4 对。原逻辑每帧打开日志、每分片写临时文件。新版保留日志文件句柄，临时文件按 32 KiB 批写。两种路径的日志和数据字节完全一致。[实际回放输出](ble-io-replay.txt)
- 录音临时文件写入从 18,811 次降为 115 次，日志打开从 18,884 次降为 1 次。已有模拟卡用例仍通过断线后从准确偏移续传、只入库一份、清理临时文件与禁发命令检查。
- DEBUG 110 真机蓝牙速率以该轮实测结果为准。本机 I/O 回放只量了文件写入开销。

## 构建与回归

`xcodegen generate`、Xcode DEBUG 110 签名构建、`swift test --disable-xctest` 共 520 项，以及 `scripts/check-m1-rules.sh` 均通过。新增覆盖窗口边界、重叠区去重和时间偏移、实际 AAC 切片，以及断线后保存完整批次和未满批次并从准确字节偏移恢复。
