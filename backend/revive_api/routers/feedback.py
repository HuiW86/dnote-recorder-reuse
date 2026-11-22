"""/v1/feedback: 意见反馈 from inside the app (features.md O1b)."""

import uuid

from fastapi import APIRouter
from pydantic import BaseModel, Field

from ..accounts import CurrentUser
from ..models import Feedback
from ..runtime import DB, Run

router = APIRouter(prefix="/feedback", tags=["feedback"])


class FeedbackIn(BaseModel):
    content: str = Field(min_length=1, max_length=5000)
    app_version: str = Field(default="", max_length=32)


class FeedbackOut(BaseModel):
    id: uuid.UUID


@router.post("", status_code=201)
async def send_feedback(body: FeedbackIn, user: CurrentUser, db: DB, run: Run) -> FeedbackOut:
    item = Feedback(
        id=uuid.uuid4(),
        user_id=user.id,
        content=body.content.strip(),
        app_version=body.app_version,
        created_at=run.clock.now(),
    )
    db.add(item)
    await db.flush()
    return FeedbackOut(id=item.id)
