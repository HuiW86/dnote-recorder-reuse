# dnote-recorder-reuse

闻笺（Revive）是一款离线优先的录音工作台，适用于 D·NOTE 录音卡（DNOTE001B）。iPhone 可以通过蓝牙配对、录音、同步和播放，也可以用手机麦克风录音、导入文件。Mac 版可以导入和整理这台 Mac 上的录音。

**开发入口**　[架构、数据流与首跑指南](docs/architecture.md) · [开发约定](CLAUDE.md) · [2026-11-26 全仓审计](docs/audit-2026-11-26.md)

## 这是什么

项目始于官方 App 的短信登录中断后，持卡人仍需要取回自己的录音。闻笺通过蓝牙直连，设备功能可以在无账号、无互联网连接时使用。转写可选 Apple 本机识别，或将音频交给用户配置的 AI 服务。纪要由用户配置的服务处理文字稿。仓库中的闻笺账号后端单独运行。

## 核心结论

- 协议来自对官方 Capacitor 应用及设备通信的分析。已验证的命令、帧格式与固件差异记录在[协议文档](docs/PROTOCOL.md)。
- 真机样本使用 v1.50 固件。蓝牙下载、离线解密和 OGG Opus 封装都已在该样本上验证。[实验记录](evidence/)和[待验收清单](docs/device-todo.md)给出各项证据与条件。

## 快速开始

从仓库根目录运行以下命令，可在装有 Xcode、Swift 6 工具链的 Mac 上测试核心模块。测试使用模拟卡，无需配对或启动后端。

```bash
(cd app/ReviveKit && swift test --disable-xctest)
```

如需用 Python 客户端连接自己的录音卡，按键唤醒后执行下列命令。

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

iOS、Mac、CLI/MCP 和后端的构建与验证方式见[首跑指南](docs/architecture.md#本地开发与验证)。

## 目录

| 路径 | 内容 |
|---|---|
| `app/` | `Revive/` 是 iOS App，`ReviveMac/` 是原生 Mac App，`ReviveKit/` 是共享 Swift Package，包含本地 CLI/MCP 可执行程序 `revive` |
| `backend/` | FastAPI 服务、后台任务进程与 PostgreSQL 迁移，见[后端接口与运行说明](backend/README.md) |
| `client/` | Python 命令行客户端：协议库 + OGG 封装，真机验证用；`probe_*.py` 是真机探测脚本 |
| `ios-prototype/` | iOS 可行性原型（Swift），阶段 0 验证用，不再开发；保留是为了能复现 `evidence/v7-ios/`（硬规则 6） |
| `scripts/` | `check-m1-rules.sh`：禁发命令字与 M1 模块不联网的静态检查；`check_evidence.py`：证据脱敏检查；`check-theme.sh`：界面颜色只取 Theme（两个 CI 都跑）；`shots.sh`：模拟器截图；`build_privacy_page.py`：生成公开隐私政策页 |
| `design/` | App 图标原图 |
| `evidence/` | 真机验证证据（按验证编号分目录） |
| `HANDOFF.md` | 最近一次开发会话的交接：做完了什么、下一步、风险 |
| `docs/backend-design.md` | App 与后端总体设计、实施计划、验收与假设结论 |
| `docs/features.md` | 功能清单与范围对照表：官方功能 A1～O1 落到里程碑 M1～M4 |
| `docs/prd.md` | 数据模型、接口契约、状态机 |
| `docs/product-spec.md` | 页面清单、流程、界面状态与错误提示 |
| `docs/test-spec.md` | 测试策略、用例、真机证据格式 |
| `docs/adr/` | 选型决策记录 |
| `docs/release/` | TestFlight 要填的内容、公开隐私政策草稿 |
| `docs/PROTOCOL.md` | 完整 BLE 协议规格 |
| `docs/official-app-analysis.md` | 官方 App 功能盘点 |
| `docs/official-ui-walkthrough.md` | 官方 App 的页面走查 |
| `docs/competitor-analysis.md` | 竞品分析 |
| `docs/craft-anything-evaluation.md` | craft-anything 对官方 App 的二次分析；快传 TCP 命令集与固件画像 |
| `docs/HANDOFF.md` | 逆向阶段的交接文档（历史文档）：设备背景、逆向方法 |

## 状态

- **设备与 iOS**　正式 App 已实现蓝牙同步、本地播放和导出。实时音频与 Wi-Fi 快传另有阶段 0 实验。内部 TestFlight 与真机验收进展见[验收跟踪](https://github.com/HuiW86/dnote-recorder-reuse/issues/42)。
- **Mac 与助手**　原生 Mac App 已实现本地录音库、播放、导入、转写和纪要。`revive` 提供本地命令行和 MCP 标准输入输出服务。[接入说明](docs/assistant-tools.md)
- **闻笺后端**　主干包含账号、设备登记、分片上传、异步转写与纪要、用量接口。iOS 账号入口默认隐藏，账号录音上传和任务轮询尚待 App 接入。开发后端使用本地存储和替身服务，生产部署另需真实服务配置。[后端现状](backend/README.md)

## 法律与边界

以下是逆向阶段的边界；产品定位改为多用户分发后需要重写，见 [`docs/adr/006-evidence-data-policy.md`](docs/adr/006-evidence-data-policy.md)。

仅用于复用**本人持有**的设备、取回本人的录音。逆向对象为自有设备的通信协议，用于互操作。请勿用于他人设备或分发受版权保护的固件。
