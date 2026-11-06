# dnote-recorder-reuse

脱离官方 App 与追觅云，复用追觅 D·NOTE（DNOTE001B）AI 录音名片硬件：通过蓝牙直连录音卡，控制录音、取回录音。

> **给接手的 agent / 开发者**：先读 [`docs/HANDOFF.md`](docs/HANDOFF.md)，它包含完整背景、已做结论、当前状态与下一步。本文件只给一分钟概览。

## 这是什么

追觅 D·NOTE 是一张信用卡大小的 AI 录音卡，录音/转写/总结依赖官方 App（DreameNote）+ 云端。当官方账号体系失效（登录需短信验证码，验证码已停发）时，硬件本身仍完好。本项目通过逆向官方 App，实现一个**完全离线**的替代客户端。

## 核心结论

- 官方 App 是 Capacitor（JS）应用，BLE 协议以近乎明文的 JavaScript 实现，已完整逆向，见 [`docs/PROTOCOL.md`](docs/PROTOCOL.md)。
- 设备侧只做录音/存储/传输；连接和取回录音**不以云端绑定为前提**。
- 录音为 16kHz 单声道 Opus；即便设备开启加密，密钥也可**离线推导**（`HMAC-SHA256(硬编码常量, 序列号)`），无需联网。
- 结论：可完全脱离官方 App 与追觅云复用硬件。

## 快速开始

```bash
cd client
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt

python dnote.py scan                 # 扫描识别录音卡（先按键唤醒）
python dnote.py info                 # 连接读设备信息
python dnote.py record --seconds 20  # 录 20 秒
python dnote.py list                 # 列出录音
python dnote.py pull --out ./recordings   # 下载并解密为 .ogg
```

## 目录

| 路径 | 内容 |
|---|---|
| `client/` | 离线客户端：命令行 + 协议库 + OGG 封装 |
| `docs/PROTOCOL.md` | 完整 BLE 协议规格 |
| `docs/HANDOFF.md` | 交接文档：背景、需求、现状、下一步、风险 |
| `docs/craft-anything-evaluation.md` | craft-anything 对官方 App 的二次分析；快传 TCP 命令集与固件画像 |

## 状态

协议逆向与客户端编码完成；离线可验证部分（解密、封装）已通过。**真机联调待完成**——需在装有蓝牙的电脑上连卡跑通 scan→record→list→pull。详见 `docs/HANDOFF.md` §现状。

## 法律与边界

仅用于复用**本人持有**的设备、取回本人的录音。逆向对象为自有设备的通信协议，用于互操作。请勿用于他人设备或分发受版权保护的固件。
