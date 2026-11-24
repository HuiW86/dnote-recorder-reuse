"""The `transcribe` task (features.md F1): hand the stored audio to the ASR engine and keep the
transcript. The engine call happens outside any database transaction; the transcript, the usage
record and the task's success are written together."""

import math
from datetime import timedelta

from sqlalchemy import select

from .asr import TranscriberError
from .models import Recording, Transcript, UsageRecord
from .runtime import Runtime
from .tasks import Claimed, TaskError, finishing

KIND = "transcribe"


async def transcribe(run: Runtime, claimed: Claimed) -> None:
    async with run.sessions() as db:
        recording = await db.get(Recording, claimed.recording_id)
        if recording is None or recording.deleted_at is not None:
            raise TaskError("recording_deleted", "录音已删除")
        if recording.uploaded_at is None or recording.audio_object_key is None:
            raise TaskError("audio_not_uploaded", "这条录音的音频还没有上传")
        key, content_type, duration_ms = recording.audio_object_key, recording.audio_content_type, recording.duration_ms

    # Long enough for the engine to fetch it even after waiting in its own queue.
    url = run.store.download_url(key, run.clock.now() + timedelta(hours=6), "audio")
    try:
        result = await run.transcriber.transcribe(
            url,
            content_type or "audio/ogg",
            claimed.params.get("language", "zh"),
            claimed.params.get("speakers", True),
            duration_ms,
        )
    except TranscriberError as error:
        raise TaskError(error.code, error.message, error.retryable) from error

    async with finishing(run, claimed) as done:
        db = done.db
        recording = await db.scalar(select(Recording).where(Recording.id == claimed.recording_id).with_for_update())
        if recording is None or recording.deleted_at is not None or recording.audio_object_key != key:
            raise TaskError("recording_deleted", "录音已删除")
        now = run.clock.now()
        segments = [
            {"start_ms": s.start_ms, "end_ms": s.end_ms, "speaker": s.speaker, "text": s.text} for s in result.segments
        ]
        transcript = await db.get(Transcript, recording.id, with_for_update=True)
        if transcript is None:
            db.add(
                Transcript(
                    recording_id=recording.id,
                    language=result.language,
                    segments=segments,
                    speakers={},
                    asr_provider=result.provider,
                    created_at=now,
                    updated_at=now,
                )
            )
        else:
            # New speaker labels need naming again.
            transcript.language, transcript.segments, transcript.speakers = result.language, segments, {}
            transcript.asr_provider, transcript.created_at, transcript.updated_at = result.provider, now, now
        db.add(
            UsageRecord(
                user_id=claimed.user_id,
                kind="asr_seconds",
                amount=math.ceil(result.audio_ms / 1000),
                occurred_at=now,
            )
        )
