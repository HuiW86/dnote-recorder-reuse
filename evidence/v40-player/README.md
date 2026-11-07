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
