"""/v1/me: the signed-in account, changing the password, this month's usage, deleting the account (prd.md §7.2;
App Store review requires deletion inside the app, backend-design.md §4.7)."""

from datetime import datetime

from fastapi import APIRouter, BackgroundTasks, Response
from pydantic import BaseModel, Field
from sqlalchemy import delete, select

from .. import usage
from ..accounts import CurrentUser, TokenOut, UserOut, revoke_all, sign_in
from ..errors import AppError
from ..maintenance import drain_deletions, queue_deletion
from ..models import Recording, User
from ..runtime import DB, Run
from ..security import hash_password, verify_password

router = APIRouter(prefix="/me", tags=["me"])


class PasswordChangeIn(BaseModel):
    current_password: str = Field(min_length=1, max_length=128)
    new_password: str = Field(min_length=8, max_length=128)


class AllowanceOut(BaseModel):
    used: int
    # Transcription only: recordings waiting to be transcribed, counted against the month.
    reserved: int = 0
    # None: no limit.
    limit: int | None
    remaining: int | None


class UsageOut(BaseModel):
    period_start: datetime
    period_end: datetime
    asr_seconds: AllowanceOut
    llm_tokens: AllowanceOut


@router.get("")
async def me(user: CurrentUser) -> UserOut:
    return UserOut.of(user)


@router.post("/password")
async def change_password(body: PasswordChangeIn, user: CurrentUser, db: DB, run: Run) -> TokenOut:
    """Signs every other device out and returns fresh tokens for this one."""
    if user.password_hash is None:
        raise AppError(400, "password_not_set", "这个账号用手机号登录，没有设置密码")
    if not verify_password(user.password_hash, body.current_password):
        raise AppError(401, "invalid_credentials", "当前密码不对")
    user.password_hash = hash_password(body.new_password)
    await revoke_all(db, user.id, run.clock.now())
    return (await sign_in(db, run, user))[0]


@router.delete("", status_code=204)
async def delete_account(user: CurrentUser, db: DB, run: Run, background: BackgroundTasks) -> Response:
    """Deletes the account and, through ON DELETE CASCADE, every row it owns: tokens, devices,
    feedback, recordings. Stored audio is queued for removal in the same transaction and removed
    right after the response (later by `maintenance` if storage is down)."""
    now = run.clock.now()
    queued = [
        queue_deletion(db, r, now) for r in await db.scalars(select(Recording).where(Recording.user_id == user.id))
    ]
    await db.execute(delete(User).where(User.id == user.id))
    if any(queued):
        background.add_task(drain_deletions, run, 10_000)
    return Response(status_code=204)


@router.get("/usage")
async def my_usage(user: CurrentUser, db: DB, run: Run) -> UsageOut:
    """This month's use and allowances (features.md X2). Months start at midnight Beijing time."""
    period = usage.current_period(run.clock.now(), run.settings.usage_utc_offset_hours)
    asr_used = await usage.used(db, user.id, usage.ASR_SECONDS, period)
    asr_reserved = await usage.reserved_asr(db, user.id)
    llm_used = await usage.used(db, user.id, usage.LLM_TOKENS, period)
    asr_limit, llm_limit = run.settings.asr_monthly_seconds, run.settings.llm_monthly_tokens
    return UsageOut(
        period_start=period.start,
        period_end=period.end,
        asr_seconds=AllowanceOut(
            used=asr_used,
            reserved=asr_reserved,
            limit=asr_limit,
            remaining=None if asr_limit is None else max(0, asr_limit - asr_used - asr_reserved),
        ),
        llm_tokens=AllowanceOut(
            used=llm_used,
            limit=llm_limit,
            remaining=None if llm_limit is None else max(0, llm_limit - llm_used),
        ),
    )
