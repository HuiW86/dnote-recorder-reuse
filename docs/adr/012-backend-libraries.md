# ADR-012：后端用的库与版本

**日期**　2026-11-22
**状态**　Accepted（2026-11-25：用户把决定交给开发会话；按本文实现的 M2 后端已随 PR #134 合并到 main。表中「任务队列」一行由 ADR-013 决定）
**来源**　#12（M2）；`prd.md` §7 写明「具体库和版本在 M2 工程初始化时用 ADR 确认」

## 背景

- ADR-002 定了 Python + FastAPI + PostgreSQL、任务队列放在 PostgreSQL 里；ADR-003 定了腾讯云。
- `prd.md` §7 给了候选：SQLAlchemy 2 + Alembic、Pydantic v2、procrastinate。
- 要求：access token 15 分钟、refresh token 30 天且每次刷新换新（§7.1）；验证码、密码、绑定码不能明文存（§8）；注销删除全部数据。
- 规模：TestFlight 阶段千级用户（ADR-004）。
- 云厂商账号还没有：短信、邮件、COS、KMS 都要先能用替身跑通，等账号到位再接真实服务。

## 候选方案

| 项 | 选 | 另一个候选 | 理由 |
|---|---|---|---|
| 数据库访问 | SQLAlchemy 2（异步）+ psycopg 3 | asyncpg | psycopg 一个驱动同时给应用（异步）和 Alembic（同步）用；性能差别在这个规模可以忽略 |
| 迁移 | Alembic，手写或自动生成后人工审 | SQLAlchemy `create_all` | 迁移要能审、能回退，和 App 端「迁移只增不改」的做法一致 |
| 校验与配置 | Pydantic v2、pydantic-settings | — | FastAPI 自带；配置从环境变量读 |
| 密码哈希 | argon2-cffi（Argon2id） | bcrypt | OWASP 首选；没有 bcrypt 的 72 字节截断 |
| access token | PyJWT，HS256，15 分钟 | 不透明 token 查库 | 每个请求不用查库；有效期短，不需要吊销列表 |
| refresh token | 不透明随机串，只存 SHA-256；轮换时记 `replaced_by`，已作废的再出现就整条链吊销 | JWT | 能吊销、能发现被盗用 |
| 验证码 | 6 位数字，只存 HMAC；10 分钟有效，最多试 5 次，同一目标 60 秒内不重发、每天最多 10 次 | — | 防暴力尝试和短信轰炸 |
| 绑定码、序列号 | 绑定码用 AES-GCM（`cryptography`）加密，密钥来自环境变量，以后换成腾讯云 KMS 的信封加密；序列号只存「客户端给的 SHA-256 再做一次服务端 HMAC」 | 只存 SHA-256(sn) | 序列号可以被枚举：只存 SHA-256 的话，数据库泄露后能反推出 sn，加上仓库里公开的 `DEVICE_KEY_SECRET` 就能算出这张卡的音频密钥（ADR-006） |
| 幂等 | 自己写一个中间件，按「鉴权身份 + Idempotency-Key」存第一次的响应 24 小时 | 第三方库 | 逻辑很少；第三方库多数要 Redis |
| 任务队列 | 等转写那一片再定（候选 procrastinate） | — | 这一片没有异步任务 |
| 测试 | pytest + pytest-asyncio + httpx，连真实 PostgreSQL（CI 用服务容器） | SQLite | 要测的正是 PostgreSQL 的约束和级联删除 |
| 代码检查 | ruff | — | |

版本在 `backend/pyproject.toml` 里精确锁定（`==`），升级走单独的 PR。

## 决定

按上表：FastAPI + Pydantic v2 + SQLAlchemy 2（异步，psycopg 3）+ Alembic + argon2-cffi + PyJWT + cryptography；短信、邮件、KMS 先用接口加替身，真实服务等账号到位后接。

## 后果

- 正面：一个驱动、一种迁移方式；没有 Redis；所有秘密都不明文落库；不用云账号就能开发和测试。
- 负面：幂等中间件要自己维护；HS256 的密钥要和应用一起保管好（泄露就能伪造 15 分钟的 access token）。
- 反悔成本：换驱动、换 JWT 库都是局部改动；换 ORM 要重写数据访问层，但这一片只有几张表。
