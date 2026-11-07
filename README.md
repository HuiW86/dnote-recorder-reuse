# dnote-recorder-reuse

脱离官方 App 与追觅云，复用追觅 D·NOTE（DNOTE001B）AI 录音名片硬件：做一个替代的 iOS App 和后端，让这一批卡的持有者重新用上配对、录音、同步、转写和 AI 总结。

> **给接手的 agent / 开发者**：先读 [`CLAUDE.md`](CLAUDE.md)（硬规则与文档地图），再读 [`docs/backend-design.md`](docs/backend-design.md)（总体设计与进度）。本文件只给一分钟概览。

## 这是什么

追觅 D·NOTE 是一张信用卡大小的 AI 录音卡，录音/转写/总结依赖官方 App（DreameNote）+ 云端。当官方账号体系失效（登录需短信验证码，验证码已停发）时，硬件本身仍完好。本项目通过逆向官方 App 的蓝牙协议，做一个**设备功能离线优先**的替代产品：配对、录音、同步、播放不依赖登录和网络；登录只用于转写、AI 和云同步。

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
| `app/` | 正式 iOS App（代号 Revive）：`ReviveKit/` 是各模块所在的 Swift Package，`project.yml` 用 XcodeGen 生成工程 |
| `client/` | Python 命令行客户端：协议库 + OGG 封装，真机验证用 |
| `ios-prototype/` | iOS 可行性原型（Swift），阶段 0 验证用 |
| `evidence/` | 真机验证证据（按验证编号分目录） |
| `docs/backend-design.md` | App 与后端总体设计、实施计划、验收与假设结论 |
| `docs/features.md` | 功能清单与范围对照表：官方功能 A1～O1 落到里程碑 M1～M4 |
| `docs/adr/` | 选型决策记录 |
| `docs/PROTOCOL.md` | 完整 BLE 协议规格 |
| `docs/official-app-analysis.md` | 官方 App 功能盘点 |
| `docs/competitor-analysis.md` | 竞品分析 |
| `docs/craft-anything-evaluation.md` | craft-anything 对官方 App 的二次分析；快传 TCP 命令集与固件画像 |
| `docs/HANDOFF.md` | 逆向阶段的交接文档：设备背景、逆向方法 |

## 状态

阶段 0（设备与平台可行性）已完成：离线配对、录音、蓝牙下载、解密、实时音频、WiFi 快传、iOS 原型均已真机跑通，证据见 `evidence/`。当前在阶段 1（规格与选型，#10）。进度以 GitHub milestone 和 issue 为准。

## 法律与边界

以下是逆向阶段的边界；产品定位改为多用户分发后需要重写，见 [`docs/adr/006-evidence-data-policy.md`](docs/adr/006-evidence-data-policy.md)。

仅用于复用**本人持有**的设备、取回本人的录音。逆向对象为自有设备的通信协议，用于互操作。请勿用于他人设备或分发受版权保护的固件。
