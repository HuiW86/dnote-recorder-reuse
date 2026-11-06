# 竞品分析：AI 录音硬件的设备功能与账号、云端的关系

- 目的：决定"设备功能离线优先（配对、录音、同步、播放不依赖登录和网络；登录只用于 AI 能力和云同步）"是否作为我们 App 的第一原则，并收集可借鉴的产品设计
- 调研范围：主流付费产品 4 个、停服/收购案例 3 个（含 D·NOTE 对照）、开源方案 1 个
- 方法：3 个子代理并行检索公开资料，所有来源访问日期均为 **2026-11-05**；查不到的标"未知"
- 配套文档：官方 App 功能盘点见 [`official-app-analysis.md`](official-app-analysis.md)

---

## 1. 对比总表

| 产品 | 不登录能否录音 | 不登录能否传到手机、播放 | 账号在哪一步绑定 | 传输方式 | 转写在哪 | 原始音频导出 | 停服后设备 |
|---|---|---|---|---|---|---|---|
| Plaud Note / NotePin | 能（离线） | **不能** | App 内配对时，一台设备同时只能绑一个账号 | 蓝牙；WiFi 快传；初代 Note 可 USB | 云端 | MP3、WAV | 条款保留随时停服权利，未说明设备去留 |
| 钉钉 A1 | 能（离线） | **不能**（社区来源） | 开箱用钉钉 App 扫码激活时 | 蓝牙；WiFi 直连 | 云端 | MP3、WAV；机内存的是 DTYJ 封装的 Opus | 未知 |
| 讯飞 SR702 星火版 | 能 | 能（自带屏幕，可本机播放；USB 拷贝） | 开机引导有"注册/登录激活云空间"，能否跳过未知 | 4G/WiFi 上云；USB | **本机离线转写** + 云端（大模型摘要仅在线） | WAV、AAC，USB 直接拷 | 无官方声明；能离线转写和 USB 导出，推断仍可用 |
| TicNote | 能（离线） | **不能** | 建账号后才能配对 | 蓝牙；WiFi 热点快传 | 云端 | MP3、WAV（另有一处说 Ogg） | 未知 |
| Omi（开源） | 能（写入 SD） | 引导流程是先登录再配对，免登录路径未见文档 | 配对前（Firebase Auth） | 蓝牙实时流 + 蓝牙拉取存储文件；WiFi 芯片未启用 | 云端为主；可切自建/端侧 Whisper（仅实时） | 开发者 API 导出 JSON；完整导出需找客服 | 后端开源可自部署，但官方 App 绑定官方后端 |
| Humane AI Pin | — | — | — | — | 云端 | 停服前 10 天内经 WiFi 下载 | **停服后只剩电量查看等功能** |
| Limitless Pendant | 能（设备存约 35 小时） | 依赖官方 App | — | 蓝牙 | 云端 | 帮助中心下载，部分地区限期导出 | 承诺支持到 2026 年底，之后未知；社区靠逆向蓝牙 + 本地 Whisper 救回 |
| **追觅 D·NOTE** | 未配对时 App 命令录音被拒（真机）；按键录音未确认 | 官方 App 不登录不能用 | App 内绑定时，绑定码由云端下发 | 蓝牙；WiFi 快传 | 云端 | 官方 App 未知；我们已实现蓝牙下载 + 解密 | **官网仍在，App 与后台已失效，无任何公告** |

## 2. 关键发现

1. **主流做法是"录音离线、其余全部绑账号"。** Plaud、钉钉 A1、TicNote、Omi 都在配对这一步就要求登录。设备能离线录音，但录音传不到手机，用户实际上拿不到自己的数据。D·NOTE 官方 App 也是这个模式，这正是它失效的直接原因：短信验证码收不到 → 登录不了 → 配对不了 → 整张卡不可用。
2. **唯一的反例是讯飞 SR702。** 录音、转写、播放、导出全部可以在本机完成，账号只用来开通云空间和大模型摘要。同厂的 SR302 Pro 甚至没有无线模块，完全不需要激活。
3. **停服案例都指向同一个教训：** 登录和云端是单点故障。
   - Humane 停服前只提前约 10 天通知，导出也依赖官方服务器，停服后设备基本成了砖头；
   - Limitless 被收购后能用多久全看收购方，社区靠逆向蓝牙协议才把设备救回来；
   - D·NOTE 是"静默失效"：官网还在，没有公告、没有导出窗口、没有退款，比公告停服更糟。
4. **蓝牙加 WiFi 快传是这一类产品的标准配置。** Plaud、钉钉 A1、TicNote 都是蓝牙为主、WiFi 快传传大文件，和 D·NOTE 一致。这说明 WiFi 快传值得做，也说明长录音只靠蓝牙传输体验会很差。
5. **设备文件同步是高风险区。** Omi 的 SD 卡同步出过多个 bug：断连重连后误报传输完成、传输中途超时中断、两套同步机制混用。Plaud 传完就删设备文件，同样要求"确认落到手机后才删"。
6. **社区逆向很常见。** 钉钉 A1、Limitless 都有社区开源工具绕开官方 App 直接走蓝牙。这说明"厂商停服后用户靠协议自救"有真实需求，也说明我们的做法有先例。

## 3. 对"离线优先原则"的建议

**建议采纳，作为 App 的第一原则：**

> 配对、录音控制、把录音同步到手机、播放、导出原始音频，这些设备功能**不依赖登录和网络**。登录只用于转写、AI 生成、AI 对话和云同步。

理由：

1. **这是 D·NOTE 失效的根本原因。** 我们复刻它，就不能再把同一个单点故障带回来。
2. **能形成差异。** 主流竞品（Plaud、钉钉、TicNote、Omi）都把配对放在登录之后，只有讯飞做到了本地闭环。对这批已经被"失效"伤过一次的用户来说，"不登录也能用"本身就是价值。
3. **和已定的决策不冲突。** 账号体系照样参考官方做全，后端统一管理 API Key；只是把账号的位置从"配对之前"挪到"使用 AI 功能之前"。
4. **技术上已经可行。** 配对用的绑定码可以在本地生成（真机已验证），解密密钥可以离线算出，这条路径本来就不需要后端。

需要注意的影响：

- **绑定码要做本地备份和云端备份两份。** 不登录时存在本地；登录后同步到后端，换手机时可以恢复。如果用户从未登录、手机又丢了，就只能解绑后重新配对。
- **"一台设备只能绑一个账号"这类限制先不做。** 竞品都用这一条防止二手设备被盗用，但我们暂不考虑商业闭环，第一版可以只靠设备上的绑定状态；这一条留给需求文档讨论。
- **iOS 审核**：App 内有注册账号就必须提供 App 内注销，离线可用不影响这一要求。

## 4. 可借鉴的设计

| # | 设计 | 来源 | 用在哪 |
|---|---|---|---|
| 1 | 设备文件**确认已经落到手机后才删除**；同步做成幂等、可续传，按 id 而不是按对象匹配 | Omi（踩过的坑）、Plaud | 蓝牙同步、WiFi 快传 |
| 2 | 蓝牙为主，大文件自动切换 WiFi 快传 | Plaud、钉钉 A1、TicNote | 文件同步 |
| 3 | 实时转写走 WebSocket，URL 里显式带 codec 和采样率；断线时本地保留数据，重连后补传 | Omi `/v4/listen` | 实时转写 |
| 4 | 语音识别服务做成可插拔：云厂商 API、自建（FunASR）、端侧 | Omi | 后端转写模块 |
| 5 | 会话结束后由大模型生成结构化摘要、待办、要点 | Omi | AI 生成模块（与官方 App 的总结、金句对应） |
| 6 | 第一版就提供**用户自助的全量导出**：原始音频 + 转写 + 总结，开放格式 | Omi 的反例（要找客服）、Humane 的教训 | 设置页、数据导出 |
| 7 | 本机播放和导出原始音频完全离线可用 | 讯飞 SR702 | 录音详情页 |
| 8 | 停服或迁移时给出明确的导出窗口和公告机制 | Humane、Limitless 的反例 | 运营预案（后期） |

## 5. 未知项与来源可靠性

- **停服后设备能否使用**：钉钉 A1、TicNote 未知；讯飞无官方声明，"仍可用"是推断；Plaud 只有一般性停服条款。
- **能否跳过登录**：讯飞开机引导能否跳过、Omi 有无免登录路径，均未知。
- **说法互相矛盾**：Plaud 经销商页称"无需账号"并提到本地模式，与官方"配对前先登录"矛盾；TicNote 导出格式官方写 MP3/WAV，亚马逊写 Ogg；钉钉 A1 免费额度有 300、1000、1300 分钟三种说法。
- **来源可靠性**：Plaud 帮助中心"离线使用""导出"两页抓取被拒（403），相关结论来自搜索摘要和经销商页面；钉钉 A1 的激活流程和导出格式主要来自知乎、什么值得买等社区文章。
- **D·NOTE**：运营主体（支持邮箱为 `lingpo.tech`）、ICP 备案主体、官方服务状态、用户报告、导出和退款政策，都没有找到公开信息。

## 6. 主要来源

| 产品 | 来源 |
|---|---|
| Plaud | support.plaud.ai/hc/en-us/articles/50947163085337-Bind-the-device ；support.plaud.ai/hc/en-us/articles/50947269502105-Transfer-files ；docs.plaud.ai/plaud-embedded/overview ；plaud.se/en/faq（经销商）；uk.plaud.ai/pages/terms-of-service ；plaud.ai/pages/plaud-ai-plan-pricing |
| 钉钉 A1 | zhuanlan.zhihu.com/p/1953438219329856708（社区）；baike.baidu.com/item/DingTalk%20A1/66338411 ；sspai.com/post/102091 ；post.smzdm.com/p/aqklq9rx/（社区）；github.com/Shawn-TKD/dingtalk-a1-pc-tools |
| 讯飞 SR702 | post.smzdm.com/p/axop5m5d/ ；dcdv.zol.com.cn/783/7836591.html ；kafan.cn/edu/22161502.html ；donews.com/news/detail/5/3175415.html（SR302 Pro） |
| TicNote | manuals.plus/mobvoi/mobvoi-ticnote-app-manual ；mrktcorrect.com/blog/ticnote-review ；ticnote.ai/pages/faq ；ticnote.com/en/membership |
| Omi | docs.omi.me/doc/hardware/DevKit2 ；docs.omi.me/doc/hardware/OmiConsumer ；docs.omi.me/doc/developer/Protocol ；docs.omi.me/doc/developer/backend/transcription ；docs.omi.me/doc/developer/backend/backend_deepdive ；docs.omi.me/doc/developer/backend/Backend_Setup ；help.omi.me/en/articles/13135362-first-steps ；github.com/BasedHardware/omi（issues 22412、22785，PR 24678） |
| Humane AI Pin | macrumors.com/2025/02/18/humane-ai-pin-discontinued/ ；engadget.com/ai/all-of-humanes-ai-pins-will-stop-working-in-10-days-225643798.html ；techcrunch.com/2025/02/22/the-fallout-of-hps-humane-acquisition/ |
| Limitless | limitless.ai ；cnbc.com/2025/12/05/meta-limitless-ai-wearable.html ；help.limitless.ai/en/articles/10761340-pendant-storage ；github.com/aldrinjenson/pendant-sync（社区） |
| D·NOTE | dreamenote.cn ；163.com/dy/article/KT08GG8Q0511B8LM.html ；finance.sina.com.cn/tech/it/2026-05-15/doc-inhxyptn3232644.shtml |
