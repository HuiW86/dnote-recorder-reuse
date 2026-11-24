"""A new title from another angle through the backend (G1 换一个角度重起标题)."""

import pytest
from conftest import bearer
from sqlalchemy import text
from test_recordings import uploaded
from test_summaries import GOOD, ScriptedModel, transcribed
from test_transcripts import task_of

from revive_api import summaries, tasks
from revive_api.llm import ChatModelError
from revive_api.worker import HANDLERS


@pytest.fixture
def model(h) -> ScriptedModel:
    h.run.chat = ScriptedModel(replies=['{"title": " 周四发外部测试 "}'])
    return h.run.chat


def test_reads_a_new_title_like_the_app():
    # The app's SummaryParsingTests.readsANewTitle, plus quotes mixed with spaces.
    assert summaries.parse_title('{"title": " 周四发外部测试 "}') == "周四发外部测试"
    assert summaries.parse_title("<think>想一想</think>\n「定下发布日」\n多余的话") == "定下发布日"
    assert len(summaries.parse_title("长" * 40)) == 30
    assert summaries.parse_title(" 「 “新标题” 」 ") == "新标题"
    assert summaries.parse_title("{坏的 JSON\n第二行") == "{坏的 JSON"
    for empty in ('{"title": ""}', "", "<think>只想不答</think>", "「」"):
        with pytest.raises(summaries.BadReply):
            summaries.parse_title(empty)
    assert "不要和「现在的标题」相同" in summaries.RETITLE_PROMPT
    assert summaries.retitle_message("甲" * 9500, "旧") == "现在的标题：旧\n\n内容：\n" + "甲" * 9000


async def test_retitle_from_the_transcript_then_the_newest_summary(h, model):
    tokens = await h.sms_login()
    recording = await transcribed(h, tokens)
    path = f"/v1/recordings/{recording['id']}/retitle"
    queued = await h.http.post(path, headers=bearer(tokens), json={"current_title": " 2026-11-20 09:30 "})
    assert queued.status_code == 202 and queued.json()["kind"] == "retitle" and queued.json()["result"] is None
    assert await tasks.run_one(h.run, HANDLERS)
    done = await task_of(h, tokens, queued.json()["id"])
    assert done["status"] == "succeeded"
    assert done["result"] == {"title": "周四发外部测试", "model": "scripted-model-1"}
    # The app's prompt and message; without a summary the material is the transcript.
    assert model.calls[0] == {
        "system": summaries.RETITLE_PROMPT,
        "user": "现在的标题：2026-11-20 09:30\n\n内容：\n大家好，开始开会。\n先说回款。\n好的。",
        "json": True,
    }
    # The recording's own title is left for the app to change.
    assert (await h.http.get(f"/v1/recordings/{recording['id']}", headers=bearer(tokens))).json()["title"] == "周会"

    # With a summary, its title and summary are the material; no current title falls back to the stored one.
    model.replies = [GOOD, "「换个说法」"]
    await h.http.post(f"/v1/recordings/{recording['id']}/summaries", headers=bearer(tokens))
    await tasks.run_one(h.run, HANDLERS)
    again = await h.http.post(path, headers=bearer(tokens))
    await tasks.run_one(h.run, HANDLERS)
    assert model.calls[-1]["user"] == "现在的标题：周会\n\n内容：\n周会排期\n下周三上线。"
    assert (await task_of(h, tokens, again.json()["id"]))["result"]["title"] == "换个说法"
    async with h.run.engine.connect() as connection:
        spent = (
            await connection.execute(text("SELECT sum(amount) FROM usage_records WHERE kind = 'llm_tokens'"))
        ).scalar()
    assert spent == 3 * 120


async def test_retitle_needs_content_and_is_not_queued_twice(h, model):
    tokens = await h.sms_login()
    bare = await uploaded(h, tokens, b"nothing to read yet")
    early = await h.http.post(f"/v1/recordings/{bare['id']}/retitle", headers=bearer(tokens))
    assert early.status_code == 409 and early.json()["error"]["code"] == "no_content"
    recording = await transcribed(h, tokens)
    path = f"/v1/recordings/{recording['id']}/retitle"
    first = await h.http.post(path, headers=bearer(tokens))
    again = await h.http.post(path, headers=bearer(tokens))
    assert again.status_code == 200 and again.json()["id"] == first.json()["id"]
    other = await h.sms_login("13900000000")
    assert (await h.http.post(path, headers=bearer(other))).status_code == 404
    too_long = await h.http.post(path, headers=bearer(tokens), json={"current_title": "长" * 201})
    assert too_long.status_code == 422


async def test_retitle_failures_and_quota(h, model):
    tokens = await h.sms_login()
    recording = await transcribed(h, tokens)
    path = f"/v1/recordings/{recording['id']}/retitle"
    model.replies = ["<think>只想不答</think>", "新标题"]
    task_id = (await h.http.post(path, headers=bearer(tokens))).json()["id"]
    await tasks.run_one(h.run, HANDLERS)
    state = await task_of(h, tokens, task_id)
    assert state["status"] == "queued" and state["error"]["code"] == "bad_reply" and state["result"] is None
    h.clock.advance(seconds=30)
    await tasks.run_one(h.run, HANDLERS)
    tokens = await h.sms_login()
    assert (await task_of(h, tokens, task_id))["result"]["title"] == "新标题"

    model.replies = [ChatModelError("llm_refused", "内容不合规，模型拒绝回答", retryable=False)]
    task_id = (await h.http.post(path, headers=bearer(tokens))).json()["id"]
    await tasks.run_one(h.run, HANDLERS)
    state = await task_of(h, tokens, task_id)
    assert state["status"] == "failed" and state["error"]["code"] == "llm_refused"

    h.run.settings = h.run.settings.model_copy(update={"llm_monthly_tokens": 100})
    refused = await h.http.post(path, headers=bearer(tokens))
    assert refused.status_code == 429 and refused.json()["error"]["code"] == "quota_exceeded"


async def test_deleting_the_recording_drops_a_pending_retitle(h, model):
    tokens = await h.sms_login()
    recording = await transcribed(h, tokens)
    task_id = (await h.http.post(f"/v1/recordings/{recording['id']}/retitle", headers=bearer(tokens))).json()["id"]
    await h.http.delete(f"/v1/recordings/{recording['id']}", headers=bearer(tokens))
    assert await tasks.run_one(h.run, HANDLERS) is False
    state = await task_of(h, tokens, task_id)
    assert (state["status"], state["error"]["code"], state["result"]) == ("failed", "recording_deleted", None)
