# 让 AI 助手用录音库：`revive` 命令行与 MCP 服务

**用途**　`features.md` X19 的说明：`revive` 能做什么、怎么接到 AI 助手上、有哪些限制
**范围**　Mac（M5，#72）。代码在 `app/ReviveKit/Sources/LibraryTools/`（工具和 MCP 协议）和 `Sources/revive/`（命令行入口）
**日期**　2026-11-22
**借鉴**　beanpod 的 `Sources/beanpod/main.swift`（命令行与 MCP 服务，MIT）：工具集照它的六项（搜索、取一条、列待办、概览、存入文字、存入音频）；代码是重写的，没有复制

---

## 1. 是什么

`revive` 是一个命令行程序，直接读写闻笺 Mac 版的录音库（`~/Library/Application Support/com.huiw86.revive.mac/library/`）。它有两种用法：

- 在终端里查：`revive overview`、`revive search 关键词`、`revive get 编号`、`revive todos`，也能存入：`revive add-text`、`revive add-audio`
- 作为 MCP 服务（`revive mcp`）：支持 Model Context Protocol 的助手（Claude 桌面版、Cursor 等）启动它，通过标准输入输出调用下面的工具

它只做这几件事：不删除、不修改已有的录音，不连录音卡，不联网（`scripts/check-m1-rules.sh` 检查）。

## 2. 工具

| MCP 工具 | 命令行 | 做什么 | 会写入吗 |
|---|---|---|---|
| `search_recordings` | `search <关键词…>` | 在标题、文字稿、纪要里找，所有词都要出现，最新的在前 | 否 |
| `get_recording` | `get <编号> [--no-transcript]` | 一条录音的时间、来源、标签、人物、摘要、要点、待办、大纲、金句和带时间的文字稿（Markdown） | 否 |
| `list_todos` | `todos` | 所有纪要里没打勾的待办，按录音分组 | 否 |
| `library_overview` | `overview` | 各来源条数、未完成待办数、还没转文字的条数、常用标签、最近的录音 | 否 |
| `add_text_note` | `add-text [--title 标题] <文件或 ->` | 一段文字成为新的一条录音（没有音频，同 E2 的文字文件） | 新增一条 |
| `add_audio_file` | `add-audio [--title 标题] <文件>` | 一个音频文件成为新的一条（来源「导入」，转换同「文件」导入） | 新增一条 |

- 编号是录音 UUID 的前 8 位，也可以给完整的；重复时会提示多给几位。
- 「最近删除」里的录音不出现，也读不到。
- 写入的两项可以关掉：`revive mcp --read-only` 只提供前四个工具。
- 每个工具都带 MCP 的提示（`readOnlyHint`、`destructiveHint: false`），助手一般会在写入前问你。

## 3. 接到 Claude 桌面版

先编译（以后随 Mac 版的安装包提供，见 §5）：

```bash
cd app/ReviveKit && swift build -c release --product revive
```

然后在 Claude 桌面版的「设置 › 开发者 › 编辑配置」（`claude_desktop_config.json`）里加上：

```json
{
  "mcpServers": {
    "wenjian": {
      "command": "/完整路径/app/ReviveKit/.build/release/revive",
      "args": ["mcp"]
    }
  }
}
```

重启 Claude 桌面版后，可以直接问「我这周的会议里有哪些待办」「找一下讲离线同步的那条录音，总结一下」。录音库不在默认位置时，在 `args` 里加 `"--library", "/路径"`，或设环境变量 `REVIVE_LIBRARY`。

## 4. 隐私与限制

- **内容去了哪里**：`revive` 本身不联网，只把查到的文字交给启动它的助手。助手怎样处理这些文字（通常会发给它自己的模型服务），以那个助手的隐私政策为准。这和「设置 › AI 服务」一样，是用户自己选择的去处，开发者收不到。
- **闻笺开着的时候**：两边可以同时用。`revive` 写入时如果闻笺正在写，会等最多 5 秒。闻笺开着时不会自动出现 `revive` 新存的录音，重新打开闻笺后才看得到（数据库的变化通知只在同一个进程里）。
- **版本**：闻笺比 `revive` 新（数据库里有 `revive` 不认识的迁移）时，`revive` 只读，并说明原因；`revive` 比闻笺新时，它打开录音库会先做新增的迁移（迁移只增不改，`prd.md` §5），旧的闻笺照样能读。
- **iPhone 上没有**：iOS 不允许别的程序读 App 的数据，这个功能只在 Mac 上。

## 5. 还没做的

- 随 Mac 版一起安装：把 `revive` 放进 `ReviveMac.app`，在设置窗口里给一个「复制 Claude 桌面版配置」的按钮。要等 Mac 版的 PR（#125）合并后再接
- 真实助手里的验收（#72 的「一个支持 MCP 的助手能查到录音和待办」）：要一台装了闻笺 Mac 版和 Claude 桌面版的 Mac，见 `device-todo.md` §9
- 隐私政策：随 Mac 版发布时，公开版政策加一段「接入 AI 助手」
