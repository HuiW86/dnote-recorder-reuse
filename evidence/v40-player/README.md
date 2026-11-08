# #40 播放与导出：系统播放器读 OGG Opus、导出文件可被 ffprobe 识别 — 2026-11-07

## 环境

| 项 | 值 |
|---|---|
| 主机 | macOS 27.0，Swift Testing；FFmpeg 8.0.1（Homebrew） |
| 代码 | `feat/40-player` 分支（基于 #39），`Player` 模块（`app/ReviveKit/Sources/Player/Player.swift`） |
| 音频 | 系统 Opus 编码器生成的 440 Hz 正弦波（`CardTestSupport/SyntheticOpus.swift`，16 kHz 单声道，20 ms 一包），经 `OggOpus.wrap` 封装；不是卡上的录音，音频不入库 |

## 命令

```
cd app/ReviveKit
swift test --disable-xctest --filter PlayerTests
mkdir -p /tmp/v40 && REVIVE_EXPORT_DIR=/tmp/v40 swift test --disable-xctest --filter exportCopiesUnderTitle
F="/tmp/v40/2026-11-01 09.00.ogg"
ffprobe -v error -show_entries format=format_name,duration:stream=codec_name,sample_rate,channels -of default=nw=1 "$F"
ffmpeg -v error -i "$F" -f null - && echo "ffmpeg decode OK"
ffmpeg -i "$F" -af volumedetect -f null - 2>&1 | grep -E "mean_volume|max_volume"
shasum -a 256 "$F"
```

## 判据

- 播放：`AVAudioPlayer` 直接打开 OGG，时长 = 包数 × 20 ms − 312/48000 s（误差 < 2 ms）；暂停、拖动、播完复位可用。
- 导出：文件名为「录音标题.ogg」（`:` 换成 `.`），字节与库中 OGG 一致；ffprobe 识别为 ogg/opus，ffmpeg 完整解码且非静音。

## 结果

**通过（macOS）。**

```
codec_name=opus
sample_rate=48000
channels=1
format_name=ogg
duration=2.020000
ffmpeg decode OK
mean_volume: -13.5 dB
max_volume: -9.9 dB
sha256 12a6b71a145f22ab6e21e06aadc8ac670d16dd1d2dc8b3a4764adabb15681132
```

- 平均音量 −13.5 dB 与振幅 0.3 的正弦波理论值（0.3/√2 ≈ −13.5 dBFS）一致，说明解出的声音正确。
- 另做了对照：同一份 OGG，`AVAudioFile` 和 `AVAudioPlayer` 读出的时长正确，`AVURLAsset` 报 17.28 s，是错的。所以播放器用 `AVAudioPlayer`，不用 `AVPlayer`。

## 未覆盖（需真机）

- iOS 真机播放：后台播放、来电打断后暂停、拔耳机后暂停；卡上真实录音的播放与导出。手头 iPhone 为 iOS 27.0。
- **iOS 17～26 能否直接播放 OGG 没有验证**。处理方式：部署目标保持 iOS 17（ADR-001），`RecordingPlayer` 在 `AVAudioPlayer` 打不开文件（或读出时长为 0）时，用 `OggOpusDecoder` 把 OGG 解成 16 位 PCM CAF，存到录音库的 `decoded/` 目录，再播放这份副本，每条录音只解一次。删除录音时副本一起删除。解码回退已在 macOS 上用强制开关验证（见下节），还没有在 iOS 17～26 真机上跑过。

## 解码回退（2026-11-07，macOS 27.0）

命令：`swift test --disable-xctest --filter PlayerTests`（`decodesWhenDirectOpenIsUnavailable`、`undecodableAudioIsReported`、`demuxReadsHeadAndPackets`）

| 检查 | 结果 |
|---|---|
| 时长：包数 × 20 ms − 312/48000 s，误差 < 2 ms | 通过 |
| 峰值在 0.2～0.5 之间（振幅 0.3 的正弦波：不是静音，没有削波） | 通过 |
| 第二次播放复用缓存，不重新解码 | 通过 |
| 不是 OGG 的文件报 `cannotOpen`，状态回到 idle | 通过 |
| 解码中再次播放同一条：前一次让位（`CancellationError`），只留下一份完整副本（`overlappingPlaysWhileDecoding`，连跑 30 次） | 通过 |
| 删除录音时删掉副本；启动恢复删掉孤儿副本和 `.part`（`LibraryTests`） | 通过 |

调试时发现：macOS 27 的系统 Opus 解码器（16 kHz）会自己去掉开头 40 个采样（2.5 ms），`primeInfo` 却报告为 0。如果再按文件头的 pre-skip（312/48000 s = 104 个采样）全砍一遍，结果会短 2.5 ms。所以解码前先用前 10 个包测出解码器自己裁掉多少，pre-skip 只补差额。旧版系统的解码器如果不裁剪，测出来是 0，就按 pre-skip 全砍。用扫频信号对比，回退结果与 `AVAudioFile` 直接读取的结果长度一致（16216 个采样），偏移 1 个采样（对比时把 48 kHz 直接抽成 16 kHz 带来的相位差）。

## 真机检查步骤（2026-11-08：P1、P2、P3、P6 已跑，P4、P5 待跑）

入口：Debug 构建的 Card Debug 页。在「文件」区点按一个文件下载，校验通过后它会按 SyncEngine 的方式（解密 → 分帧 → 封装 OGG）存进单独的调试录音库（Application Support/`debug-library/`），出现在「播放」区。播放器的每次状态变化，以及系统的打断、线路变更通知，都会写进 `card-debug.log`。

| 编号 | 操作 | 通过判据（看日志） |
|---|---|---|
| P1 | 点按录音播放 | `✔ play`，时长 ≈ 录音帧数 × 20 ms；耳朵听到的是卡上录的内容 |
| P2 | 播放中锁屏或切到别的 App，等 30 秒 | 一直有声音；锁屏后状态仍为 `playing`，日志标签为 `[bg]` 或 `[lock]` |
| P3 | 播放中打进来一个电话（或响起闹钟），挂断 | `session interruption began` 之后紧跟 `player paused`；挂断后不自动继续播放 |
| P4 | 戴有线或蓝牙耳机播放，拔下或断开 | `session route change reason 2`（oldDeviceUnavailable）之后紧跟 `player paused` |
| P5 | 长按录音删除 | `library: deleted`，录音从列表消失 |
| P6 | 打开「强制解码回退」，播放同一条录音两次；再关掉开关播放一次 | 第一次 `via decoded PCM copy`，记录启动耗时（含解码）；第二次仍是 `via decoded PCM copy`，耗时很短（复用缓存）；听感、时长与直接打开一致；关掉后为 `OGG opened directly`。用来代替 iOS 17～26 真机，但它只证明回退在 iOS 27 的解码器上可用 |

### 结果（P1、P2、P3、P6）

环境：iPhone 12，iOS 27.2，Debug 包由 `b1b41d0` 构建；卡固件 v1.50。录音 `20261106034311.opus`（卡上 202060 B，5050 帧；入库 OGG 209880 B）。理论时长 5050 × 20 ms − 312/48000 s = 100.9935 s。

| 编号 | 结果 | 日志要点 |
|---|---|---|
| P1 | 通过 | `✔ play 0.11 s to start, duration 100.99 s, OGG opened directly`；人耳确认是卡上录的内容 |
| P2 | 通过 | 锁屏后 20:22:06.539 `player playing` → 20:23:47.545 `player idle`，连续 101.0 s，中间没有暂停；人耳确认声音清晰不断。日志只在状态变化时写一行，锁屏期间没有状态变化，所以没有 `[lock]` 标签的行，播完那行标签是 `[fg]`（判据中的标签一项无法从这份日志判断，以连续时长和人耳为准） |
| P3 | 通过（用计时器响铃打断） | 20:43:06.372 `session interruption began` → 20:43:06.385 `player paused at 53.53 s`；20:58:05 `session interruption ended` 之后没有自动继续 |
| P6 | 通过 | 强制解码开：第一次 `0.18 s to start … via decoded PCM copy`，第二次 `0.04 s`（复用缓存），时长都是 100.99 s；关掉开关后 `0.05 s … OGG opened directly`。对比 P1 直接打开 0.11 s，101 s 的录音解码只多出约 0.1 s，差别不算「明显」，所以判据改为如实记录耗时 |

P3 之后 20:54:24 有一行 `player idle at 0.00 s`，前后没有 `force decode`、`library: deleted`、`▶ play`，按代码只可能来自「停止」按钮（`CardDebugModel.stopPlayback`），不是暂停状态自己跳回 idle。

日志存为 `01-device-playback.log`，放进本目录前先按硬规则 4 检索原始 `sn`、`btaddr`。
