"""Tables of slice 1 (prd.md §8). Every user-owned row cascades on delete, so DELETE /me removes
the account and everything in it in one statement."""

import uuid
from datetime import datetime

from sqlalchemy import (
    CheckConstraint,
    DateTime,
    ForeignKey,
    Index,
    Integer,
    LargeBinary,
    String,
    Text,
    UniqueConstraint,
)
from sqlalchemy.dialects.postgresql import UUID
from sqlalchemy.orm import DeclarativeBase, Mapped, mapped_column


class Base(DeclarativeBase):
    pass


def _id() -> Mapped[uuid.UUID]:
    return mapped_column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)


def _time(nullable: bool = False) -> Mapped[datetime]:
    return mapped_column(DateTime(timezone=True), nullable=nullable)


def _owner() -> Mapped[uuid.UUID]:
    return mapped_column(UUID(as_uuid=True), ForeignKey("users.id", ondelete="CASCADE"), nullable=False, index=True)


class User(Base):
    __tablename__ = "users"
    __table_args__ = (CheckConstraint("phone IS NOT NULL OR email IS NOT NULL", name="users_phone_or_email"),)
    id: Mapped[uuid.UUID] = _id()
    # +86 numbers in E.164; lowercased email. Either may be missing, not both.
    phone: Mapped[str | None] = mapped_column(String(20), unique=True)
    email: Mapped[str | None] = mapped_column(String(254), unique=True)
    email_verified_at: Mapped[datetime | None] = _time(nullable=True)
    password_hash: Mapped[str | None] = mapped_column(String(255))
    created_at: Mapped[datetime] = _time()


class RefreshToken(Base):
    __tablename__ = "refresh_tokens"
    id: Mapped[uuid.UUID] = _id()
    user_id: Mapped[uuid.UUID] = _owner()
    token_hash: Mapped[str] = mapped_column(String(64), unique=True, nullable=False)
    # Every token from one sign-in shares a family; reusing a replaced token revokes the family.
    family_id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), nullable=False, index=True)
    expires_at: Mapped[datetime] = _time()
    revoked_at: Mapped[datetime | None] = _time(nullable=True)
    replaced_by: Mapped[uuid.UUID | None] = mapped_column(UUID(as_uuid=True))
    created_at: Mapped[datetime] = _time()


class VerificationCode(Base):
    __tablename__ = "verification_codes"
    __table_args__ = (Index("verification_codes_target", "target", "purpose", "created_at"),)
    id: Mapped[uuid.UUID] = _id()
    target: Mapped[str] = mapped_column(String(254), nullable=False)
    # sms_login, email_verify, password_reset
    purpose: Mapped[str] = mapped_column(String(32), nullable=False)
    code_hash: Mapped[str] = mapped_column(String(64), nullable=False)
    expires_at: Mapped[datetime] = _time()
    attempts: Mapped[int] = mapped_column(Integer, nullable=False, default=0)
    consumed_at: Mapped[datetime | None] = _time(nullable=True)
    created_at: Mapped[datetime] = _time()


class Device(Base):
    __tablename__ = "devices"
    __table_args__ = (UniqueConstraint("user_id", "sn_key", name="devices_user_sn"),)
    id: Mapped[uuid.UUID] = _id()
    user_id: Mapped[uuid.UUID] = _owner()
    # HMAC(sn_pepper, client SHA-256(sn)): for lookups only.
    sn_key: Mapped[str] = mapped_column(String(64), nullable=False)
    # AES-GCM of the client's hash and the bond code (security.DeviceVault).
    secret: Mapped[bytes] = mapped_column(LargeBinary, nullable=False)
    name: Mapped[str] = mapped_column(String(64), nullable=False, default="")
    firmware: Mapped[str] = mapped_column(String(32), nullable=False, default="")
    created_at: Mapped[datetime] = _time()
    updated_at: Mapped[datetime] = _time()


class Feedback(Base):
    __tablename__ = "feedback"
    id: Mapped[uuid.UUID] = _id()
    user_id: Mapped[uuid.UUID] = _owner()
    content: Mapped[str] = mapped_column(Text, nullable=False)
    app_version: Mapped[str] = mapped_column(String(32), nullable=False, default="")
    created_at: Mapped[datetime] = _time()


class IdempotencyRecord(Base):
    """The first response to a write with an Idempotency-Key, replayed for 24 h (prd.md §7.1)."""

    __tablename__ = "idempotency_records"
    __table_args__ = (UniqueConstraint("scope", "key", name="idempotency_scope_key"),)
    id: Mapped[uuid.UUID] = _id()
    # Whose key: "user:<id>" for a signed-in caller, else a hash or "anonymous" (idempotency.py).
    scope: Mapped[str] = mapped_column(String(64), nullable=False)
    key: Mapped[str] = mapped_column(String(255), nullable=False)
    request_hash: Mapped[str] = mapped_column(String(64), nullable=False)
    # Null while the first request is still running.
    status_code: Mapped[int | None] = mapped_column(Integer)
    content_type: Mapped[str | None] = mapped_column(String(100))
    body: Mapped[bytes | None] = mapped_column(LargeBinary)
    created_at: Mapped[datetime] = _time()
