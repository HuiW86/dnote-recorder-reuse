# ADR-002：后端用 Python + FastAPI + PostgreSQL，任务队列放在 PostgreSQL 里

**日期**　2026-11-06
**状态**　Accepted
**来源**　#26（父 issue #10）

## 背景

- 后端要做：REST 接口、异步转写与 AI 生成任务、AI 对话的 SSE 流式返回、实时转写的 WebSocket、对象存储直传签名（`backend-design.md` §4.4、§4.6）。
- 主要外部依赖是国内云厂商的 ASR 和大模型 SDK，ASR 要能替换（§4.5）。
- 用户对后端语言没有偏好；团队现有代码里，协议客户端 `client/` 是 Python。
- 规模：TestFlight 阶段用户量在千级以内（ADR-004），不需要为高并发选型。

## 候选方案

| 方案 | 优点 | 缺点 |
|---|---|---|
| **Python + FastAPI** | 国内 ASR、大模型 SDK 对 Python 支持最好；FastAPI 原生支持异步、SSE、WebSocket；可直接复用 `client/` 的协议和解密代码做服务端校验 | 单进程 CPU 性能一般（本项目主要是 I/O，影响小） |
| Go | 性能好，单个二进制，部署简单 | AI SDK 支持弱，部分要自己封装 HTTP 调用 |
| Node.js / TypeScript | SSE、WebSocket 生态成熟 | AI SDK 支持中等；和现有代码没有共享 |

任务队列：

| 方案 | 优点 | 缺点 |
|---|---|---|
| **放在 PostgreSQL 里**（基于 `SELECT … FOR UPDATE SKIP LOCKED` 的队列） | 少一个 Redis；任务和业务数据在同一事务里提交，不会出现「记录写了、任务没发」 | 吞吐低于专用消息队列（当前规模足够） |
| Celery / RQ + Redis | 成熟、生态大 | 多维护一个 Redis；任务与数据库状态要另外保证一致 |

## 决定

后端用 Python + FastAPI，数据库用 PostgreSQL；异步任务队列也放在 PostgreSQL 里，不引入 Redis。具体库和版本在 `prd.md`（#27）中定。

## 后果

- 正面：AI 侧集成最快；部署只有「应用 + 数据库 + 对象存储」三件。
- 负面：任务量到万级每分钟时要换专用队列。
- 反悔成本：队列只通过一个内部接口调用，改用 Redis 方案只需替换这一层；换语言等于重写后端。
