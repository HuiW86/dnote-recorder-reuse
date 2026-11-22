"""/v1/recordings: recording metadata and its audio in object storage (prd.md §7.2 录音与上传).

Uploading audio, from the app's side:

1. `POST /recordings` with the metadata and the audio's SHA-256, size and type. The answer has
   the recording and an `upload`: one presigned URL per part. The same audio already in the
   account gives back that recording instead of a second one (§7.5, X3).
2. PUT each part's bytes to its URL, straight to storage.
3. `POST /recordings/{id}/upload-complete`. The server checks the stored parts against the
   declared size and joins them.

Interrupted? `POST /recordings/{id}/upload` (or step 1 again) gives fresh URLs and says which
parts are already stored. Recordings without audio (imported text, prd.md §5.2.1) skip 2 and 3."""

import base64
import binascii
import hashlib
import json
import re
import secrets
import uuid
from datetime import datetime, timedelta
from typing import Literal

from fastapi import APIRouter, BackgroundTasks, Query, Response
from pydantic import AwareDatetime, BaseModel, Field
from sqlalchemy import select, text, tuple_
from sqlalchemy.ext.asyncio import AsyncSession

from ..accounts import CurrentUser
from ..errors import AppError
from ..maintenance import drain_deletions, queue_deletion
from ..models import Device, Recording, User
from ..runtime import DB, Run, Runtime
from ..storage import StoredPart, UploadMismatch
from ..tasks import cancel as cancel_tasks

router = APIRouter(prefix="/recordings", tags=["recordings"])

HEX64 = r"^[0-9a-fA-F]{64}$"
EXTENSIONS = {
    "audio/ogg": ".ogg",
    "audio/opus": ".opus",
    "audio/mp4": ".m4a",
    "audio/x-m4a": ".m4a",
    "audio/aac": ".aac",
    "audio/mpeg": ".mp3",
    "audio/wav": ".wav",
    "audio/x-wav": ".wav",
    "audio/x-caf": ".caf",
    "audio/flac": ".flac",
}


class AudioIn(BaseModel):
    sha256: str = Field(pattern=HEX64)
    size: int = Field(gt=0)
    content_type: str = Field(default="audio/ogg", pattern=r"^audio/[a-z0-9.+-]{1,50}$")


class RecordingIn(BaseModel):
    source: Literal["card", "phone", "import", "realtime"]
    started_at: AwareDatetime
    duration_ms: int = Field(ge=0, le=7 * 24 * 3600 * 1000)
    title: str = Field(default="", max_length=200)
    # The card it came from, if registered (PUT /devices); an unknown card is left out.
    device_sn_hash: str | None = Field(default=None, pattern=HEX64)
    audio: AudioIn | None = None


class PartDone(BaseModel):
    part_number: int = Field(ge=1, le=10_000)
    etag: str = Field(min_length=1, max_length=100)


class CompleteIn(BaseModel):
    # Optional: without it the server uses the parts the store has. With it, each ETag must match.
    parts: list[PartDone] | None = Field(default=None, max_length=10_000)


class AudioOut(BaseModel):
    sha256: str
    size: int
    content_type: str
    uploaded: bool


class PartOut(BaseModel):
    part_number: int
    offset: int
    size: int
    url: str
    # Already stored: no need to send it again.
    done: bool
    etag: str | None


class UploadOut(BaseModel):
    part_size: int
    expires_at: datetime
    parts: list[PartOut]


class RecordingOut(BaseModel):
    id: uuid.UUID
    source: str
    started_at: datetime
    duration_ms: int
    title: str
    device_sn_hash: str | None
    audio: AudioOut | None
    version: int
    created_at: datetime
    updated_at: datetime
    # Only on answers that hand out upload URLs, and only while the audio is not stored.
    upload: UploadOut | None = None


class RecordingPage(BaseModel):
    items: list[RecordingOut]
    next_cursor: str | None


class AudioUrlOut(BaseModel):
    url: str
    expires_at: datetime


# MARK: Routes


@router.post("", status_code=201)
async def create_recording(body: RecordingIn, user: CurrentUser, db: DB, run: Run, response: Response) -> RecordingOut:
    """201 with a new recording; 200 with the existing one when this account already has the
    same audio (its metadata is left as it was)."""
    now = run.clock.now()
    device_id = await _device_id(db, run, user, body.device_sn_hash)
    if body.audio is not None:
        sha = body.audio.sha256.lower()
        if body.audio.size > run.settings.max_audio_bytes:
            raise AppError(413, "audio_too_large", f"音频超过 {run.settings.max_audio_bytes // 1024 // 1024} MB")
        # Two first-time uploads of the same audio at once must not both insert.
        await db.execute(text("SELECT pg_advisory_xact_lock(:key)"), {"key": _lock_key(user.id, sha)})
        existing = await db.scalar(
            select(Recording)
            .where(Recording.user_id == user.id, Recording.audio_sha256 == sha, Recording.deleted_at.is_(None))
            .with_for_update()
        )
        if existing is not None:
            response.status_code = 200
            return await _with_upload(db, run, existing)
    recording = Recording(
        id=uuid.uuid4(),
        user_id=user.id,
        device_id=device_id,
        source=body.source,
        started_at=body.started_at,
        duration_ms=body.duration_ms,
        title=body.title.strip(),
        audio_sha256=body.audio.sha256.lower() if body.audio else None,
        audio_size=body.audio.size if body.audio else None,
        audio_content_type=body.audio.content_type if body.audio else None,
        version=1,
        created_at=now,
        updated_at=now,
    )
    db.add(recording)
    await db.flush()
    return await _with_upload(db, run, recording)


@router.get("")
async def list_recordings(
    user: CurrentUser,
    db: DB,
    run: Run,
    limit: int = Query(default=50, ge=1, le=200),
    cursor: str | None = Query(default=None, max_length=200),
) -> RecordingPage:
    """Newest first by start time. Pass `next_cursor` back as `cursor` for the next page."""
    query = select(Recording).where(Recording.user_id == user.id, Recording.deleted_at.is_(None))
    if cursor is not None:
        started_at, last_id = _read_cursor(cursor)
        query = query.where(tuple_(Recording.started_at, Recording.id) < tuple_(started_at, last_id))
    rows = list(await db.scalars(query.order_by(Recording.started_at.desc(), Recording.id.desc()).limit(limit + 1)))
    page, more = rows[:limit], len(rows) > limit
    return RecordingPage(
        items=await _outs(db, run, page),
        next_cursor=_write_cursor(page[-1]) if more else None,
    )


@router.get("/{recording_id}")
async def get_recording(recording_id: uuid.UUID, user: CurrentUser, db: DB, run: Run) -> RecordingOut:
    return (await _outs(db, run, [await _owned(db, user, recording_id)]))[0]


@router.post("/{recording_id}/upload")
async def resume_upload(recording_id: uuid.UUID, user: CurrentUser, db: DB, run: Run) -> RecordingOut:
    """Fresh part URLs and which parts are stored. `upload` is null when the audio is already
    stored; a recording without audio is a 409."""
    recording = await _owned(db, user, recording_id, lock=True)
    if recording.audio_sha256 is None:
        raise AppError(409, "no_audio", "这条录音没有音频")
    return await _with_upload(db, run, recording)


@router.post("/{recording_id}/upload-complete")
async def complete_upload(
    recording_id: uuid.UUID, user: CurrentUser, db: DB, run: Run, body: CompleteIn | None = None
) -> RecordingOut:
    """Joins the stored parts into the audio. Doing it again once stored is not an error."""
    recording = await _owned(db, user, recording_id, lock=True)
    if recording.audio_sha256 is None:
        raise AppError(409, "no_audio", "这条录音没有音频")
    if recording.uploaded_at is not None:
        return (await _outs(db, run, [recording]))[0]
    if recording.upload_id is None or recording.audio_object_key is None:
        raise AppError(409, "upload_not_started", "还没有开始上传，请先获取上传地址")
    assert recording.audio_size is not None
    expected = _plan(recording.audio_size, run.settings.upload_part_bytes)
    listed = await _call(run.store.uploaded_parts(recording.audio_object_key, recording.upload_id))
    if listed is None:
        # The store forgot the upload (expired by a lifecycle rule): start again.
        recording.upload_id = None
        raise AppError(409, "upload_expired", "这次上传已失效，请重新获取上传地址", keep_changes=True)
    stored = {p.number: p for p in listed}
    missing = [n for n, (_, size) in expected.items() if n not in stored or stored[n].size != size]
    extra = set(stored) - set(expected)
    if missing or extra:
        raise AppError(
            409, "upload_incomplete", f"还有 {len(missing)} 个分片没有传完或大小不对，请重新获取上传地址后补传"
        )
    if body is not None and body.parts is not None:
        named = {p.part_number: p.etag for p in body.parts}
        if set(named) != set(expected) or any(stored[n].etag != etag for n, etag in named.items()):
            raise AppError(409, "upload_mismatch", "分片的 ETag 和已上传的不一致")
    try:
        size = await _call(
            run.store.finish_upload(
                recording.audio_object_key, recording.upload_id, [(n, stored[n].etag) for n in sorted(expected)]
            )
        )
    except UploadMismatch as error:
        raise AppError(409, "upload_incomplete", "分片在合并时不完整，请重新获取上传地址后补传") from error
    now = run.clock.now()
    recording.upload_id = None
    recording.uploaded_at = now
    recording.updated_at = now
    recording.version += 1
    if size != recording.audio_size:
        # Should not happen after the part check; never keep audio that is not what was declared.
        queue_deletion(db, recording, now)
        recording.uploaded_at = None
        recording.audio_object_key = None
        raise AppError(409, "upload_size_mismatch", "上传的音频大小不对，请重新上传", keep_changes=True)
    return (await _outs(db, run, [recording]))[0]


@router.get("/{recording_id}/audio-url")
async def audio_url(recording_id: uuid.UUID, user: CurrentUser, db: DB, run: Run) -> AudioUrlOut:
    """A short-lived URL to download the audio (a new phone restoring the library, M4)."""
    recording = await _owned(db, user, recording_id)
    if recording.uploaded_at is None or recording.audio_object_key is None:
        raise AppError(409, "audio_not_uploaded", "这条录音的音频还没有上传")
    expires_at = run.clock.now() + timedelta(seconds=run.settings.audio_url_ttl_seconds)
    name = _file_name(recording)
    return AudioUrlOut(url=run.store.download_url(recording.audio_object_key, expires_at, name), expires_at=expires_at)


@router.delete("/{recording_id}", status_code=204)
async def delete_recording(
    recording_id: uuid.UUID, user: CurrentUser, db: DB, run: Run, background: BackgroundTasks
) -> Response:
    """Keeps a tombstone for sync (prd.md §7.5) and removes the audio from storage."""
    recording = await _owned(db, user, recording_id, lock=True)
    now = run.clock.now()
    if queue_deletion(db, recording, now):
        background.add_task(drain_deletions, run, 50)
    recording.audio_object_key = None
    recording.upload_id = None
    recording.uploaded_at = None
    recording.deleted_at = now
    recording.updated_at = now
    recording.version += 1
    await cancel_tasks(db, run, recording.id, "recording_deleted", "录音已删除")
    return Response(status_code=204)


# MARK: Helpers


async def _owned(db: AsyncSession, user: User, recording_id: uuid.UUID, lock: bool = False) -> Recording:
    query = select(Recording).where(
        Recording.id == recording_id, Recording.user_id == user.id, Recording.deleted_at.is_(None)
    )
    recording = await db.scalar(query.with_for_update() if lock else query)
    if recording is None:
        raise AppError(404, "recording_not_found", "账号里没有这条录音")
    return recording


async def _device_id(db: AsyncSession, run: Runtime, user: User, sn_hash: str | None) -> uuid.UUID | None:
    if sn_hash is None:
        return None
    return await db.scalar(
        select(Device.id).where(Device.user_id == user.id, Device.sn_key == run.vault.lookup_key(sn_hash.lower()))
    )


def _lock_key(user_id: uuid.UUID, sha: str) -> int:
    return int.from_bytes(hashlib.sha256(f"{user_id}:{sha}".encode()).digest()[:8], "big", signed=True)


def _plan(size: int, part_size: int) -> dict[int, tuple[int, int]]:
    """Part number → (offset, size). Parts are `part_size` except a shorter last one."""
    count = -(-size // part_size)
    return {n: ((n - 1) * part_size, min(part_size, size - (n - 1) * part_size)) for n in range(1, count + 1)}


async def _call(awaitable):
    """Store calls: a mismatch is the caller's to report, anything else is the store failing."""
    try:
        return await awaitable
    except (UploadMismatch, AppError):
        raise
    except Exception as error:
        raise AppError(502, "storage_unavailable", "存储服务暂时不可用，请稍后再试", retryable=True) from error


async def _with_upload(db: AsyncSession, run: Runtime, recording: Recording) -> RecordingOut:
    """The recording, plus upload URLs while it has audio that is not stored yet. Starts an upload
    (with a fresh object key) when none is under way."""
    out = (await _outs(db, run, [recording]))[0]
    if recording.audio_size is None or recording.uploaded_at is not None:
        return out
    stored: list[StoredPart] | None = None
    if recording.upload_id is not None:
        assert recording.audio_object_key is not None
        stored = await _call(run.store.uploaded_parts(recording.audio_object_key, recording.upload_id))
    if stored is None:
        # No upload under way, or the store forgot it: start one.
        recording.audio_object_key = f"audio/{recording.user_id}/{recording.id}/{secrets.token_hex(8)}"
        recording.upload_id = await _call(
            run.store.start_upload(recording.audio_object_key, recording.audio_content_type or "audio/ogg")
        )
        recording.updated_at = run.clock.now()
        await db.flush()
        stored = []
    done = {p.number: p for p in stored}
    part_size = run.settings.upload_part_bytes
    expires_at = run.clock.now() + timedelta(seconds=run.settings.upload_url_ttl_seconds)
    key, upload_id = recording.audio_object_key, recording.upload_id
    assert key is not None and upload_id is not None
    parts = []
    for number, (offset, size) in _plan(recording.audio_size, part_size).items():
        ok = number in done and done[number].size == size
        parts.append(
            PartOut(
                part_number=number,
                offset=offset,
                size=size,
                url=run.store.part_url(key, upload_id, number, expires_at),
                done=ok,
                etag=done[number].etag if ok else None,
            )
        )
    out.upload = UploadOut(part_size=part_size, expires_at=expires_at, parts=parts)
    return out


async def _outs(db: AsyncSession, run: Runtime, recordings: list[Recording]) -> list[RecordingOut]:
    device_ids = {r.device_id for r in recordings if r.device_id is not None}
    sn_hashes: dict[uuid.UUID, str] = {}
    if device_ids:
        for device in await db.scalars(select(Device).where(Device.id.in_(device_ids))):
            sn_hashes[device.id] = run.vault.open(device.user_id, device.sn_key, device.secret).sn_hash
    return [
        RecordingOut(
            id=r.id,
            source=r.source,
            started_at=r.started_at,
            duration_ms=r.duration_ms,
            title=r.title,
            device_sn_hash=sn_hashes.get(r.device_id) if r.device_id else None,
            audio=(
                AudioOut(
                    sha256=r.audio_sha256,
                    size=r.audio_size or 0,
                    content_type=r.audio_content_type or "",
                    uploaded=r.uploaded_at is not None,
                )
                if r.audio_sha256
                else None
            ),
            version=r.version,
            created_at=r.created_at,
            updated_at=r.updated_at,
        )
        for r in recordings
    ]


def _write_cursor(recording: Recording) -> str:
    raw = json.dumps([recording.started_at.isoformat(), str(recording.id)]).encode()
    return base64.urlsafe_b64encode(raw).decode()


def _read_cursor(cursor: str) -> tuple[datetime, uuid.UUID]:
    try:
        started_at, last_id = json.loads(base64.urlsafe_b64decode(cursor.encode()))
        return datetime.fromisoformat(started_at), uuid.UUID(last_id)
    except (ValueError, TypeError, binascii.Error) as error:
        raise AppError(422, "invalid_cursor", "分页参数不对") from error


def _file_name(recording: Recording) -> str:
    title = re.sub(r'[\x00-\x1f/\\:*?"<>|]', " ", recording.title).strip()[:80]
    if not title:
        title = recording.started_at.strftime("%Y-%m-%d %H-%M-%S")
    return title + EXTENSIONS.get(recording.audio_content_type or "", "")
