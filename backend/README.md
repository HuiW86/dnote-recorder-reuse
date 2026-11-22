# 后端（M2）

闻笺的后端：账号、设备登记、意见反馈，之后是录音上传、转写、AI 整理（`docs/prd.md` §7、§8）。选型见 ADR-002、ADR-003，库与版本见 ADR-012。

App 没登录时不调用这里的任何接口；设备功能（配对、录音、同步、播放、导出）完全不依赖后端（`CLAUDE.md` 硬规则 3）。

## 现在有什么（第一片）

| 模块 | 接口 | 对应 |
|---|---|---|
| 账号 | `POST /v1/auth/sms/send`、`/sms/login`、`/email/register`、`/email/verify`、`/password/login`、`/password/reset/send`、`/password/reset`、`/refresh`、`/logout` | K1 |
| 当前账号 | `GET /v1/me`、`POST /v1/me/password`、`DELETE /v1/me`（注销，删除全部数据） | K1 |
| 设备登记 | `GET /v1/devices`、`PUT /v1/devices/{sn_hash}`、`DELETE /v1/devices/{sn_hash}` | A4b |
| 意见反馈 | `POST /v1/feedback` | O1b |
| 通用 | 统一错误结构、写操作的 `Idempotency-Key`、`GET /healthz` | §7.1、§7.3 |

还没有：录音上传（COS）、转写、AI 生成、任务、用量（M2 后面几片）。

**替身**：短信、邮件、KMS 要腾讯云账号。现在验证码由 `LoggingSender` 打到日志里（生产环境会拒绝启动），绑定码用环境变量里的密钥加密。账号到位后各自换成真实实现（`revive_api/runtime.py` 的 `CodeSender`，`security.py` 的 `Box`）。

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

接口文档在 `http://127.0.0.1:8000/docs`。

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
- **迁移**：改模型后 `alembic revision --autogenerate`，审一遍再提交；`tests/test_migrations.py` 会检查模型和迁移一致。
