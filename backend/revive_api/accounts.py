"""Verification codes, sign-in and refresh-token rotation (prd.md §7.1, features.md K1)."""

import re
import uuid
from datetime import timedelta
from typing import Annotated

from fastapi import Depends, Header
from pydantic import BaseModel
from sqlalchemy import func, select, update
from sqlalchemy.ext.asyncio import AsyncSession

from .errors import AppError
from .models import RefreshToken, User, VerificationCode
from .runtime import DB, Run, Runtime
from .security import ExpiredToken, InvalidToken, Tokens, sha256_hex

SMS_LOGIN = "sms_login"
EMAIL_VERIFY = "email_verify"
PASSWORD_RESET = "password_reset"  # noqa: S105 - a code purpose, not a password


class UserOut(BaseModel):
    id: uuid.UUID
    phone: str | None
    email: str | None
    email_verified: bool
    has_password: bool

    @classmethod
    def of(cls, user: User) -> "UserOut":
        return cls(
            id=user.id,
            phone=user.phone,
            email=user.email,
            email_verified=user.email_verified_at is not None,
            has_password=user.password_hash is not None,
        )


class TokenOut(BaseModel):
    access_token: str
    refresh_token: str
    token_type: str = "bearer"  # noqa: S105 - the OAuth token type
    expires_in: int
    user: UserOut


class CodeSent(BaseModel):
    resend_after_seconds: int


def normalize_phone(raw: str) -> str:
    """Mainland China mobile numbers only for now (Tencent SMS, ADR-003), as +86XXXXXXXXXXX."""
    digits = re.sub(r"[\s\-()]", "", raw)
    if digits.startswith("+86"):
        digits = digits[3:]
    elif digits.startswith("0086"):
        digits = digits[4:]
    if not re.fullmatch(r"1[3-9]\d{9}", digits):
        raise AppError(422, "invalid_phone", "手机号不对；目前只支持中国大陆手机号")
    return "+86" + digits


def normalize_email(raw: str) -> str:
    return raw.strip().lower()


# MARK: Codes


async def issue_code(db: AsyncSession, run: Runtime, target: str, purpose: str, deliver: bool) -> CodeSent:
    """A new code for `target`, replacing any unused one. Throttled per target: one per
    `code_resend_seconds`, at most `code_daily_limit` a day across purposes. With `deliver` false
    (password reset for an unknown email) the code is recorded but sent nowhere, so the reply and
    the throttle look the same whether or not the account exists."""
    s = run.settings
    now = run.clock.now()
    last = await db.scalar(
        select(VerificationCode.created_at)
        .where(VerificationCode.target == target, VerificationCode.purpose == purpose)
        .order_by(VerificationCode.created_at.desc())
        .limit(1)
    )
    if last is not None and now - last < timedelta(seconds=s.code_resend_seconds):
        wait = s.code_resend_seconds - int((now - last).total_seconds())
        raise AppError(429, "code_too_frequent", f"验证码发得太频繁，请 {wait} 秒后再试", retryable=True)
    today = await db.scalar(
        select(func.count())
        .select_from(VerificationCode)
        .where(VerificationCode.target == target, VerificationCode.created_at > now - timedelta(days=1))
    )
    if (today or 0) >= s.code_daily_limit:
        raise AppError(429, "code_daily_limit", "今天获取验证码的次数用完了，请明天再试")
    await db.execute(
        update(VerificationCode)
        .where(
            VerificationCode.target == target,
            VerificationCode.purpose == purpose,
            VerificationCode.consumed_at.is_(None),
        )
        .values(consumed_at=now)
    )
    code = run.codes.new()
    db.add(
        VerificationCode(
            target=target,
            purpose=purpose,
            code_hash=run.codes.digest(purpose, target, code),
            expires_at=now + timedelta(seconds=s.code_ttl_seconds),
            attempts=0,
            created_at=now,
        )
    )
    await db.flush()
    if deliver:
        sender = run.sms if purpose == SMS_LOGIN else run.email
        try:
            await sender.send(target, purpose, code)
        except Exception as error:
            raise AppError(502, "code_send_failed", "验证码发送失败，请稍后再试", retryable=True) from error
    return CodeSent(resend_after_seconds=s.code_resend_seconds)


async def consume_code(db: AsyncSession, run: Runtime, target: str, purpose: str, code: str) -> None:
    """Accepts the latest unused code once. A wrong code counts as an attempt even though the
    request fails; after `code_max_attempts` the code is dead and a new one is needed."""
    now = run.clock.now()
    record = await db.scalar(
        select(VerificationCode)
        .where(
            VerificationCode.target == target,
            VerificationCode.purpose == purpose,
            VerificationCode.consumed_at.is_(None),
        )
        .order_by(VerificationCode.created_at.desc())
        .limit(1)
        .with_for_update()
    )
    if record is None:
        raise AppError(400, "code_invalid", "验证码不对或已失效，请重新获取")
    if record.expires_at <= now:
        raise AppError(400, "code_expired", "验证码已过期，请重新获取")
    if record.attempts >= run.settings.code_max_attempts:
        raise AppError(429, "code_attempts_exceeded", "验证码试错次数太多，请重新获取")
    if not run.codes.matches(record.code_hash, purpose, target, code.strip()):
        record.attempts += 1
        raise AppError(400, "code_invalid", "验证码不对或已失效，请重新获取", keep_changes=True)
    record.consumed_at = now


# MARK: Tokens


async def sign_in(
    db: AsyncSession, run: Runtime, user: User, family: uuid.UUID | None = None
) -> tuple[TokenOut, uuid.UUID]:
    now = run.clock.now()
    raw, digest = Tokens.new_refresh()
    token = RefreshToken(
        id=uuid.uuid4(),
        user_id=user.id,
        token_hash=digest,
        family_id=family or uuid.uuid4(),
        expires_at=now + run.tokens.refresh_ttl,
        created_at=now,
    )
    db.add(token)
    await db.flush()
    out = TokenOut(
        access_token=run.tokens.access(user.id, now),
        refresh_token=raw,
        expires_in=int(run.tokens.access_ttl.total_seconds()),
        user=UserOut.of(user),
    )
    return out, token.id


async def rotate(db: AsyncSession, run: Runtime, raw: str) -> TokenOut:
    """Refresh: the old token is spent and a new one replaces it. A spent token presented again
    means two parties hold it (stolen, or a client that retried without an Idempotency-Key):
    the whole family is revoked and both must sign in again."""
    now = run.clock.now()
    token = await db.scalar(select(RefreshToken).where(RefreshToken.token_hash == sha256_hex(raw)).with_for_update())
    if token is None or token.expires_at <= now:
        raise AppError(401, "refresh_invalid", "登录已失效，请重新登录")
    if token.revoked_at is not None:
        if token.replaced_by is not None:
            await revoke_family(db, token.family_id, now)
            raise AppError(401, "refresh_reused", "登录已失效，请重新登录", keep_changes=True)
        raise AppError(401, "refresh_invalid", "登录已失效，请重新登录")
    user = await db.get(User, token.user_id)
    if user is None:
        raise AppError(401, "refresh_invalid", "登录已失效，请重新登录")
    out, new_id = await sign_in(db, run, user, family=token.family_id)
    token.revoked_at = now
    token.replaced_by = new_id
    return out


async def revoke_family(db: AsyncSession, family: uuid.UUID, now) -> None:
    await db.execute(
        update(RefreshToken)
        .where(RefreshToken.family_id == family, RefreshToken.revoked_at.is_(None))
        .values(revoked_at=now)
    )


async def revoke_all(db: AsyncSession, user_id: uuid.UUID, now) -> None:
    await db.execute(
        update(RefreshToken)
        .where(RefreshToken.user_id == user_id, RefreshToken.revoked_at.is_(None))
        .values(revoked_at=now)
    )


# MARK: The signed-in user


async def current_user(db: DB, run: Run, authorization: Annotated[str | None, Header()] = None) -> User:
    if not authorization or not authorization.lower().startswith("bearer "):
        raise AppError(401, "unauthorized", "请先登录")
    try:
        user_id = run.tokens.read_access(authorization[7:].strip(), run.clock.now())
    except ExpiredToken as error:
        raise AppError(401, "token_expired", "登录已过期", retryable=True) from error
    except InvalidToken as error:
        raise AppError(401, "invalid_token", "登录信息无效，请重新登录") from error
    user = await db.get(User, user_id)
    if user is None:
        raise AppError(401, "invalid_token", "登录信息无效，请重新登录")
    return user


CurrentUser = Annotated[User, Depends(current_user)]


def new_user(run: Runtime, **fields) -> User:
    return User(id=uuid.uuid4(), created_at=run.clock.now(), **fields)
