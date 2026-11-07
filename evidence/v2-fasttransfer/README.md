# 证据：#6 V2 WiFi 快传协议与吞吐

- 日期：2026-11-07 09:56–10:08（设备本地时间）
- 机型：iPhone 12，iOS 27.2
- 卡：序列号 `h7spab9m1novnz0415`，固件 `1.50`，电量 9–12%（测试中接 USB 充电，`usb=1`）
- App：`com.huiw86.dnoteprobe`，分支 `feat/6-fast-transfer`
- 原始日志：`probe.log`（本次会话的全部行），sha256 `b34204eb…6cc1e63`
- 样本：`20261106040350.opus`，15,180,060 B，7590 s 按键录音（#5 的同一文件）。音频本身不入库

## 方法

命令集来源是固件 `strings`（`docs/craft-anything-evaluation.md` §5.1），在真机上逐条验证。
全程只发 `list_files`、`get` 和一个无意义词；第 1 轮误发过两次 `pull`（当时误以为是下载），
卡回 `status=01` 拒绝，前后列表一致（22 个文件，见 `probe.log` 第 2 轮 `list-after`）。

```sh
# 构建、安装同 evidence/v21-hotspot/README.md
# 第 1、2 轮：探测线格式，回包原样存到 Documents/ft-probe/
xcrun devicectl device process launch --terminate-existing --device 00008101-001828D02686001E \
  com.huiw86.dnoteprobe --ft-probe
# 第 3 轮：同一次热点会话内连续下载 3 次
xcrun devicectl device process launch --terminate-existing --device 00008101-001828D02686001E \
  com.huiw86.dnoteprobe --ft-get 20261106040350.opus 3
# 取回下载结果，在 Mac 上用 client/ 的解密链路转 ogg
xcrun devicectl device copy from --device 00008101-001828D02686001E \
  --domain-type appDataContainer --domain-identifier com.huiw86.dnoteprobe \
  --source Documents/downloads/20261106040350.opus.ft.raw --destination /tmp/ftbig/20261106040350.opus.ft.raw
python3 evidence/v2-fasttransfer/mac-check.py /tmp/ftbig/20261106040350.opus.ft.raw
```

## 判据

1. 一致性：快传取得的原始字节与蓝牙下载的同一文件 sha256 相同；Mac 上解密封装后的 ogg 与 #5 的 ogg 相同
2. 吞吐：文件大小 ÷（发出 `get` 到最后一帧的耗时），≥ 3 次，均值 ≥ #5 蓝牙基线 23.60 KB/s 的 2 倍（47.2 KB/s）
3. 吞吐不含加入热点的时间（加入耗时单列）

## 结果

**三条判据全部满足，快传成立。**

| 次 | 耗时 | 吞吐 | 大小 | 与蓝牙原始字节 |
|---|---|---|---|---|
| 1 | 18.71 s | 792.34 KB/s | 15,180,060 | 一致 |
| 2 | 18.55 s | 799.21 KB/s | 15,180,060 | 一致 |
| 3 | 19.99 s | 741.71 KB/s | 15,180,060 | 一致 |

- 均值 **777.75 KB/s**，范围 741.71–799.21（−4.6% / +2.8%）
- 对 #5 Mac 蓝牙基线（23.60 KB/s，3 次）为 **33.0 倍**；对同一部 iPhone 的蓝牙下载（V7，`evidence/v7-ios/probe.log`，25.55 KB/s，**仅 1 次**）为 **30.4 倍**
- 原始字节 sha256 `ed0688d3…cef9f6b5`，与 iPhone 上 V7 蓝牙下载的 `20261106040350.opus.raw` 相同（App 内比对）
- Mac 解密封装后 ogg sha256 `c45eebf1…a7201968`，379,500 帧，无余数，与 #5 三次蓝牙下载相同（`mac-check.log`）
- 小样本交叉验证：第 2 轮 `get 20261106035009.opus`（8,060 B）解密后 200 个 Opus 包与蓝牙备份逐包相同
- 加入热点 3 次分别用了 78.7 s、53.0 s、44.8 s（`join 1 OK after …`），远长于传输本身。15 MB 文件端到端约 65–100 s，蓝牙约 580–645 s

## 线格式（已写入 `docs/PROTOCOL.md` §7）

- 请求是纯文本，不需要换行：`list_files`、`list_files\n`、`list_files\r\n` 三种写法回包完全相同
- 回包是二进制帧 `aa | type | status | len(u16 BE) | body`
- `get` 的块大小是 8192 B，每块带 2 字节字段。它在 1854 块里有 1833 种取值，像校验值，
  但不是常见的 CRC16（CCITT-FALSE、XMODEM、KERMIT、MODBUS、ARC、X25、AUG-CCITT、BUYPASS）。**算法未知，未使用**

## 未覆盖

- `pull`（上传到卡）、`delete`、`quit` 没有验证：前两个会写卡，复刻 App 也不需要
- 卡电量低（9–12%）且在充电；满电、不充电时的吞吐没测
- 后台、锁屏下的快传没测（V1 的后台结论不能直接套用到 Wi-Fi）
