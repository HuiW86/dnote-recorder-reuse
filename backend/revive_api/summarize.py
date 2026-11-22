"""The `summarize` task (features.md G1, G2a): the transcript to the language model with the app's
prompts (summaries.py), the reply read with the app's rules, the summary kept with the model that
wrote it. Model calls happen outside any database transaction; the summary, the usage record and
the task's success are written together."""

import uuid

from sqlalchemy import select

from . import summaries
from .llm import ChatModelError, ChatReply
from .models import Recording, Summary, Transcript, UsageRecord
from .runtime import Runtime
from .tasks import Claimed, TaskError, finishing

KIND = "summarize"


async def summarize(run: Runtime, claimed: Claimed) -> None:
    async with run.sessions() as db:
        recording = await db.get(Recording, claimed.recording_id)
        if recording is None or recording.deleted_at is not None:
            raise TaskError("recording_deleted", "录音已删除")
        transcript = await db.get(Transcript, recording.id)
        if transcript is None:
            raise TaskError("no_transcript", "这条录音还没有文字稿")
        text, duration_ms = summaries.material(transcript.segments), recording.duration_ms

    scene = claimed.params.get("scene")
    tokens = 0

    async def ask(system: str, user: str, json_reply: bool) -> ChatReply:
        nonlocal tokens
        try:
            reply = await run.chat.complete(system, user, json_reply)
        except ChatModelError as error:
            raise TaskError(error.code, error.message, error.retryable) from error
        tokens += reply.prompt_tokens + reply.completion_tokens
        return reply

    material = text
    if len(text) > summaries.LONG_TRANSCRIPT_THRESHOLD:
        # Long transcripts are compressed chunk by chunk first, as in the app.
        notes = []
        for index, chunk in enumerate(summaries.split(text, summaries.CHUNK_SIZE), 1):
            notes.append((await ask(summaries.chunk_prompt(index), chunk, False)).text)
        material = summaries.chunk_notes(notes)
    reply = await ask(
        summaries.system_prompt(scene, claimed.params.get("profession", "")),
        summaries.user_message(material, duration_ms),
        True,
    )
    try:
        draft = summaries.parse(reply.text, scene)
    except summaries.BadReply as error:
        # Models vary between tries; another one may well be readable.
        raise TaskError("bad_reply", f"AI 的回答格式不对（{error}）", retryable=True) from error

    async with finishing(run, claimed) as db:
        recording = await db.scalar(select(Recording).where(Recording.id == claimed.recording_id).with_for_update())
        if recording is None or recording.deleted_at is not None:
            raise TaskError("recording_deleted", "录音已删除")
        now = run.clock.now()
        db.add(
            Summary(
                id=uuid.uuid4(),
                recording_id=recording.id,
                scene=draft.scene,
                content=draft.content(),
                model=reply.model,
                created_at=now,
            )
        )
        db.add(UsageRecord(user_id=claimed.user_id, kind="llm_tokens", amount=tokens, occurred_at=now))
