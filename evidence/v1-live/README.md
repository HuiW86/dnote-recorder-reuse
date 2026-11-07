# V1 实时录音验证（#4，假设 H2）

- 日期：2026-11-06
- 设备：DNOTE001B，固件 v1.50，sn `h7spab9m1novnz0415`，已绑定、加密开启
- 主机：macOS + bleak（`client/.venv`）
- 脚本：`client/probe_live.py`

## 命令

```bash
cd client
A=853BE462-3927-35DC-A23E-F592DFD35491
.venv/bin/python probe_live.py --address $A --method 51       --seconds 10
.venv/bin/python probe_live.py --address $A --method 54       --seconds 10
.venv/bin/python probe_live.py --address $A --method official --seconds 10
.venv/bin/python probe_live.py --address $A --method 51       --seconds 60 --repeat 3
```

每个目录含 `notify.jsonl`（全部通知；`0x68` 只留 8 字节头和音频哈希）与 `summary.json`。
`live.bin` / `live.ogg` 是现场录音，不入库，校验值见 `SHA256SUMS`。

## 判据与结果

| 运行 | 断开 | `0x68` 包 | 实收帧 | 期望帧 | 偏差 |
|---|---|---|---|---|---|
| `51-10s` | 否 | 116 | 464 | 460 | 0.92% |
| `54-10s` | 否 | 0 | 0 | — | — |
| `official-10s` | 否 | 124 | 496 | 492 | 0.79% |
| `51-60s-run1` | 否 | 743 | 2972 | 2968 | 0.14% |
| `51-60s-run2` | 否 | 743 | 2972 | 2968 | 0.14% |
| `51-60s-run3` | 否 | 744 | 2976 | 2972 | 0.15% |

期望帧 = 首末 `0x68` 时间差 / 20 ms；判据偏差 ≤ 5%。

- OGG：3 个 60 s 文件 ffprobe 读出 Opus、约 59.4 s，`ffmpeg -f null` 零错误；人工试听正常。
- 加密：TOC 字节仅 `0x4b`/`0x48` 两种，可直接解码 → 明文。
- 对照：卡上同时生成的 `20261106034631.opus`（加密）解密后 2950 帧，与 run1 实时流前 2950 帧逐帧一致。
- 停止后：`dnote.py record --seconds 5` 成功生成文件，`list` 正常列出。
- `official` 中补发的 `0x54` 在音频开始推送之后，卡未回复 `0x54`；`54-10s` 单独发送无任何响应。

## 结论

H2 成立。`0x51 [1]` 启动实时推流，`0x68` 稳定输出明文 Opus（4 帧/包，50 帧/秒），60 s 连续 3 次无断开。`0x54` 不是必要条件。协议细节见 `docs/PROTOCOL.md` §4.3、§5.1。
