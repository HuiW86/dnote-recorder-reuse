"""The `retitle` task (features.md G1 换一个角度重起标题): one request to the language model for a
title from another angle, the way the app does it (Summarizer.retitle). The material is the newest
summary's title and summary, else the transcript. The new title is kept on the task
(`result.title`); the recording's title is the app's to change, by its own rules for user titles
(RecordingLibrary.applyAITitle)."""

from sqlalchemy import select

from . import summaries, usage
from .llm import ChatModelError
from .models import Recording, Summary, Transcript, UsageRecord
from .runtime import Runtime
from .tasks import Claimed, TaskError, finishing

KIND = "retitle"


async def material_of(db, recording_id) -> str:
    """The newest summary as "title\\nsummary", else the transcript text, else ""."""
    summary = await db.scalar(
        select(Summary).where(Summary.recording_id == recording_id).order_by(Summary.created_at.desc()).limit(1)
    )
    if summary is not None:
        return f"{summary.content.get('title', '')}\n{summary.content.get('summary', '')}"
    transcript = await db.get(Transcript, recording_id)
    return summaries.material(transcript.segments) if transcript is not None else ""


async def retitle(run: Runtime, claimed: Claimed) -> None:
    async with run.sessions() as db:
        recording = await db.get(Recording, claimed.recording_id)
        if recording is None or recording.deleted_at is not None:
            raise TaskError("recording_deleted", "录音已删除")
        material = await material_of(db, recording.id)
        current = claimed.params.get("current_title") or recording.title
    if not material:
        raise TaskError("no_content", "这条录音还没有文字稿或纪要")

    try:
        reply = await run.chat.complete(summaries.RETITLE_PROMPT, summaries.retitle_message(material, current), True)
    except ChatModelError as error:
        raise TaskError(error.code, error.message, error.retryable) from error
    tokens = reply.prompt_tokens + reply.completion_tokens
    try:
        try:
            title = summaries.parse_title(reply.text)
        except summaries.BadReply as error:
            raise TaskError("bad_reply", f"AI 的回答格式不对（{error}）", retryable=True) from error

        async with finishing(run, claimed) as done:
            done.db.add(
                UsageRecord(user_id=claimed.user_id, kind="llm_tokens", amount=tokens, occurred_at=run.clock.now())
            )
            done.result = {"title": title, "model": reply.model}
    except Exception:
        # Spent on an attempt that produced nothing: a cost, not billed to the user (usage.py).
        await usage.record_unbilled(run, claimed.user_id, tokens)
        raise
