"""Server-side transcription (F1) and the task queue under it (prd.md §7.4, ADR-013)."""

import asyncio
from dataclasses import dataclass, field

import pytest
from conftest import bearer
from sqlalchemy import text
from test_recordings import AUDIO, meta, uploaded

from revive_api import tasks
from revive_api.asr import Segment, TranscriberError, TranscriptResult
from revive_api.worker import HANDLERS, work


@dataclass
class ScriptedTranscriber:
    """Returns `result`, or raises the next entry of `failures` first."""

    name: str = "scripted"
    failures: list[Exception] = field(default_factory=list)
    calls: list[dict] = field(default_factory=list)
    # Run while "recognising", to change things under a running task.
    during: object = None
    result: TranscriptResult = field(
        default_factory=lambda: TranscriptResult(
            language="zh",
            segments=[
                Segment(0, 1500, "大家好，开始开会。", "S1"),
                Segment(1500, 4000, "先说回款。", "S2"),
                Segment(4000, 61_000, "好的。", "S1"),
            ],
            audio_ms=61_001,
            provider="scripted-asr",
        )
    )

    async def transcribe(self, audio_url, content_type, language, speakers, duration_ms):
        self.calls.append({"url": audio_url, "language": language, "speakers": speakers, "duration_ms": duration_ms})
        if self.during is not None:
            await self.during()
        if self.failures:
            raise self.failures.pop(0)
        return self.result


@pytest.fixture
def asr(h) -> ScriptedTranscriber:
    h.run.transcriber = ScriptedTranscriber()
    return h.run.transcriber


async def task_of(h, tokens, task_id) -> dict:
    reply = await h.http.get(f"/v1/tasks/{task_id}", headers=bearer(tokens))
    assert reply.status_code == 200, reply.text
    return reply.json()


async def test_transcribe_end_to_end(h, asr):
    tokens = await h.sms_login()
    recording = await uploaded(h, tokens)
    queued = await h.http.post(
        f"/v1/recordings/{recording['id']}/transcribe", headers=bearer(tokens), json={"language": "zh-CN"}
    )
    assert queued.status_code == 202
    task = queued.json()
    assert (task["kind"], task["status"], task["attempts"], task["error"]) == ("transcribe", "queued", 0, None)
    missing = await h.http.get(f"/v1/recordings/{recording['id']}/transcript", headers=bearer(tokens))
    assert missing.status_code == 404 and missing.json()["error"]["code"] == "transcript_not_found"

    assert await tasks.run_one(h.run, HANDLERS) is True
    assert await tasks.run_one(h.run, HANDLERS) is False
    done = await task_of(h, tokens, task["id"])
    assert (done["status"], done["attempts"], done["finished_at"] is not None) == ("succeeded", 1, True)
    # The engine got a URL to the stored audio, and what was asked for.
    assert asr.calls[0]["language"] == "zh-CN" and asr.calls[0]["speakers"] is True
    assert (await h.http.get(asr.calls[0]["url"])).content == AUDIO

    transcript = (await h.http.get(f"/v1/recordings/{recording['id']}/transcript", headers=bearer(tokens))).json()
    assert transcript["asr_provider"] == "scripted-asr" and transcript["speakers"] == {}
    assert transcript["segments"][1] == {"start_ms": 1500, "end_ms": 4000, "speaker": "S2", "text": "先说回款。"}
    async with h.run.engine.connect() as connection:
        usage = (await connection.execute(text("SELECT kind, amount FROM usage_records"))).all()
    assert [tuple(u) for u in usage] == [("asr_seconds", 62)]


async def test_transcribe_needs_stored_audio_and_is_not_queued_twice(h, asr):
    tokens = await h.sms_login()
    pending = await h.http.post("/v1/recordings", headers=bearer(tokens), json={
        "source": "card", "started_at": "2026-11-20T09:30:00+08:00", "duration_ms": 1000,
        "audio": {"sha256": "a" * 64, "size": 10},
    })  # fmt: skip
    early = await h.http.post(f"/v1/recordings/{pending.json()['id']}/transcribe", headers=bearer(tokens))
    assert early.status_code == 409 and early.json()["error"]["code"] == "audio_not_uploaded"

    recording = await uploaded(h, tokens)
    first = await h.http.post(f"/v1/recordings/{recording['id']}/transcribe", headers=bearer(tokens))
    again = await h.http.post(f"/v1/recordings/{recording['id']}/transcribe", headers=bearer(tokens))
    assert again.status_code == 200 and again.json()["id"] == first.json()["id"]
    await tasks.run_one(h.run, HANDLERS)
    redo = await h.http.post(f"/v1/recordings/{recording['id']}/transcribe", headers=bearer(tokens))
    assert redo.status_code == 202 and redo.json()["id"] != first.json()["id"]

    other = await h.sms_login("13900000000")
    for reply in (
        await h.http.post(f"/v1/recordings/{recording['id']}/transcribe", headers=bearer(other)),
        await h.http.get(f"/v1/tasks/{first.json()['id']}", headers=bearer(other)),
        await h.http.get(f"/v1/recordings/{recording['id']}/transcript", headers=bearer(other)),
    ):
        assert reply.status_code == 404
    bad = await h.http.post(
        f"/v1/recordings/{recording['id']}/transcribe", headers=bearer(tokens), json={"language": "中文"}
    )
    assert bad.status_code == 422


async def test_retryable_failures_back_off_then_give_up(h, asr):
    asr.failures = [TranscriberError("asr_busy", "识别服务繁忙", retryable=True) for _ in range(4)]
    tokens = await h.sms_login()
    recording = await uploaded(h, tokens)
    task_id = (await h.http.post(f"/v1/recordings/{recording['id']}/transcribe", headers=bearer(tokens))).json()["id"]
    for attempt, wait in ((1, 30), (2, 60), (3, 120)):
        assert await tasks.run_one(h.run, HANDLERS)
        state = await task_of(h, tokens, task_id)
        assert (state["status"], state["attempts"], state["error"]["code"]) == ("queued", attempt, "asr_busy")
        h.clock.advance(seconds=wait - 1)
        assert await tasks.run_one(h.run, HANDLERS) is False  # not due yet
        h.clock.advance(seconds=1)
        tokens = await h.sms_login()
    assert await tasks.run_one(h.run, HANDLERS)
    state = await task_of(h, tokens, task_id)
    assert (state["status"], state["attempts"], state["error"]["code"]) == ("failed", 4, "asr_busy")
    assert len(asr.calls) == 4 and await h.count("transcripts") == 0


async def test_a_retry_that_succeeds_clears_the_error(h, asr):
    asr.failures = [RuntimeError("boom")]
    tokens = await h.sms_login()
    recording = await uploaded(h, tokens)
    task_id = (await h.http.post(f"/v1/recordings/{recording['id']}/transcribe", headers=bearer(tokens))).json()["id"]
    await tasks.run_one(h.run, HANDLERS)
    state = await task_of(h, tokens, task_id)
    assert state["status"] == "queued" and state["error"]["code"] == "internal"
    h.clock.advance(seconds=30)
    await tasks.run_one(h.run, HANDLERS)
    tokens = await h.sms_login()
    state = await task_of(h, tokens, task_id)
    assert (state["status"], state["attempts"], state["error"]) == ("succeeded", 2, None)


async def test_a_permanent_failure_is_not_retried(h, asr):
    asr.failures = [TranscriberError("audio_unreadable", "音频无法识别", retryable=False)]
    tokens = await h.sms_login()
    recording = await uploaded(h, tokens)
    task_id = (await h.http.post(f"/v1/recordings/{recording['id']}/transcribe", headers=bearer(tokens))).json()["id"]
    await tasks.run_one(h.run, HANDLERS)
    state = await task_of(h, tokens, task_id)
    assert state["status"] == "failed" and state["error"] == {"code": "audio_unreadable", "message": "音频无法识别"}


async def test_a_worker_that_vanishes_loses_its_lease(h, asr):
    tokens = await h.sms_login()
    recording = await uploaded(h, tokens)
    task_id = (await h.http.post(f"/v1/recordings/{recording['id']}/transcribe", headers=bearer(tokens))).json()["id"]
    gone = await tasks.claim(h.run)  # this worker never comes back
    assert gone is not None and gone.attempt == 1
    assert await tasks.claim(h.run) is None  # leased
    h.clock.advance(minutes=15, seconds=1)
    assert await tasks.run_one(h.run, HANDLERS)  # another worker takes over
    tokens = await h.sms_login()
    state = await task_of(h, tokens, task_id)
    assert (state["status"], state["attempts"]) == ("succeeded", 2)
    # The first worker turning up late writes nothing.
    with pytest.raises(tasks.LostLease):
        async with tasks.finishing(h.run, gone):
            pytest.fail("must not get here")


async def test_a_task_whose_workers_keep_vanishing_fails(h, asr):
    tokens = await h.sms_login()
    recording = await uploaded(h, tokens)
    task_id = (await h.http.post(f"/v1/recordings/{recording['id']}/transcribe", headers=bearer(tokens))).json()["id"]
    for _ in range(4):
        assert await tasks.claim(h.run) is not None
        h.clock.advance(minutes=16)
    assert await tasks.claim(h.run) is None
    tokens = await h.sms_login()
    state = await task_of(h, tokens, task_id)
    assert (state["status"], state["error"]["code"]) == ("failed", "worker_lost")


async def test_deleting_the_recording_cancels_its_tasks(h, asr):
    tokens = await h.sms_login()
    running = await uploaded(h, tokens)
    queued = await uploaded(h, tokens, b"other audio")
    running_task = (await h.http.post(f"/v1/recordings/{running['id']}/transcribe", headers=bearer(tokens))).json()
    queued_task = (await h.http.post(f"/v1/recordings/{queued['id']}/transcribe", headers=bearer(tokens))).json()

    # Both recordings are deleted while the engine is working on the first.
    async def delete_both() -> None:
        for r in (running, queued):
            assert (await h.http.delete(f"/v1/recordings/{r['id']}", headers=bearer(tokens))).status_code == 204

    asr.during = delete_both
    assert await tasks.run_one(h.run, HANDLERS)
    for t in (running_task, queued_task):
        state = await task_of(h, tokens, t["id"])
        assert (state["status"], state["error"]["code"]) == ("failed", "recording_deleted")
    assert await tasks.run_one(h.run, HANDLERS) is False
    assert len(asr.calls) == 1
    assert await h.count("transcripts") == 0 and await h.count("usage_records") == 0


async def test_naming_speakers(h, asr):
    tokens = await h.sms_login()
    recording = await uploaded(h, tokens)
    await h.http.post(f"/v1/recordings/{recording['id']}/transcribe", headers=bearer(tokens))
    await tasks.run_one(h.run, HANDLERS)
    path = f"/v1/recordings/{recording['id']}/speakers"
    named = await h.http.patch(path, headers=bearer(tokens), json={"speakers": {"S1": " 张三 ", "S2": "李四"}})
    assert named.status_code == 200 and named.json()["speakers"] == {"S1": "张三", "S2": "李四"}
    cleared = await h.http.patch(path, headers=bearer(tokens), json={"speakers": {"S2": ""}})
    assert cleared.json()["speakers"] == {"S1": "张三"}
    unknown = await h.http.patch(path, headers=bearer(tokens), json={"speakers": {"S9": "王五"}})
    assert unknown.status_code == 422 and unknown.json()["error"]["code"] == "unknown_speaker"
    long = await h.http.patch(path, headers=bearer(tokens), json={"speakers": {"S1": "名" * 33}})
    assert long.status_code == 422 and long.json()["error"]["code"] == "speaker_name_too_long"
    # A new transcript has new labels: names start over.
    await h.http.post(f"/v1/recordings/{recording['id']}/transcribe", headers=bearer(tokens))
    await tasks.run_one(h.run, HANDLERS)
    again = await h.http.get(f"/v1/recordings/{recording['id']}/transcript", headers=bearer(tokens))
    assert again.json()["speakers"] == {}


async def test_deleting_the_account_keeps_usage_without_the_user(h, asr):
    tokens = await h.sms_login()
    recording = await uploaded(h, tokens)
    await h.http.post(f"/v1/recordings/{recording['id']}/transcribe", headers=bearer(tokens))
    await tasks.run_one(h.run, HANDLERS)
    assert (await h.http.delete("/v1/me", headers=bearer(tokens))).status_code == 204
    assert await h.count("tasks") == await h.count("transcripts") == 0
    async with h.run.engine.connect() as connection:
        usage = (await connection.execute(text("SELECT user_id, amount FROM usage_records"))).all()
    assert [tuple(u) for u in usage] == [(None, 62)]


async def test_the_worker_runs_queued_tasks_until_stopped(h, asr):
    tokens = await h.sms_login()
    recording = await uploaded(h, tokens)
    task_id = (await h.http.post(f"/v1/recordings/{recording['id']}/transcribe", headers=bearer(tokens))).json()["id"]
    stop = asyncio.Event()
    worker = asyncio.create_task(work(h.run, stop, idle_seconds=0.01))
    for _ in range(500):
        if (await task_of(h, tokens, task_id))["status"] == "succeeded":
            break
        await asyncio.sleep(0.01)
    stop.set()
    await asyncio.wait_for(worker, timeout=5)
    assert (await task_of(h, tokens, task_id))["status"] == "succeeded"


async def test_the_stand_in_engine_says_it_heard_nothing(h):
    tokens = await h.sms_login()
    recording = await uploaded(h, tokens)
    await h.http.post(f"/v1/recordings/{recording['id']}/transcribe", headers=bearer(tokens))
    await tasks.run_one(h.run, HANDLERS)
    transcript = (await h.http.get(f"/v1/recordings/{recording['id']}/transcript", headers=bearer(tokens))).json()
    assert transcript["asr_provider"] == "stand-in" and "替身" in transcript["segments"][0]["text"]
    assert transcript["segments"][0]["end_ms"] == 61_000


async def test_the_app_can_put_its_own_transcript(h, asr):
    """product-spec.md §7.3b: a transcript made on the phone goes up as text, no audio needed."""
    tokens = await h.sms_login()
    bare = await h.http.post("/v1/recordings", headers=bearer(tokens), json=meta(None))
    assert bare.status_code == 201 and bare.json()["audio"] is None
    path = f"/v1/recordings/{bare.json()['id']}/transcript"
    lines = [
        {"start_ms": 1500, "end_ms": 3000, "text": "先说回款。"},
        {"start_ms": 0, "end_ms": 1500, "speaker": None, "text": "大家好。"},
    ]
    put = await h.http.put(path, headers=bearer(tokens), json={"engine": "on-device", "segments": lines})
    assert put.status_code == 200, put.text
    got = (await h.http.get(path, headers=bearer(tokens))).json()
    assert got["asr_provider"] == "app:on-device" and got["language"] == "zh" and got["speakers"] == {}
    assert [s["text"] for s in got["segments"]] == ["大家好。", "先说回款。"]  # in time order
    assert await h.count("usage_records") == 0  # nothing was transcribed here

    # Putting again replaces it.
    again = await h.http.put(
        path,
        headers=bearer(tokens),
        json={"engine": "own-service", "language": "en", "segments": [{"start_ms": 0, "end_ms": 900, "text": "Hi"}]},
    )
    assert again.json()["asr_provider"] == "app:own-service" and len(again.json()["segments"]) == 1

    bad = {"engine": "on-device", "segments": [{"start_ms": 900, "end_ms": 100, "text": "x"}]}
    backwards = await h.http.put(path, headers=bearer(tokens), json=bad)
    assert backwards.status_code == 422 and backwards.json()["error"]["code"] == "invalid_segment"
    empty = await h.http.put(path, headers=bearer(tokens), json={"engine": "on-device", "segments": []})
    assert empty.status_code == 422
    odd = await h.http.put(path, headers=bearer(tokens), json={"engine": "On Device!", "segments": lines})
    assert odd.status_code == 422

    other = await h.sms_login("13900000000")
    theirs = await h.http.put(path, headers=bearer(other), json={"engine": "on-device", "segments": lines})
    assert theirs.status_code == 404 and theirs.json()["error"]["code"] == "recording_not_found"


async def test_the_app_transcript_waits_for_a_server_transcription(h, asr):
    tokens = await h.sms_login()
    recording = await uploaded(h, tokens)
    await h.http.post(f"/v1/recordings/{recording['id']}/transcribe", headers=bearer(tokens))
    path = f"/v1/recordings/{recording['id']}/transcript"
    body = {"engine": "on-device", "segments": [{"start_ms": 0, "end_ms": 900, "text": "你好"}]}
    busy = await h.http.put(path, headers=bearer(tokens), json=body)
    assert busy.status_code == 409 and busy.json()["error"]["code"] == "transcription_running"
    await tasks.run_one(h.run, HANDLERS)
    assert (await h.http.put(path, headers=bearer(tokens), json=body)).status_code == 200
