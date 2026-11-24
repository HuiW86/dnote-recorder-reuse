"""Usage and monthly allowances (X2): GET /me/usage, quota_exceeded, the pending-task cap."""

from datetime import UTC, datetime

import pytest
from conftest import bearer
from test_recordings import uploaded
from test_summaries import ScriptedModel
from test_transcripts import ScriptedTranscriber, task_of

from revive_api import tasks, usage
from revive_api.asr import TranscriberError
from revive_api.worker import HANDLERS


def limits(h, **values) -> None:
    h.run.settings = h.run.settings.model_copy(update=values)


@pytest.fixture
def engines(h):
    h.run.transcriber = ScriptedTranscriber()
    h.run.chat = ScriptedModel()
    return h.run.transcriber, h.run.chat


async def transcribe(h, tokens, recording) -> dict:
    return await h.http.post(f"/v1/recordings/{recording['id']}/transcribe", headers=bearer(tokens))


def test_months_start_at_midnight_beijing_time():
    # 2026-11-30 16:30 UTC is 1 December 00:30 in Beijing.
    period = usage.current_period(datetime(2026, 11, 30, 16, 30, tzinfo=UTC), 8)
    assert (period.start, period.end) == (
        datetime(2026, 11, 30, 16, 0, tzinfo=UTC),
        datetime(2026, 12, 31, 16, 0, tzinfo=UTC),
    )
    november = usage.current_period(datetime(2026, 11, 30, 15, 59, tzinfo=UTC), 8)
    assert november.start == datetime(2026, 10, 31, 16, 0, tzinfo=UTC) and november.end == period.start
    assert [usage.seconds_of(ms) for ms in (0, 1, 1000, 1001, -5)] == [0, 1, 1, 2, 0]


async def test_usage_shows_this_month(h, engines):
    tokens = await h.sms_login()
    empty = (await h.http.get("/v1/me/usage", headers=bearer(tokens))).json()
    assert empty["period_start"] == "2026-10-31T16:00:00Z" and empty["period_end"] == "2026-11-30T16:00:00Z"
    assert empty["asr_seconds"] == {"used": 0, "reserved": 0, "limit": None, "remaining": None}
    assert empty["llm_tokens"] == {"used": 0, "reserved": 0, "limit": None, "remaining": None}

    limits(h, asr_monthly_seconds=600, llm_monthly_tokens=1000)
    recording = await uploaded(h, tokens)  # 61 s
    await transcribe(h, tokens, recording)
    waiting = (await h.http.get("/v1/me/usage", headers=bearer(tokens))).json()
    assert waiting["asr_seconds"] == {"used": 0, "reserved": 61, "limit": 600, "remaining": 539}
    await tasks.run_one(h.run, HANDLERS)
    await h.http.post(f"/v1/recordings/{recording['id']}/summaries", headers=bearer(tokens))
    await tasks.run_one(h.run, HANDLERS)
    done = (await h.http.get("/v1/me/usage", headers=bearer(tokens))).json()
    # The scripted engine heard 61.001 s: 62 started seconds.
    assert done["asr_seconds"] == {"used": 62, "reserved": 0, "limit": 600, "remaining": 538}
    assert done["llm_tokens"] == {"used": 120, "reserved": 0, "limit": 1000, "remaining": 880}
    # Next month starts from zero.
    h.clock.current = datetime(2026, 11, 30, 16, 0, tzinfo=UTC)
    tokens = await h.sms_login()
    december = (await h.http.get("/v1/me/usage", headers=bearer(tokens))).json()
    assert december["period_start"] == "2026-11-30T16:00:00Z"
    assert december["asr_seconds"]["used"] == december["llm_tokens"]["used"] == 0
    assert (await h.http.get("/v1/me/usage")).status_code == 401


async def test_transcription_stops_when_the_month_would_run_out(h, engines):
    limits(h, asr_monthly_seconds=150)
    tokens = await h.sms_login()
    first, second, third = [await uploaded(h, tokens, bytes([n]) * 100) for n in range(3)]  # 61 s each
    assert (await transcribe(h, tokens, first)).status_code == 202
    assert (await transcribe(h, tokens, second)).status_code == 202  # 122 of 150 reserved
    refused = await transcribe(h, tokens, third)
    assert refused.status_code == 429
    assert refused.json()["error"] == {
        "code": "quota_exceeded",
        "message": "本月转写时长不够了（每月 2 分钟），下个月 1 日恢复",
        "retryable": False,
    }
    # Asking again for one already queued is not a new charge.
    assert (await transcribe(h, tokens, first)).status_code == 200
    # Another account has its own allowance.
    other = await h.sms_login("13900000000")
    assert (await transcribe(h, other, await uploaded(h, other))).status_code == 202
    # Finished in November: 124 s used, still not enough room for 61 more.
    while await tasks.run_one(h.run, HANDLERS):
        pass
    assert (await transcribe(h, tokens, third)).status_code == 429
    # Next month (Beijing time) it works again.
    h.clock.current = datetime(2026, 11, 30, 16, 0, tzinfo=UTC)
    tokens = await h.sms_login()
    assert (await transcribe(h, tokens, third)).status_code == 202


async def test_a_failed_transcription_gives_its_time_back(h, engines):
    asr, _ = engines
    asr.failures = [TranscriberError("audio_unreadable", "音频无法识别", retryable=False)]
    limits(h, asr_monthly_seconds=100)
    tokens = await h.sms_login()
    first, second = [await uploaded(h, tokens, bytes([n]) * 100) for n in range(2)]
    task = (await transcribe(h, tokens, first)).json()
    assert (await transcribe(h, tokens, second)).status_code == 429
    await tasks.run_one(h.run, HANDLERS)
    assert (await task_of(h, tokens, task["id"]))["status"] == "failed"
    assert (await transcribe(h, tokens, second)).status_code == 202


async def test_summaries_stop_once_the_tokens_are_used(h, engines):
    limits(h, llm_monthly_tokens=100)
    tokens = await h.sms_login()
    recording = await uploaded(h, tokens)
    await transcribe(h, tokens, recording)
    await tasks.run_one(h.run, HANDLERS)
    path = f"/v1/recordings/{recording['id']}/summaries"
    assert (await h.http.post(path, headers=bearer(tokens))).status_code == 202  # nothing used yet
    await tasks.run_one(h.run, HANDLERS)  # uses 120: the last one may go over
    refused = await h.http.post(path, headers=bearer(tokens))
    assert (
        refused.status_code == 429 and refused.json()["error"]["message"] == "本月 AI 整理的额度用完了，下个月 1 日恢复"
    )


async def test_only_so_many_tasks_wait_at_once(h, engines):
    limits(h, max_pending_tasks=2)
    tokens = await h.sms_login()
    recordings = [await uploaded(h, tokens, bytes([n]) * 100) for n in range(3)]
    assert [(await transcribe(h, tokens, r)).status_code for r in recordings[:2]] == [202, 202]
    busy = await transcribe(h, tokens, recordings[2])
    assert busy.status_code == 429 and busy.json()["error"]["code"] == "too_many_tasks"
    assert busy.json()["error"]["retryable"] is True
    await tasks.run_one(h.run, HANDLERS)
    assert (await transcribe(h, tokens, recordings[2])).status_code == 202


async def test_two_requests_at_once_cannot_both_slip_under_the_limit(h, engines, monkeypatch):
    import asyncio

    check = usage.check_transcribe

    async def slow_check(*args):
        # Widen the gap between checking and enqueueing, so without the lock both would pass.
        await check(*args)
        await asyncio.sleep(0.1)

    monkeypatch.setattr(usage, "check_transcribe", slow_check)
    limits(h, asr_monthly_seconds=100)
    tokens = await h.sms_login()
    first, second = [await uploaded(h, tokens, bytes([n]) * 100) for n in range(2)]  # 61 s each
    replies = await asyncio.gather(transcribe(h, tokens, first), transcribe(h, tokens, second))
    assert sorted(r.status_code for r in replies) == [202, 429]
    assert await h.count("tasks") == 1
