"""Usage and monthly allowances (features.md X2; prd.md §7.2 用量).

Usage is recorded when a task succeeds (`usage_records`: ASR seconds, model tokens). Allowances
are checked when a task is asked for, so a request over the limit is refused right away with
`quota_exceeded` instead of failing later:

- Transcription: the seconds used this month, plus the recordings already waiting to be
  transcribed, plus this one, must fit. Waiting work counts so that queueing many recordings at
  once cannot overshoot.
- Summaries: tokens are not known in advance, so a summary is refused only once the month's
  tokens are used up; the last one may go over a little.

Model tokens an attempt spent without producing a result (an unreadable reply that is retried, a
recording deleted meanwhile) are recorded as `llm_unbilled`: they are what running the service
cost, but the user got nothing for them, so they never count against the allowance.

Every account may also have only `max_pending_tasks` tasks queued or running at a time.
Checks and the enqueue that follows run under a lock on the user's row, so two requests at once
cannot both slip under the limit."""

import logging
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta, timezone

from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from .errors import AppError
from .models import Recording, Task, UsageRecord, User
from .runtime import Runtime
from .tasks import QUEUED, RUNNING

ASR_SECONDS, LLM_TOKENS, LLM_UNBILLED = "asr_seconds", "llm_tokens", "llm_unbilled"

log = logging.getLogger("revive_api")


@dataclass(frozen=True)
class Period:
    start: datetime
    end: datetime


def current_period(now: datetime, offset_hours: int) -> Period:
    """The calendar month containing `now`, in local time at `offset_hours` from UTC."""
    zone = timezone(timedelta(hours=offset_hours))
    local = now.astimezone(zone)
    start = local.replace(day=1, hour=0, minute=0, second=0, microsecond=0)
    end = start.replace(year=start.year + 1, month=1) if start.month == 12 else start.replace(month=start.month + 1)
    return Period(start.astimezone(UTC), end.astimezone(UTC))


def seconds_of(duration_ms: int) -> int:
    """ASR seconds for a recording: started seconds count, as in transcription.py."""
    return -(-max(0, duration_ms) // 1000)


async def used(db: AsyncSession, user_id, kind: str, period: Period) -> int:
    total = await db.scalar(
        select(func.coalesce(func.sum(UsageRecord.amount), 0)).where(
            UsageRecord.user_id == user_id,
            UsageRecord.kind == kind,
            UsageRecord.occurred_at >= period.start,
            UsageRecord.occurred_at < period.end,
        )
    )
    return int(total or 0)


async def reserved_asr(db: AsyncSession, user_id) -> int:
    """Seconds of the recordings waiting to be transcribed (queued, retrying or running)."""
    total = await db.scalar(
        select(func.coalesce(func.sum((Recording.duration_ms + 999) / 1000), 0))
        .select_from(Task)
        .join(Recording, Recording.id == Task.recording_id)
        .where(Task.user_id == user_id, Task.kind == "transcribe", Task.status.in_([QUEUED, RUNNING]))
    )
    return int(total or 0)


async def lock(db: AsyncSession, user: User) -> None:
    """Serialises this user's checks and enqueues until the request's transaction ends."""
    await db.execute(select(User.id).where(User.id == user.id).with_for_update())


async def check_pending(db: AsyncSession, run: Runtime, user: User) -> None:
    pending = await db.scalar(
        select(func.count()).select_from(Task).where(Task.user_id == user.id, Task.status.in_([QUEUED, RUNNING]))
    )
    if (pending or 0) >= run.settings.max_pending_tasks:
        raise AppError(429, "too_many_tasks", "正在处理的任务太多，请等前面的完成后再试", retryable=True)


async def check_transcribe(db: AsyncSession, run: Runtime, user: User, duration_ms: int) -> None:
    limit = run.settings.asr_monthly_seconds
    if limit is None:
        return
    period = current_period(run.clock.now(), run.settings.usage_utc_offset_hours)
    need = await used(db, user.id, ASR_SECONDS, period) + await reserved_asr(db, user.id) + seconds_of(duration_ms)
    if need > limit:
        raise AppError(429, "quota_exceeded", f"本月转写时长不够了（每月 {limit // 60} 分钟），下个月 1 日恢复")


async def check_summarize(db: AsyncSession, run: Runtime, user: User) -> None:
    limit = run.settings.llm_monthly_tokens
    if limit is None:
        return
    period = current_period(run.clock.now(), run.settings.usage_utc_offset_hours)
    if await used(db, user.id, LLM_TOKENS, period) >= limit:
        raise AppError(429, "quota_exceeded", "本月 AI 整理的额度用完了，下个月 1 日恢复")


async def record_unbilled(run: Runtime, user_id, tokens: int) -> None:
    """Keeps the tokens of an attempt that produced nothing, outside the failed attempt's own
    transaction. Never raises: losing this record must not hide why the attempt failed."""
    if tokens <= 0:
        return
    try:
        async with run.sessions() as db, db.begin():
            db.add(UsageRecord(user_id=user_id, kind=LLM_UNBILLED, amount=tokens, occurred_at=run.clock.now()))
    except Exception:
        log.exception("could not record %d unbilled tokens", tokens)
