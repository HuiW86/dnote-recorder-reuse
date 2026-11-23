"""The task queue (ADR-013): one `tasks` table is both the queue and what GET /tasks/{id} reads.

    queued ──▶ running ──▶ succeeded
                  │
                  └──▶ failed   (retryable failures go back to queued, up to 4 attempts)

A worker claims a due task with SKIP LOCKED and takes a lease. If it dies, the lease runs out and
another worker claims the task again (a new attempt). Results are written only while the task is
still running *this* attempt, so a worker that lost its lease cannot write a second result."""

import logging
import uuid
from collections.abc import AsyncIterator, Awaitable, Callable, Mapping
from contextlib import asynccontextmanager
from dataclasses import dataclass
from datetime import timedelta

from sqlalchemy import and_, or_, select, update
from sqlalchemy.ext.asyncio import AsyncSession

from .models import Task
from .runtime import Runtime

log = logging.getLogger("revive_api")

LEASE = timedelta(minutes=15)
# One attempt plus three retries (prd.md §7.4), waiting this long before each retry.
MAX_ATTEMPTS = 4
BACKOFF_SECONDS = (30, 60, 120)
QUEUED, RUNNING, SUCCEEDED, FAILED = "queued", "running", "succeeded", "failed"


class TaskError(Exception):
    def __init__(self, code: str, message: str, retryable: bool = False):
        super().__init__(code)
        self.code = code
        self.message = message
        self.retryable = retryable


class LostLease(Exception):
    """The task is no longer running this attempt (lease expired and reclaimed, or cancelled)."""


@dataclass(frozen=True)
class Claimed:
    id: uuid.UUID
    user_id: uuid.UUID
    recording_id: uuid.UUID | None
    kind: str
    params: dict
    attempt: int


Handler = Callable[[Runtime, Claimed], Awaitable[None]]


async def enqueue(
    db: AsyncSession,
    run: Runtime,
    *,
    user_id: uuid.UUID,
    kind: str,
    recording_id: uuid.UUID | None = None,
    params: dict | None = None,
) -> Task:
    """Adds a task in the caller's transaction: it exists exactly when the caller's writes do."""
    now = run.clock.now()
    task = Task(
        id=uuid.uuid4(),
        user_id=user_id,
        recording_id=recording_id,
        kind=kind,
        params=params or {},
        status=QUEUED,
        attempts=0,
        max_attempts=MAX_ATTEMPTS,
        run_after=now,
        created_at=now,
        updated_at=now,
    )
    db.add(task)
    await db.flush()
    return task


async def cancel(db: AsyncSession, run: Runtime, recording_id: uuid.UUID, code: str, message: str) -> None:
    """Fails the recording's unfinished tasks in the caller's transaction. A running one finds out
    when it tries to write its result (LostLease) and its result is dropped."""
    now = run.clock.now()
    await db.execute(
        update(Task)
        .where(Task.recording_id == recording_id, Task.status.in_([QUEUED, RUNNING]))
        .values(
            status=FAILED,
            error_code=code,
            error_message=message,
            lease_until=None,
            finished_at=now,
            updated_at=now,
        )
    )


async def claim(run: Runtime) -> Claimed | None:
    """Takes the next due task, or one whose lease ran out, and starts an attempt."""
    while True:
        now = run.clock.now()
        async with run.sessions() as db, db.begin():
            task = await db.scalar(
                select(Task)
                .where(
                    or_(
                        and_(Task.status == QUEUED, Task.run_after <= now),
                        and_(Task.status == RUNNING, Task.lease_until < now),
                    )
                )
                .order_by(Task.run_after)
                .limit(1)
                .with_for_update(skip_locked=True)
            )
            if task is None:
                return None
            if task.attempts >= task.max_attempts:
                # Its last attempt's worker vanished: no attempts left.
                _finish_failed(task, now, "worker_lost", "处理中断了，请重试")
                continue
            task.status = RUNNING
            task.attempts += 1
            task.lease_until = now + LEASE
            task.started_at = task.started_at or now
            task.updated_at = now
            return Claimed(task.id, task.user_id, task.recording_id, task.kind, dict(task.params), task.attempts)


@dataclass
class Finishing:
    db: AsyncSession
    # Set to keep a small answer on the task (Task.result).
    result: dict | None = None


@asynccontextmanager
async def finishing(run: Runtime, claimed: Claimed) -> AsyncIterator[Finishing]:
    """A transaction for the task's results that also marks it succeeded. Raises LostLease, writing
    nothing, when the task is no longer running this attempt."""
    async with run.sessions() as db, db.begin():
        task = await _this_attempt(db, claimed)
        if task is None:
            raise LostLease(str(claimed.id))
        done = Finishing(db)
        yield done
        now = run.clock.now()
        task.result = done.result
        task.status = SUCCEEDED
        task.lease_until = None
        task.error_code = task.error_message = None
        task.finished_at = now
        task.updated_at = now


async def run_one(run: Runtime, handlers: Mapping[str, Handler]) -> bool:
    """Claims and runs one task. False when nothing was due."""
    claimed = await claim(run)
    if claimed is None:
        return False
    try:
        handler = handlers.get(claimed.kind)
        if handler is None:
            raise TaskError("unknown_kind", "服务端不认识这种任务")
        await handler(run, claimed)
    except LostLease:
        log.warning("task %s attempt %d lost its lease; result dropped", claimed.id, claimed.attempt)
    except TaskError as error:
        await _failed(run, claimed, error)
    except Exception:
        log.exception("task %s (%s) failed", claimed.id, claimed.kind)
        await _failed(run, claimed, TaskError("internal", "服务暂时出错，稍后会自动重试", retryable=True))
    return True


async def _failed(run: Runtime, claimed: Claimed, error: TaskError) -> None:
    async with run.sessions() as db, db.begin():
        task = await _this_attempt(db, claimed)
        if task is None:
            return
        now = run.clock.now()
        task.error_code, task.error_message = error.code, error.message
        if error.retryable and task.attempts < task.max_attempts:
            task.status = QUEUED
            task.lease_until = None
            task.run_after = now + timedelta(seconds=BACKOFF_SECONDS[min(task.attempts, len(BACKOFF_SECONDS)) - 1])
            task.updated_at = now
        else:
            _finish_failed(task, now, error.code, error.message)


def _finish_failed(task: Task, now, code: str, message: str) -> None:
    task.status = FAILED
    task.error_code, task.error_message = code, message
    task.lease_until = None
    task.finished_at = now
    task.updated_at = now


async def _this_attempt(db: AsyncSession, claimed: Claimed) -> Task | None:
    return await db.scalar(
        select(Task)
        .where(Task.id == claimed.id, Task.status == RUNNING, Task.attempts == claimed.attempt)
        .with_for_update()
    )
