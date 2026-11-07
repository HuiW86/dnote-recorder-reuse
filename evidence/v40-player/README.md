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
- **iOS 17～26 能否直接播放 OGG 没有验证**，而部署目标是 iOS 17。如果低版本不支持，需要改用原型的方案（`AVAudioConverter` 解码，见 `evidence/v7-ios/opuscheck.swift`），或者提高最低支持版本。
