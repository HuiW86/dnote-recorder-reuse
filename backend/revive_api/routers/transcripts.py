"""Server-side transcription (features.md F1, prd.md §7.2 转写) and the task it runs as (§7.4); also the
app's own transcript, put here so a summary can be written from text (product-spec.md §7.3b).

`POST /recordings/{id}/transcribe` queues a task; the app polls `GET /tasks/{id}` (2 s, backing off
to 30 s) and then reads `GET /recordings/{id}/transcript`."""

import uuid
from datetime import datetime

from fastapi import APIRouter, Response
from pydantic import BaseModel, Field
from sqlalchemy import select

from .. import usage
from ..accounts import CurrentUser
from ..errors import AppError
from ..models import Recording, Task, Transcript
from ..runtime import DB, Run
from ..tasks import QUEUED, RUNNING, enqueue
from ..transcription import KIND as TRANSCRIBE

router = APIRouter(tags=["transcripts"])


class TranscribeIn(BaseModel):
    # "zh", "en", "zh-CN", or "auto"
    language: str = Field(default="zh", pattern=r"^([a-z]{2}(-[A-Z]{2})?|auto)$")
    # Tell the speakers apart (diarization).
    speakers: bool = True


class TaskErrorOut(BaseModel):
    code: str
    message: str


class TaskOut(BaseModel):
    id: uuid.UUID
    kind: str
    recording_id: uuid.UUID | None
    # queued, running, succeeded, failed. A retry waiting shows queued with the last error.
    status: str
    attempts: int
    error: TaskErrorOut | None
    # Kinds that answer on the task itself: retitle gives {"title", "model"}. Null otherwise.
    result: dict | None = None
    created_at: datetime
    updated_at: datetime
    finished_at: datetime | None

    @classmethod
    def of(cls, task: Task) -> "TaskOut":
        return cls(
            id=task.id,
            kind=task.kind,
            recording_id=task.recording_id,
            status=task.status,
            attempts=task.attempts,
            error=TaskErrorOut(code=task.error_code, message=task.error_message or "") if task.error_code else None,
            result=task.result,
            created_at=task.created_at,
            updated_at=task.updated_at,
            finished_at=task.finished_at,
        )


class SegmentOut(BaseModel):
    start_ms: int
    end_ms: int
    speaker: str | None
    text: str


class TranscriptOut(BaseModel):
    recording_id: uuid.UUID
    language: str
    segments: list[SegmentOut]
    # Names the user gave the engine's labels; labels without a name are absent.
    speakers: dict[str, str]
    asr_provider: str
    created_at: datetime
    updated_at: datetime

    @classmethod
    def of(cls, transcript: Transcript) -> "TranscriptOut":
        return cls(
            recording_id=transcript.recording_id,
            language=transcript.language,
            segments=[SegmentOut(**s) for s in transcript.segments],
            speakers=transcript.speakers,
            asr_provider=transcript.asr_provider,
            created_at=transcript.created_at,
            updated_at=transcript.updated_at,
        )


class SpeakersIn(BaseModel):
    # Label → name. An empty name removes the name.
    speakers: dict[str, str] = Field(max_length=50)


@router.post("/recordings/{recording_id}/transcribe", status_code=202)
async def transcribe(
    recording_id: uuid.UUID, user: CurrentUser, db: DB, run: Run, response: Response, body: TranscribeIn | None = None
) -> TaskOut:
    """202 with a new task; 200 with the one already queued or running for this recording.
    429 `quota_exceeded` when this month's transcription time would run out (usage.py)."""
    body = body or TranscribeIn()
    await usage.lock(db, user)  # user row first, as DELETE /me does
    recording = await db.scalar(
        select(Recording)
        .where(Recording.id == recording_id, Recording.user_id == user.id, Recording.deleted_at.is_(None))
        .with_for_update()
    )
    if recording is None:
        raise AppError(404, "recording_not_found", "账号里没有这条录音")
    if recording.uploaded_at is None:
        raise AppError(409, "audio_not_uploaded", "这条录音的音频还没有上传")
    pending = await db.scalar(
        select(Task).where(
            Task.recording_id == recording.id, Task.kind == TRANSCRIBE, Task.status.in_([QUEUED, RUNNING])
        )
    )
    if pending is not None:
        response.status_code = 200
        return TaskOut.of(pending)
    await usage.check_pending(db, run, user)
    await usage.check_transcribe(db, run, user, recording.duration_ms)
    task = await enqueue(db, run, user_id=user.id, kind=TRANSCRIBE, recording_id=recording.id, params=body.model_dump())
    return TaskOut.of(task)


@router.get("/tasks/{task_id}")
async def get_task(task_id: uuid.UUID, user: CurrentUser, db: DB) -> TaskOut:
    task = await db.scalar(select(Task).where(Task.id == task_id, Task.user_id == user.id))
    if task is None:
        raise AppError(404, "task_not_found", "没有这个任务")
    return TaskOut.of(task)


@router.get("/recordings/{recording_id}/transcript")
async def get_transcript(recording_id: uuid.UUID, user: CurrentUser, db: DB) -> TranscriptOut:
    return TranscriptOut.of(await _transcript(db, user, recording_id))


@router.patch("/recordings/{recording_id}/speakers")
async def rename_speakers(
    recording_id: uuid.UUID, body: SpeakersIn, user: CurrentUser, db: DB, run: Run
) -> TranscriptOut:
    """Names the speakers. Only labels that occur in the transcript can be named."""
    transcript = await _transcript(db, user, recording_id, lock=True)
    labels = {s["speaker"] for s in transcript.segments if s.get("speaker")}
    unknown = sorted(set(body.speakers) - labels)
    if unknown:
        raise AppError(422, "unknown_speaker", f"文字稿里没有说话人 {', '.join(unknown)}")
    names = dict(transcript.speakers)
    for label, name in body.speakers.items():
        name = name.strip()
        if len(name) > 32:
            raise AppError(422, "speaker_name_too_long", "说话人名称最多 32 个字")
        if name:
            names[label] = name
        else:
            names.pop(label, None)
    transcript.speakers = names
    transcript.updated_at = run.clock.now()
    return TranscriptOut.of(transcript)


class ClientSegmentIn(BaseModel):
    start_ms: int = Field(ge=0)
    end_ms: int = Field(ge=0)
    speaker: str | None = Field(default=None, max_length=32)
    text: str = Field(max_length=10_000)


class ClientTranscriptIn(BaseModel):
    language: str = Field(default="zh", pattern=r"^([a-z]{2}(-[A-Z]{2})?|auto)$")
    # What made it on the phone: "on-device", "own-service". Stored as "app:<engine>".
    engine: str = Field(pattern=r"^[a-z0-9-]{1,32}$")
    segments: list[ClientSegmentIn] = Field(min_length=1, max_length=20_000)


# Characters of text a client transcript may hold: about 40 hours of speech.
CLIENT_TEXT_LIMIT = 2_000_000


@router.put("/recordings/{recording_id}/transcript")
async def put_transcript(
    recording_id: uuid.UUID, body: ClientTranscriptIn, user: CurrentUser, db: DB, run: Run
) -> TranscriptOut:
    """The app's own transcript (made on the phone or by the user's own service), so a summary
    can be written from text without uploading the audio (product-spec.md §7.3b). The recording
    may have no audio. Replaces any transcript there; speaker names start over. 409
    `transcription_running` while a server transcription is queued or running for it."""
    recording = await db.scalar(
        select(Recording)
        .where(Recording.id == recording_id, Recording.user_id == user.id, Recording.deleted_at.is_(None))
        .with_for_update()
    )
    if recording is None:
        raise AppError(404, "recording_not_found", "账号里没有这条录音")
    pending = await db.scalar(
        select(Task.id).where(
            Task.recording_id == recording.id, Task.kind == TRANSCRIBE, Task.status.in_([QUEUED, RUNNING])
        )
    )
    if pending is not None:
        raise AppError(409, "transcription_running", "服务器正在转写这条录音，请等它完成")
    if any(s.end_ms < s.start_ms for s in body.segments):
        raise AppError(422, "invalid_segment", "文字稿里有一句的结束时间早于开始时间")
    if sum(len(s.text) for s in body.segments) > CLIENT_TEXT_LIMIT:
        raise AppError(413, "transcript_too_large", "文字稿太长")
    segments = [s.model_dump() for s in sorted(body.segments, key=lambda s: (s.start_ms, s.end_ms))]
    now = run.clock.now()
    transcript = await db.get(Transcript, recording.id, with_for_update=True)
    if transcript is None:
        transcript = Transcript(recording_id=recording.id, created_at=now)
        db.add(transcript)
    transcript.language = body.language
    transcript.segments = segments
    transcript.speakers = {}
    transcript.asr_provider = f"app:{body.engine}"
    transcript.updated_at = now
    await db.flush()
    return TranscriptOut.of(transcript)


async def _transcript(db, user, recording_id: uuid.UUID, lock: bool = False) -> Transcript:
    query = (
        select(Transcript)
        .join(Recording, Recording.id == Transcript.recording_id)
        .where(Recording.id == recording_id, Recording.user_id == user.id, Recording.deleted_at.is_(None))
    )
    transcript = await db.scalar(query.with_for_update(of=Transcript) if lock else query)
    if transcript is None:
        raise AppError(404, "transcript_not_found", "这条录音还没有文字稿")
    return transcript
