"""/v1/auth: SMS login, email registration and verification, password login and reset, refresh,
logout (prd.md §7.2 账号)."""

from fastapi import APIRouter, Response
from pydantic import BaseModel, EmailStr, Field
from sqlalchemy import select

from ..accounts import (
    EMAIL_VERIFY,
    PASSWORD_RESET,
    SMS_LOGIN,
    CodeSent,
    TokenOut,
    consume_code,
    issue_code,
    new_user,
    normalize_email,
    normalize_phone,
    revoke_all,
    rotate,
    sign_in,
)
from ..errors import AppError
from ..models import RefreshToken, User
from ..runtime import DB, Run
from ..security import hash_password, sha256_hex, verify_password

router = APIRouter(prefix="/auth", tags=["auth"])

Password = Field(min_length=8, max_length=128)
Code = Field(min_length=4, max_length=8)


class PhoneIn(BaseModel):
    phone: str = Field(max_length=32)


class SmsLoginIn(PhoneIn):
    code: str = Code


class EmailIn(BaseModel):
    email: EmailStr


class RegisterIn(EmailIn):
    password: str = Password


class VerifyIn(EmailIn):
    code: str = Code


class LoginIn(EmailIn):
    password: str = Field(min_length=1, max_length=128)


class ResetIn(EmailIn):
    code: str = Code
    new_password: str = Password


class RefreshIn(BaseModel):
    refresh_token: str = Field(min_length=1, max_length=200)


@router.post("/sms/send", status_code=202)
async def sms_send(body: PhoneIn, db: DB, run: Run) -> CodeSent:
    return await issue_code(db, run, normalize_phone(body.phone), SMS_LOGIN, deliver=True)


@router.post("/sms/login")
async def sms_login(body: SmsLoginIn, db: DB, run: Run) -> TokenOut:
    """Signs in, creating the account on first use: a phone number needs no separate sign-up."""
    phone = normalize_phone(body.phone)
    await consume_code(db, run, phone, SMS_LOGIN, body.code)
    user = await db.scalar(select(User).where(User.phone == phone))
    if user is None:
        user = new_user(run, phone=phone)
        db.add(user)
        await db.flush()
    return (await sign_in(db, run, user))[0]


@router.post("/email/register", status_code=202)
async def email_register(body: RegisterIn, db: DB, run: Run) -> CodeSent:
    """Creates an unverified account (or updates the password of one never verified) and emails a
    code. A verified address is taken."""
    email = normalize_email(body.email)
    user = await db.scalar(select(User).where(User.email == email))
    if user is not None and user.email_verified_at is not None:
        raise AppError(409, "email_taken", "这个邮箱已经注册过了，请直接登录")
    if user is None:
        db.add(new_user(run, email=email, password_hash=hash_password(body.password)))
    else:
        user.password_hash = hash_password(body.password)
    await db.flush()
    return await issue_code(db, run, email, EMAIL_VERIFY, deliver=True)


@router.post("/email/verify")
async def email_verify(body: VerifyIn, db: DB, run: Run) -> TokenOut:
    email = normalize_email(body.email)
    await consume_code(db, run, email, EMAIL_VERIFY, body.code)
    user = await db.scalar(select(User).where(User.email == email))
    if user is None:
        raise AppError(400, "code_invalid", "验证码不对或已失效，请重新获取")
    user.email_verified_at = user.email_verified_at or run.clock.now()
    return (await sign_in(db, run, user))[0]


@router.post("/password/login")
async def password_login(body: LoginIn, db: DB, run: Run) -> TokenOut:
    """Unknown email and wrong password get the same answer, after the same amount of hashing."""
    user = await db.scalar(select(User).where(User.email == normalize_email(body.email)))
    if not verify_password(user.password_hash if user else None, body.password):
        raise AppError(401, "invalid_credentials", "邮箱或密码不对")
    assert user is not None
    if user.email_verified_at is None:
        raise AppError(403, "email_not_verified", "邮箱还没有验证，请先完成验证")
    return (await sign_in(db, run, user))[0]


@router.post("/password/reset/send", status_code=202)
async def password_reset_send(body: EmailIn, db: DB, run: Run) -> CodeSent:
    """Same reply whether or not the address has an account; a code is only sent if it has."""
    email = normalize_email(body.email)
    user = await db.scalar(select(User).where(User.email == email, User.email_verified_at.is_not(None)))
    return await issue_code(db, run, email, PASSWORD_RESET, deliver=user is not None)


@router.post("/password/reset", status_code=204)
async def password_reset(body: ResetIn, db: DB, run: Run) -> Response:
    """Sets a new password and signs every device out."""
    email = normalize_email(body.email)
    await consume_code(db, run, email, PASSWORD_RESET, body.code)
    user = await db.scalar(select(User).where(User.email == email))
    if user is None:
        raise AppError(400, "code_invalid", "验证码不对或已失效，请重新获取")
    user.password_hash = hash_password(body.new_password)
    await revoke_all(db, user.id, run.clock.now())
    return Response(status_code=204)


@router.post("/refresh")
async def refresh(body: RefreshIn, db: DB, run: Run) -> TokenOut:
    """Send an Idempotency-Key: a retried refresh then gets the same tokens back instead of
    presenting the spent token again, which would sign the user out everywhere."""
    return await rotate(db, run, body.refresh_token)


@router.post("/logout", status_code=204)
async def logout(body: RefreshIn, db: DB, run: Run) -> Response:
    token = await db.scalar(select(RefreshToken).where(RefreshToken.token_hash == sha256_hex(body.refresh_token)))
    if token is not None and token.revoked_at is None:
        token.revoked_at = run.clock.now()
    return Response(status_code=204)
