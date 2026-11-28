"""AI summaries through the backend (G1, G2a): the app's prompts (ADR-009), its reply rules, and the
summarize task."""

import importlib.util
import json
import uuid
from dataclasses import dataclass, field

import pytest
from conftest import BACKEND, bearer
from sqlalchemy import text
from test_recordings import meta, uploaded
from test_transcripts import ScriptedTranscriber, task_of

from revive_api import summaries, tasks, usage
from revive_api.asr import Segment, TranscriptResult
from revive_api.llm import ChatModelError, ChatReply
from revive_api.worker import HANDLERS

GOOD = json.dumps(
    {
        "scene": "meeting",
        "title": " 周会排期 ",
        "summary": "下周三上线。",
        "sections": [{"heading": "结论与决定", "items": ["下周三上线", " "]}, {"heading": "分歧与风险", "items": []}],
        "todos": ["老王周二前测完", ""],
        "tags": ["#排期", "上线"],
        "people": ["老王"],
    },
    ensure_ascii=False,
)


# MARK: One source of prompts


def _fixture_cases() -> dict[str, str]:
    spec = importlib.util.spec_from_file_location("make_prompt_fixtures", BACKEND / "scripts/make_prompt_fixtures.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module.FIXTURES, module.CASES


def test_prompts_match_the_fixtures_the_app_checks():
    folder, cases = _fixture_cases()
    assert sorted(p.name for p in folder.iterdir()) == sorted(cases)
    for name, prompt in cases.items():
        assert (folder / name).read_text(encoding="utf-8") == prompt, name


def test_prompts_keep_the_rules():
    open_prompt = summaries.system_prompt(None)
    for rule in ("只写录音里真有的内容", "听不清的不要猜", "全部用简体中文", "先判断场景"):
        assert rule in open_prompt
    for scene in summaries.SCENES:
        assert f"- {scene.code}（{scene.name}）" in open_prompt
    assert "场景已经确定是 sales" in summaries.system_prompt("sales")
    assert summaries.system_prompt(None, "  ") == open_prompt
    long_job = summaries.system_prompt(None, "长" * 60)
    assert "「" + "长" * 40 + "」" in long_job and "长" * 41 not in long_job


# MARK: Reading replies (the app's SummaryParsingTests)


def test_reads_a_good_reply():
    draft = summaries.parse(GOOD, None)
    assert (draft.scene, draft.title, draft.summary) == ("meeting", "周会排期", "下周三上线。")
    assert draft.sections == [{"heading": "结论与决定", "items": ["下周三上线"]}]
    assert (draft.todos, draft.tags, draft.people) == (["老王周二前测完"], ["排期", "上线"], ["老王"])


def test_reads_json_wrapped_in_prose_and_thinking():
    reply = f'<think>这是会议吗？{{"scene":"call"}}</think>好的，整理如下：\n```json\n{GOOD}\n```\n希望有帮助。'
    draft = summaries.parse(reply, None)
    assert draft.scene == "meeting" and draft.summary == "下周三上线。"


def test_reads_outline_and_quotes_capped():
    points = [f"点{i}" for i in range(1, 10)]
    reply = json.dumps(
        {
            "summary": "s",
            "outline": [{"title": f"话题{i}", "points": points} for i in range(1, 11)] + [{"title": " "}],
            "quotes": [f"「原话{i}」" for i in range(1, 8)],
        },
        ensure_ascii=False,
    )
    draft = summaries.parse(reply, None)
    assert [o["title"] for o in draft.outline] == [f"话题{i}" for i in range(1, 9)]
    assert all(o["points"] == points[:6] for o in draft.outline)
    assert draft.quotes == [f"原话{i}" for i in range(1, 6)]
    assert summaries.parse('{"summary": "s"}', None).outline == []


def test_a_reply_without_a_summary_is_bad():
    for reply in ('{"scene": "meeting", "title": "t"}', '{"summary": "   "}', "没有 JSON", "} 反了 {", "[1, 2]"):
        with pytest.raises(summaries.BadReply):
            summaries.parse(reply, None)


def test_the_scene_is_read_tolerantly():
    assert summaries.parse('{"scene": "podcast", "summary": "s"}', None).scene == "other"
    assert summaries.parse('{"summary": "s"}', None).scene == "other"
    assert summaries.parse('{"scene": " Sales ", "summary": "s"}', None).scene == "sales"
    assert summaries.parse('{"scene": "课程", "summary": "s"}', None).scene == "lesson"
    assert summaries.parse('{"scene": "sales", "summary": "s"}', "call").scene == "call"


def test_caps_title_tags_and_people():
    reply = json.dumps(
        {
            "summary": "s",
            "title": "长" * 40,
            "tags": [f"#标签{i}" for i in range(1, 9)] + ["#"],
            "people": [f"人{i}" for i in range(1, 16)],
        },
        ensure_ascii=False,
    )
    draft = summaries.parse(reply, None)
    assert len(draft.title) == 30
    assert draft.tags == [f"标签{i}" for i in range(1, 7)]
    assert draft.people == [f"人{i}" for i in range(1, 13)]


def test_split_matches_the_app():
    text_ = "字" * 35 + "。" + "字" * 20
    pieces = summaries.split(text_, 40)
    assert [len(p) for p in pieces] == [36, 20] and pieces[0].endswith("。")
    assert [len(p) for p in summaries.split("字" * 100, 40)] == [40, 40, 20]
    assert summaries.split("一句话。", 6000) == ["一句话。"]
    assert summaries.split("", 6000) == []


def test_durations_read_like_speech():
    assert [summaries.prompt_duration(ms) for ms in (45_000, 125_000, 3_600_000, 3_900_000)] == [
        "45 秒",
        "2 分钟",
        "1 小时",
        "1 小时 5 分",
    ]


# MARK: The summarize task


@dataclass
class ScriptedModel:
    name: str = "scripted"
    replies: list = field(default_factory=lambda: [GOOD])
    calls: list[dict] = field(default_factory=list)

    async def complete(self, system: str, user: str, json_reply: bool) -> ChatReply:
        self.calls.append({"system": system, "user": user, "json": json_reply})
        reply = self.replies.pop(0) if len(self.replies) > 1 else self.replies[0]
        if isinstance(reply, Exception):
            raise reply
        return ChatReply(reply, "scripted-model-1", 100, 20)


@pytest.fixture
def model(h) -> ScriptedModel:
    h.run.chat = ScriptedModel()
    return h.run.chat


async def transcribed(h, tokens, lines: list[str] | None = None) -> dict:
    asr = ScriptedTranscriber()
    if lines is not None:
        asr.result = TranscriptResult("zh", [Segment(i * 1000, i * 1000 + 900, t) for i, t in enumerate(lines)], 1, "s")
    h.run.transcriber = asr
    recording = await uploaded(h, tokens)
    await h.http.post(f"/v1/recordings/{recording['id']}/transcribe", headers=bearer(tokens))
    assert await tasks.run_one(h.run, HANDLERS)
    return recording


async def test_summarize_end_to_end(h, model):
    tokens = await h.sms_login()
    recording = await transcribed(h, tokens)
    path = f"/v1/recordings/{recording['id']}/summaries"
    assert (await h.http.get(path, headers=bearer(tokens))).json() == []
    queued = await h.http.post(
        path, headers=bearer(tokens), json={"template_id": "meeting", "profession": " 产品经理 "}
    )
    assert queued.status_code == 202 and queued.json()["kind"] == "summarize"
    assert await tasks.run_one(h.run, HANDLERS)
    assert (await task_of(h, tokens, queued.json()["id"]))["status"] == "succeeded"

    # One request, with the app's prompt for the picked scene and job, and the app's user message.
    assert len(model.calls) == 1 and model.calls[0]["json"] is True
    assert model.calls[0]["system"] == summaries.system_prompt("meeting", "产品经理")
    assert model.calls[0]["user"] == "录音时长：1 分钟\n\n文字稿：\n大家好，开始开会。\n先说回款。\n好的。"

    listed = (await h.http.get(path, headers=bearer(tokens))).json()
    assert len(listed) == 1
    got = listed[0]
    assert (got["scene"], got["title"], got["summary"], got["model"]) == (
        "meeting",
        "周会排期",
        "下周三上线。",
        "scripted-model-1",
    )
    assert got["sections"] == [{"heading": "结论与决定", "items": ["下周三上线"]}] and got["tags"] == ["排期", "上线"]
    async with h.run.engine.connect() as connection:
        usage = (await connection.execute(text("SELECT kind, amount FROM usage_records ORDER BY kind"))).all()
    assert [tuple(u) for u in usage] == [("asr_seconds", 62), ("llm_tokens", 120)]

    # Regenerating keeps the earlier one; the newest comes first.
    model.replies = [GOOD.replace("周会排期", "第二版")]
    h.clock.advance(seconds=1)
    await h.http.post(path, headers=bearer(tokens))
    await tasks.run_one(h.run, HANDLERS)
    assert [s["title"] for s in (await h.http.get(path, headers=bearer(tokens))).json()] == ["第二版", "周会排期"]
    # No template: the model chooses.
    assert model.calls[1]["system"] == summaries.system_prompt(None)


async def test_a_long_transcript_is_compressed_chunk_by_chunk_first(h, model):
    tokens = await h.sms_login()
    lines = ["这一句有十个字左右。" * 50] * 20  # about 10 000 characters
    recording = await transcribed(h, tokens, lines)
    material = summaries.material([{"text": t} for t in lines])
    chunks = summaries.split(material, summaries.CHUNK_SIZE)
    assert len(chunks) == 2
    model.replies = ["第一段笔记", "第二段笔记", GOOD]
    await h.http.post(f"/v1/recordings/{recording['id']}/summaries", headers=bearer(tokens))
    await tasks.run_one(h.run, HANDLERS)
    assert [(c["system"], c["user"], c["json"]) for c in model.calls[:2]] == [
        (summaries.chunk_prompt(1), chunks[0], False),
        (summaries.chunk_prompt(2), chunks[1], False),
    ]
    assert model.calls[2]["user"].endswith("文字稿：\n" + summaries.chunk_notes(["第一段笔记", "第二段笔记"]))
    async with h.run.engine.connect() as connection:
        assert (
            await connection.execute(text("SELECT amount FROM usage_records WHERE kind = 'llm_tokens'"))
        ).scalar() == 360


async def test_summarize_needs_a_transcript_and_is_not_queued_twice(h, model):
    tokens = await h.sms_login()
    bare = await uploaded(h, tokens, b"no transcript yet")
    early = await h.http.post(f"/v1/recordings/{bare['id']}/summaries", headers=bearer(tokens))
    assert early.status_code == 409 and early.json()["error"]["code"] == "no_transcript"
    recording = await transcribed(h, tokens)
    path = f"/v1/recordings/{recording['id']}/summaries"
    unknown = await h.http.post(path, headers=bearer(tokens), json={"template_id": "podcast"})
    assert unknown.status_code == 422 and unknown.json()["error"]["code"] == "unknown_template"
    first = await h.http.post(path, headers=bearer(tokens))
    again = await h.http.post(path, headers=bearer(tokens), json={"template_id": "call"})
    assert again.status_code == 200 and again.json()["id"] == first.json()["id"]
    other = await h.sms_login("13900000000")
    assert (await h.http.post(path, headers=bearer(other))).status_code == 404
    assert (await h.http.get(path, headers=bearer(other))).status_code == 404


async def test_an_unreadable_reply_is_retried_and_a_dead_model_fails(h, model):
    tokens = await h.sms_login()
    recording = await transcribed(h, tokens)
    model.replies = ["抱歉，我不能输出 JSON。", GOOD]
    task_id = (await h.http.post(f"/v1/recordings/{recording['id']}/summaries", headers=bearer(tokens))).json()["id"]
    await tasks.run_one(h.run, HANDLERS)
    state = await task_of(h, tokens, task_id)
    assert state["status"] == "queued" and state["error"]["code"] == "bad_reply"
    h.clock.advance(seconds=30)
    await tasks.run_one(h.run, HANDLERS)
    tokens = await h.sms_login()
    assert (await task_of(h, tokens, task_id))["status"] == "succeeded"
    # The unreadable attempt cost tokens too: kept, but not counted against the allowance.
    async with h.run.engine.connect() as connection:
        rows = (
            await connection.execute(
                text("SELECT kind, sum(amount) FROM usage_records WHERE kind LIKE 'llm%' GROUP BY kind ORDER BY kind")
            )
        ).all()
    assert [tuple(r) for r in rows] == [("llm_tokens", 120), ("llm_unbilled", 120)]
    assert (await h.http.get("/v1/me/usage", headers=bearer(tokens))).json()["llm_tokens"]["used"] == 120

    model.replies = [ChatModelError("llm_refused", "内容不合规，模型拒绝回答", retryable=False)]
    task_id = (await h.http.post(f"/v1/recordings/{recording['id']}/summaries", headers=bearer(tokens))).json()["id"]
    await tasks.run_one(h.run, HANDLERS)
    state = await task_of(h, tokens, task_id)
    assert state["status"] == "failed" and state["error"]["code"] == "llm_refused"


async def test_templates_are_the_scenes(h):
    tokens = await h.sms_login()
    listed = (await h.http.get("/v1/templates", headers=bearer(tokens))).json()
    assert [t["id"] for t in listed] == [s.code for s in summaries.SCENES]
    assert listed[0] == {
        "id": "meeting",
        "name": "会议",
        "definition": "多人围绕议题讨论并形成决定的内部会议、例会、评审",
        "headings": ["结论与决定", "讨论要点", "分歧与风险"],
        "is_builtin": True,
    }
    assert (await h.http.get("/v1/templates")).status_code == 401


async def test_the_stand_in_model_runs_the_whole_pipeline(h):
    tokens = await h.sms_login()
    recording = await uploaded(h, tokens)
    await h.http.post(f"/v1/recordings/{recording['id']}/transcribe", headers=bearer(tokens))
    await tasks.run_one(h.run, HANDLERS)
    await h.http.post(f"/v1/recordings/{recording['id']}/summaries", headers=bearer(tokens))
    await tasks.run_one(h.run, HANDLERS)
    listed = (await h.http.get(f"/v1/recordings/{recording['id']}/summaries", headers=bearer(tokens))).json()
    assert listed[0]["model"] == "stand-in" and "替身" in listed[0]["summary"]


async def test_deleting_the_account_deletes_summaries_and_keeps_usage(h, model):
    tokens = await h.sms_login()
    recording = await transcribed(h, tokens)
    await h.http.post(f"/v1/recordings/{recording['id']}/summaries", headers=bearer(tokens))
    await tasks.run_one(h.run, HANDLERS)
    assert await h.count("summaries") == 1
    await h.http.delete("/v1/me", headers=bearer(tokens))
    assert await h.count("summaries") == 0 and await h.count("usage_records") == 2


async def test_a_summary_from_the_apps_own_transcript(h, model):
    """No audio on the server: the app's transcript is enough to summarize (product-spec.md §7.3b)."""
    tokens = await h.sms_login()
    bare = (await h.http.post("/v1/recordings", headers=bearer(tokens), json=meta(None))).json()
    lines = [
        {"start_ms": 0, "end_ms": 1500, "text": "大家好，开始开会。"},
        {"start_ms": 1500, "end_ms": 4000, "text": "先说回款。"},
    ]
    path = f"/v1/recordings/{bare['id']}/transcript"
    put = await h.http.put(path, headers=bearer(tokens), json={"engine": "on-device", "segments": lines})
    assert put.status_code == 200
    queued = await h.http.post(f"/v1/recordings/{bare['id']}/summaries", headers=bearer(tokens), json={})
    assert queued.status_code == 202, queued.text
    assert await tasks.run_one(h.run, HANDLERS)
    assert "大家好，开始开会。\n先说回款。" in model.calls[0]["user"]


async def test_unbilled_tokens_are_kept_after_the_account_is_gone(h):
    # The account was deleted while the model ran: the cost stays, without a user.
    tokens = await h.sms_login()
    me = (await h.http.get("/v1/me", headers=bearer(tokens))).json()
    await usage.record_unbilled(h.run, uuid.UUID(me["id"]), 30)
    await usage.record_unbilled(h.run, uuid.uuid4(), 50)
    async with h.run.engine.connect() as connection:
        rows = (
            await connection.execute(
                text("SELECT user_id::text, amount FROM usage_records WHERE kind = 'llm_unbilled' ORDER BY amount")
            )
        ).all()
    assert [tuple(r) for r in rows] == [(me["id"], 30), (None, 50)]
