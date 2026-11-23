"""AI summaries through the backend (features.md G1, G2a; prd.md §7.2 AI 生成): the same prompts
and scenes the app uses with a service the user configures (ADR-009).

`POST /recordings/{id}/summaries` queues a task; the app polls `GET /tasks/{id}` and then reads
`GET /recordings/{id}/summaries`, newest first. The built-in templates are the ten scenes
(`GET /templates`); no `template_id` lets the model pick the scene."""

import uuid
from datetime import datetime

from fastapi import APIRouter, Response
from pydantic import BaseModel, Field
from sqlalchemy import select

from .. import summaries as prompts
from .. import usage
from ..accounts import CurrentUser
from ..errors import AppError
from ..models import Recording, Summary, Task, Transcript
from ..runtime import DB, Run
from ..summarize import KIND as SUMMARIZE
from ..tasks import QUEUED, RUNNING, enqueue
from .transcripts import TaskOut

router = APIRouter(tags=["summaries"])


class TemplateOut(BaseModel):
    id: str
    name: str
    # One sentence telling the scenes apart (what the model reads too).
    definition: str
    # The headed sections a summary of this scene has.
    headings: list[str]
    is_builtin: bool = True


class SummarizeIn(BaseModel):
    # A scene code from GET /templates; null lets the model choose.
    template_id: str | None = None
    # The user's job (features.md G1 职业设定): reorders and rewords, never adds. Cut to 40 characters.
    profession: str = Field(default="", max_length=200)


class SectionOut(BaseModel):
    heading: str
    items: list[str]


class OutlineOut(BaseModel):
    title: str
    points: list[str]


class SummaryOut(BaseModel):
    id: uuid.UUID
    recording_id: uuid.UUID
    scene: str
    title: str
    summary: str
    sections: list[SectionOut]
    todos: list[str]
    tags: list[str]
    people: list[str]
    outline: list[OutlineOut]
    quotes: list[str]
    model: str
    created_at: datetime

    @classmethod
    def of(cls, row: Summary) -> "SummaryOut":
        return cls(id=row.id, recording_id=row.recording_id, scene=row.scene, model=row.model,
                   created_at=row.created_at, **row.content)  # fmt: skip


@router.get("/templates")
async def templates(user: CurrentUser) -> list[TemplateOut]:
    return [
        TemplateOut(id=s.code, name=s.name, definition=s.definition, headings=list(s.headings)) for s in prompts.SCENES
    ]


@router.post("/recordings/{recording_id}/summaries", status_code=202)
async def summarize(
    recording_id: uuid.UUID, user: CurrentUser, db: DB, run: Run, response: Response, body: SummarizeIn | None = None
) -> TaskOut:
    """202 with a new task; 200 with the one already queued or running for this recording.
    429 `quota_exceeded` once this month's model allowance is used up (usage.py)."""
    body = body or SummarizeIn()
    if body.template_id is not None and body.template_id not in prompts.BY_CODE:
        raise AppError(422, "unknown_template", "没有这个模板")
    await usage.lock(db, user)  # user row first, as DELETE /me does
    recording = await db.scalar(
        select(Recording)
        .where(Recording.id == recording_id, Recording.user_id == user.id, Recording.deleted_at.is_(None))
        .with_for_update()
    )
    if recording is None:
        raise AppError(404, "recording_not_found", "账号里没有这条录音")
    if await db.get(Transcript, recording.id) is None:
        raise AppError(409, "no_transcript", "这条录音还没有文字稿，请先转写")
    pending = await db.scalar(
        select(Task).where(
            Task.recording_id == recording.id, Task.kind == SUMMARIZE, Task.status.in_([QUEUED, RUNNING])
        )
    )
    if pending is not None:
        response.status_code = 200
        return TaskOut.of(pending)
    await usage.check_pending(db, run, user)
    await usage.check_summarize(db, run, user)
    params = {"scene": body.template_id, "profession": body.profession.strip()[: prompts.PROFESSION_LIMIT]}
    return TaskOut.of(await enqueue(db, run, user_id=user.id, kind=SUMMARIZE, recording_id=recording.id, params=params))


@router.get("/recordings/{recording_id}/summaries")
async def list_summaries(recording_id: uuid.UUID, user: CurrentUser, db: DB) -> list[SummaryOut]:
    owned = await db.scalar(
        select(Recording.id).where(
            Recording.id == recording_id, Recording.user_id == user.id, Recording.deleted_at.is_(None)
        )
    )
    if owned is None:
        raise AppError(404, "recording_not_found", "账号里没有这条录音")
    rows = await db.scalars(
        select(Summary).where(Summary.recording_id == recording_id).order_by(Summary.created_at.desc(), Summary.id)
    )
    return [SummaryOut.of(row) for row in rows]
