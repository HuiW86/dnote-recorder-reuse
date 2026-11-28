"""Tables (prd.md §8). Every user-owned row cascades on delete, so DELETE /me removes the account
and everything in it in one statement; stored audio goes through `ObjectDeletion`."""

import uuid
from datetime import datetime

from sqlalchemy import (
    BigInteger,
    CheckConstraint,
    DateTime,
    ForeignKey,
    Index,
    Integer,
    LargeBinary,
    String,
    Text,
    UniqueConstraint,
    text,
)
from sqlalchemy.dialects.postgresql import JSONB, UUID
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


class Recording(Base):
    """A recording's metadata and, when it has audio, where the audio is (prd.md §7.2). Deleting
    one keeps a tombstone (`deleted_at`) for sync (§7.5); its audio is removed."""

    __tablename__ = "recordings"
    __table_args__ = (
        CheckConstraint("source IN ('card', 'phone', 'import', 'realtime')", name="recordings_source"),
        CheckConstraint("duration_ms >= 0", name="recordings_duration"),
        CheckConstraint(
            "(audio_sha256 IS NULL) = (audio_size IS NULL) AND (audio_sha256 IS NULL) = (audio_content_type IS NULL)",
            name="recordings_audio_fields",
        ),
        # The same audio is uploaded once per account (§7.5, X3).
        Index(
            "recordings_user_audio",
            "user_id",
            "audio_sha256",
            unique=True,
            postgresql_where=text("audio_sha256 IS NOT NULL AND deleted_at IS NULL"),
        ),
        Index("recordings_user_started", "user_id", "started_at", "id"),
    )
    id: Mapped[uuid.UUID] = _id()
    user_id: Mapped[uuid.UUID] = _owner()
    device_id: Mapped[uuid.UUID | None] = mapped_column(
        UUID(as_uuid=True), ForeignKey("devices.id", ondelete="SET NULL"), index=True
    )
    # card, phone, import, realtime (the app's Recording.Source)
    source: Mapped[str] = mapped_column(String(16), nullable=False)
    started_at: Mapped[datetime] = _time()
    duration_ms: Mapped[int] = mapped_column(BigInteger, nullable=False)
    title: Mapped[str] = mapped_column(String(200), nullable=False, default="")
    # Null for a text-only recording (prd.md §5.2.1).
    audio_sha256: Mapped[str | None] = mapped_column(String(64))
    audio_size: Mapped[int | None] = mapped_column(BigInteger)
    audio_content_type: Mapped[str | None] = mapped_column(String(64))
    # A fresh key for every upload attempt; the object exists once `uploaded_at` is set.
    audio_object_key: Mapped[str | None] = mapped_column(String(255))
    # The multipart upload under way, if any.
    upload_id: Mapped[str | None] = mapped_column(String(255))
    uploaded_at: Mapped[datetime | None] = _time(nullable=True)
    version: Mapped[int] = mapped_column(Integer, nullable=False, default=1)
    created_at: Mapped[datetime] = _time()
    updated_at: Mapped[datetime] = _time()
    deleted_at: Mapped[datetime | None] = _time(nullable=True)


class ObjectDeletion(Base):
    """Stored audio (or an unfinished upload) still to be removed. Written in the same transaction
    that drops the reference, so nothing is forgotten if the store is down; owned by no one, so it
    survives the account being deleted. Drained by `maintenance.drain_deletions`."""

    __tablename__ = "object_deletions"
    id: Mapped[uuid.UUID] = _id()
    object_key: Mapped[str] = mapped_column(String(255), nullable=False)
    # Set: abort this unfinished upload. Null: delete the object.
    upload_id: Mapped[str | None] = mapped_column(String(255))
    attempts: Mapped[int] = mapped_column(Integer, nullable=False, default=0)
    last_error: Mapped[str | None] = mapped_column(Text)
    created_at: Mapped[datetime] = _time()


class Task(Base):
    """An asynchronous job and its state (prd.md §7.4); queue rules in tasks.py (ADR-013)."""

    __tablename__ = "tasks"
    __table_args__ = (
        CheckConstraint("status IN ('queued', 'running', 'succeeded', 'failed')", name="tasks_status"),
        Index("tasks_due", "run_after", postgresql_where=text("status = 'queued'")),
        Index("tasks_leased", "lease_until", postgresql_where=text("status = 'running'")),
        Index("tasks_recording_kind", "recording_id", "kind"),
    )
    id: Mapped[uuid.UUID] = _id()
    user_id: Mapped[uuid.UUID] = _owner()
    recording_id: Mapped[uuid.UUID | None] = mapped_column(
        UUID(as_uuid=True), ForeignKey("recordings.id", ondelete="CASCADE")
    )
    # transcribe, summarize, retitle
    kind: Mapped[str] = mapped_column(String(32), nullable=False)
    params: Mapped[dict] = mapped_column(JSONB, nullable=False, default=dict)
    status: Mapped[str] = mapped_column(String(16), nullable=False)
    attempts: Mapped[int] = mapped_column(Integer, nullable=False, default=0)
    max_attempts: Mapped[int] = mapped_column(Integer, nullable=False)
    run_after: Mapped[datetime] = _time()
    lease_until: Mapped[datetime | None] = _time(nullable=True)
    # The last failure, kept while a retry waits so the app can show it.
    error_code: Mapped[str | None] = mapped_column(String(64))
    error_message: Mapped[str | None] = mapped_column(String(500))
    # A small answer kept on the task itself, for kinds with no table of their own (retitle: {"title"}).
    result: Mapped[dict | None] = mapped_column(JSONB)
    created_at: Mapped[datetime] = _time()
    updated_at: Mapped[datetime] = _time()
    started_at: Mapped[datetime | None] = _time(nullable=True)
    finished_at: Mapped[datetime | None] = _time(nullable=True)


class Transcript(Base):
    """A recording's transcript from server-side ASR (features.md F1). One per recording;
    transcribing again replaces it."""

    __tablename__ = "transcripts"
    recording_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("recordings.id", ondelete="CASCADE"), primary_key=True
    )
    language: Mapped[str] = mapped_column(String(16), nullable=False)
    # [{start_ms, end_ms, speaker, text}]
    segments: Mapped[list] = mapped_column(JSONB, nullable=False)
    # The user's names for the engine's speaker labels: {"S1": "张三"}
    speakers: Mapped[dict] = mapped_column(JSONB, nullable=False, default=dict)
    # Which engine made it, so transcripts can be redone when a better one comes (backend-design.md §4.5).
    asr_provider: Mapped[str] = mapped_column(String(64), nullable=False)
    created_at: Mapped[datetime] = _time()
    updated_at: Mapped[datetime] = _time()


class Summary(Base):
    """A summary the backend's model wrote (features.md G1). Every generation is kept, newest
    first in GET /recordings/{id}/summaries; the app shows the newest."""

    __tablename__ = "summaries"
    __table_args__ = (Index("summaries_recording_time", "recording_id", "created_at"),)
    id: Mapped[uuid.UUID] = _id()
    recording_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("recordings.id", ondelete="CASCADE"), nullable=False
    )
    # The scene code (summaries.SCENES): the template it was written with.
    scene: Mapped[str] = mapped_column(String(16), nullable=False)
    # title, summary, sections, todos, tags, people, outline, quotes (summaries.Draft)
    content: Mapped[dict] = mapped_column(JSONB, nullable=False)
    model: Mapped[str] = mapped_column(String(100), nullable=False)
    created_at: Mapped[datetime] = _time()


class UsageRecord(Base):
    """What a user consumed (prd.md §8, X2). Kept, without the user, when the account is deleted."""

    __tablename__ = "usage_records"
    __table_args__ = (
        CheckConstraint("kind IN ('asr_seconds', 'llm_tokens')", name="usage_records_kind"),
        Index("usage_records_user_time", "user_id", "occurred_at"),
    )
    id: Mapped[uuid.UUID] = _id()
    user_id: Mapped[uuid.UUID | None] = mapped_column(UUID(as_uuid=True), ForeignKey("users.id", ondelete="SET NULL"))
    kind: Mapped[str] = mapped_column(String(16), nullable=False)
    amount: Mapped[int] = mapped_column(BigInteger, nullable=False)
    occurred_at: Mapped[datetime] = _time()
