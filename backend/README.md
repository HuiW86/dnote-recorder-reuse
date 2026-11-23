# 后端（M2）

闻笺的后端：账号、设备登记、意见反馈、录音上传、转写、AI 纪要（`docs/prd.md` §7、§8）。选型见 ADR-002、ADR-003，库与版本见 ADR-012，任务队列见 ADR-013。

App 没登录时不调用这里的任何接口；设备功能（配对、录音、同步、播放、导出）完全不依赖后端（`CLAUDE.md` 硬规则 3）。

## 现在有什么（第一到五片）

| 模块 | 接口 | 对应 |
|---|---|---|
| 账号 | `POST /v1/auth/sms/send`、`/sms/login`、`/email/register`、`/email/verify`、`/password/login`、`/password/reset/send`、`/password/reset`、`/refresh`、`/logout` | K1 |
| 当前账号 | `GET /v1/me`、`POST /v1/me/password`、`DELETE /v1/me`（注销，删除全部数据） | K1 |
| 用量 | `GET /v1/me/usage`；转写、纪要超额 `429 quota_exceeded`，排队任务太多 `429 too_many_tasks` | X2（额度数值未定） |
| 设备登记 | `GET /v1/devices`、`PUT /v1/devices/{sn_hash}`、`DELETE /v1/devices/{sn_hash}` | A4b |
| 录音与上传 | `POST /v1/recordings`、`GET /v1/recordings`、`GET /v1/recordings/{id}`、`DELETE /v1/recordings/{id}`、`POST /v1/recordings/{id}/upload`、`/upload-complete`、`GET /v1/recordings/{id}/audio-url` | §7.2，X3 的后端部分 |
| 转写 | `POST /v1/recordings/{id}/transcribe`、`GET /v1/recordings/{id}/transcript`、`PATCH /v1/recordings/{id}/speakers` | F1（识别引擎暂用替身） |
| AI 纪要 | `POST /v1/recordings/{id}/summaries`、`GET /v1/recordings/{id}/summaries`、`GET /v1/templates` | G1、G2a（大模型暂用替身） |
| 任务 | `GET /v1/tasks/{id}`；工作进程 `python -m revive_api.worker` | §7.4，ADR-013 |
| 意见反馈 | `POST /v1/feedback` | O1b |
| 通用 | 统一错误结构、写操作的 `Idempotency-Key`、`GET /healthz` | §7.1、§7.3 |

还没有：真实的识别引擎和大模型、换角度重起标题。额度的数值还没定（`REVIVE_ASR_MONTHLY_SECONDS`、`REVIVE_LLM_MONTHLY_TOKENS`，不设表示不限，生产环境必须设）。

**替身**：短信、邮件、COS、KMS、ASR、大模型要腾讯云账号（ASR 和大模型还要等 `docs/asr-evaluation.md`、`docs/summary-evaluation.md` 的对比）。识别引擎现在是 `StandInTranscriber`，文字稿只有一句「替身转写」；大模型是 `StandInChatModel`，纪要只摘开头两句。现在验证码由 `LoggingSender` 打到日志里，音频由 `LocalStore` 存在 `REVIVE_STORAGE_DIR`（默认 `backend/.storage/`）并由本服务在 `/dev-storage` 下按签名地址收发（这几个替身在生产环境都会拒绝启动），绑定码用环境变量里的密钥加密。账号到位后各自换成真实实现（`revive_api/runtime.py` 的 `CodeSender`，`storage.py` 的 `ObjectStore`，`asr.py` 的 `Transcriber`，`llm.py` 的 `ChatModel`，`security.py` 的 `Box`）。

## 本机运行

需要 Python 3.12+ 和 PostgreSQL 16。

```bash
cd backend && python3 -m venv .venv && .venv/bin/pip install -e ".[dev]"
```

```bash
export REVIVE_DATABASE_URL=postgresql+psycopg://postgres@127.0.0.1:5432/revive
export REVIVE_JWT_SECRET=... REVIVE_CODE_SECRET=... REVIVE_SN_PEPPER=...   # 各至少 32 个字符
export REVIVE_BOND_KEY=$(python3 -c "import base64,os;print(base64.b64encode(os.urandom(32)).decode())")
```

```bash
.venv/bin/alembic upgrade head
```

```bash
.venv/bin/uvicorn revive_api.main:app --reload
```

接口文档在 `http://127.0.0.1:8000/docs`。不在 8000 端口跑时设 `REVIVE_PUBLIC_BASE_URL`，上传和下载地址按它拼。

转写等异步任务由工作进程执行，和 API 一起跑（可以起多个）；它每 10 分钟顺带清理存储不可用时没删掉的音频和 7 天没传完的上传：

```bash
.venv/bin/python -m revive_api.worker
```

只想清理一次：`.venv/bin/python -m revive_api.maintenance`。

## 测试

测试连真实的 PostgreSQL，会清空它的 `public` schema，所以给一个专门的库：

```bash
TEST_DATABASE_URL=postgresql+psycopg://postgres@127.0.0.1:5432/revive_test .venv/bin/pytest
```

```bash
.venv/bin/ruff check . && .venv/bin/ruff format --check .
```

CI 是 `.github/workflows/backend-ci.yml`（Linux，PostgreSQL 16 服务容器）。

## 几条要知道的规则

- **时间**：路由和令牌校验都用注入的时钟（`runtime.Clock`），测试可以拨快；不要在业务代码里直接调 `datetime.now()`。
- **事务**：每个请求一个事务，路由返回后、响应发出前提交（`Depends(session, scope="function")`）。出错回滚；`AppError(keep_changes=True)` 例外（输错验证码也要记一次）。
- **刷新令牌**：每次刷新换新，旧的作废；作废的再出现就整条链吊销。App 刷新时要带 `Idempotency-Key`，网络断了重试才拿得回同一对令牌，而不是被当成盗用。
- **幂等**：按「令牌里的用户」区分调用方（access token 换新了也算同一个人），没登录时是匿名；第一次的响应加密保存 24 小时。
- **秘密不落明文**：密码 Argon2id；验证码、刷新令牌只存摘要；序列号只存「客户端 SHA-256 再做服务端 HMAC」，绑定码加密（理由见 ADR-012）。
- **上传音频**：App 先 `POST /v1/recordings` 拿每个分片的预签名地址，直接 PUT 到存储，再 `upload-complete`；断了就 `POST /recordings/{id}/upload` 看哪些分片已经在了。同一段音频（按 SHA-256）在一个账号里只存一份。每次开始上传都换一个新的对象键，所以排队待删的旧对象不会误删新传的音频。
- **删除存储里的东西**：不在请求里直接删，而是在同一事务里写一行 `object_deletions`，响应发出后再删（`maintenance.drain_deletions`）；存储挂了也不丢。COS 上另外要配生命周期规则，清掉 7 天以上未完成的分片上传（App 服务器建了上传、数据库却回滚时会留下）。
- **任务**：入口只有 `tasks.enqueue`（和业务数据同一个事务），执行只有工作进程。处理函数先在事务外调外部服务，再用 `tasks.finishing` 写结果：它在同一个事务里把任务标成成功，并且只在任务仍是这一次尝试时才写，租约过期被别人接手的那次结果会丢弃。可重试的错误抛 `TaskError(retryable=True)`。
- **纪要提示词只有一份**（ADR-009）：来源是 App 的 `Summarizer.swift`/`Scene.swift`，`revive_api/summaries.py` 逐行照它移植。改提示词时两边一起改，再跑 `.venv/bin/python scripts/make_prompt_fixtures.py` 更新 `app/ReviveKit/Tests/AssistantTests/Fixtures/prompts`；App 的 `PromptFixtureTests` 和这里的 `tests/test_summaries.py` 都拿自己的输出和这些文件逐字比对。
- **额度**：建任务的接口先 `usage.lock`（锁用户行，和注销的加锁顺序一致），再 `check_pending` 和对应的 `check_*`，再 `enqueue`；用量只在任务成功时由处理函数写入 `usage_records`。
- **迁移**：改模型后 `alembic revision --autogenerate`，审一遍再提交；`tests/test_migrations.py` 会检查模型和迁移一致。
