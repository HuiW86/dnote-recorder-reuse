# ADR-013：任务队列自己写，一张 `tasks` 表，不用 procrastinate

**日期**　2026-11-22
**状态**　Proposed
**来源**　#12（M2）；ADR-012「任务队列：等转写那一片再定（候选 procrastinate）」

## 背景

- ADR-002 定了任务队列放在 PostgreSQL 里，用 `SELECT … FOR UPDATE SKIP LOCKED`；ADR-012 把具体用哪个库留到转写这一片。
- `prd.md` §7.4：任务状态 `queued → running → succeeded / failed`，可重试的失败服务端自动重试，最多 3 次；App 轮询 `GET /tasks/{id}`。
- `prd.md` §8：`tasks`「由任务队列库管理；业务侧另记 kind、recording_id、user_id、status、error_code」。也就是说，用了库也还要一张业务表。
- 规模：TestFlight 阶段千级用户（ADR-004）；任务只有转写和 AI 生成两类，每条录音几次。
- 注销账号要删掉这个用户的全部数据，任务也在内。

## 候选方案

| 方案 | 优点 | 缺点 |
|---|---|---|
| **A. 自己写**：一张 `tasks` 表同时是队列和业务状态；取任务用 `FOR UPDATE SKIP LOCKED`，取到后写租约（`lease_until`），工作进程挂了租约过期就能被别人接手 | 状态只有一份，`GET /tasks/{id}` 直接读它；任务和录音、转写结果在同一个事务里提交；表在 Alembic 迁移里，随用户 `ON DELETE CASCADE`；代码约 200 行，全部有测试 | 重试、租约、退避要自己写和维护；没有现成的管理界面、定时任务 |
| B. procrastinate | 现成的重试、定时任务、`LISTEN/NOTIFY` 唤醒、命令行管理 | 它有自己的表和迁移，要和 Alembic 并存；状态在它的表里，业务表还得另记一份并保持一致；注销时要另外清它的表；又多一个要锁版本、跟升级的依赖 |
| C. Celery / RQ + Redis | 生态最大 | ADR-002 已经排除：多一个 Redis，任务和数据库状态要另外保证一致 |

## 决定

采用 **A**。规则：

- 一次执行算一次尝试；可重试的失败在 4 次尝试内（第一次加 3 次重试）退避后重排（30 秒、60 秒、120 秒），否则 `failed`。
- 租约 15 分钟；工作进程完成时按「状态还是 `running`、尝试次数没变」有条件地写结果，租约过期被别人接手的那次结果丢弃，不会写两份。
- 工作进程 `python -m revive_api.worker`：取任务、执行，空闲时每秒查一次；顺带每 10 分钟跑一次 `maintenance`（删除待删的音频、作废 7 天没传完的上传），之前写的 cron 用不着了。

## 后果

- 正面：任务状态只有一份；不多一个依赖和一套迁移；注销时随用户一起删。
- 负面：重试和租约的边界情况要靠自己的测试守住；没有 `LISTEN/NOTIFY`，任务最多晚 1 秒开始（轮询）；要看队列只能查表。
- 反悔成本：低。任务的入口只有 `tasks.enqueue`，执行只有 `worker`；换成 procrastinate 时把这两处换掉，`tasks` 表退回成业务表即可。

---

规则：已接受的 ADR 不改原文；改主意时新开一份，把旧的状态改为 `Superseded by ADR-NNN`。
