"""Recordings and their audio (prd.md §7.2 录音与上传): presigned multipart upload, resuming,
de-duplication by SHA-256, download URLs, deletion, and the queue that removes stored audio."""

import base64
import hashlib
import os

from conftest import bearer
from sqlalchemy import text

from revive_api.maintenance import drain_deletions, sweep_stale_uploads
from revive_api.storage import LocalStore

AUDIO = os.urandom(2500)  # three parts of 1024, 1024 and 452 bytes in the test settings
SHA = hashlib.sha256(AUDIO).hexdigest()
SN_HASH = hashlib.sha256(b"DN12345678").hexdigest()
BOND = base64.b64encode(bytes(range(16))).decode()


def meta(audio: bytes | None = AUDIO, **fields) -> dict:
    body = {"source": "card", "started_at": "2026-11-20T09:30:00+08:00", "duration_ms": 61_000, "title": "周会"}
    if audio is not None:
        body["audio"] = {"sha256": hashlib.sha256(audio).hexdigest(), "size": len(audio), "content_type": "audio/ogg"}
    return body | fields


async def put_parts(h, recording: dict, audio: bytes = AUDIO, only: set[int] | None = None) -> dict[int, str]:
    etags = {}
    for part in recording["upload"]["parts"]:
        if only is not None and part["part_number"] not in only:
            continue
        chunk = audio[part["offset"] : part["offset"] + part["size"]]
        reply = await h.http.put(part["url"], content=chunk)
        assert reply.status_code == 200, reply.text
        etags[part["part_number"]] = reply.headers["etag"]
    return etags


async def uploaded(h, tokens: dict, audio: bytes = AUDIO, **fields) -> dict:
    created = await h.http.post("/v1/recordings", headers=bearer(tokens), json=meta(audio, **fields))
    assert created.status_code == 201, created.text
    await put_parts(h, created.json(), audio)
    done = await h.http.post(f"/v1/recordings/{created.json()['id']}/upload-complete", headers=bearer(tokens))
    assert done.status_code == 200, done.text
    return done.json()


async def test_upload_in_parts_then_download(h):
    tokens = await h.sms_login()
    created = await h.http.post("/v1/recordings", headers=bearer(tokens), json=meta())
    assert created.status_code == 201
    body = created.json()
    assert body["audio"] == {"sha256": SHA, "size": 2500, "content_type": "audio/ogg", "uploaded": False}
    parts = body["upload"]["parts"]
    assert [(p["part_number"], p["offset"], p["size"], p["done"]) for p in parts] == [
        (1, 0, 1024, False),
        (2, 1024, 1024, False),
        (3, 2048, 452, False),
    ]
    etags = await put_parts(h, body)
    done = await h.http.post(
        f"/v1/recordings/{body['id']}/upload-complete",
        headers=bearer(tokens),
        json={"parts": [{"part_number": n, "etag": e} for n, e in etags.items()]},
    )
    assert done.status_code == 200, done.text
    assert done.json()["audio"]["uploaded"] is True and done.json()["upload"] is None
    assert done.json()["version"] == 2
    # Completing again is not an error.
    again = await h.http.post(f"/v1/recordings/{body['id']}/upload-complete", headers=bearer(tokens))
    assert again.status_code == 200 and again.json()["version"] == 2

    link = await h.http.get(f"/v1/recordings/{body['id']}/audio-url", headers=bearer(tokens))
    assert link.status_code == 200
    audio = await h.http.get(link.json()["url"])
    assert audio.status_code == 200 and audio.content == AUDIO
    assert "filename*=UTF-8''%E5%91%A8%E4%BC%9A.ogg" in audio.headers["content-disposition"]
    # Only the joined object is left in the store.
    assert len(h.files) == 1


async def test_an_interrupted_upload_resumes_from_the_stored_parts(h):
    tokens = await h.sms_login()
    created = (await h.http.post("/v1/recordings", headers=bearer(tokens), json=meta())).json()
    await put_parts(h, created, only={1, 3})
    early = await h.http.post(f"/v1/recordings/{created['id']}/upload-complete", headers=bearer(tokens))
    assert early.status_code == 409 and early.json()["error"]["code"] == "upload_incomplete"
    resumed = await h.http.post(f"/v1/recordings/{created['id']}/upload", headers=bearer(tokens))
    assert resumed.status_code == 200
    assert [p["done"] for p in resumed.json()["upload"]["parts"]] == [True, False, True]
    assert resumed.json()["upload"]["parts"][0]["etag"].startswith('"')
    await put_parts(h, resumed.json(), only={2})
    done = await h.http.post(f"/v1/recordings/{created['id']}/upload-complete", headers=bearer(tokens))
    assert done.status_code == 200 and done.json()["audio"]["uploaded"] is True


async def test_a_wrong_part_is_not_joined(h):
    tokens = await h.sms_login()
    created = (await h.http.post("/v1/recordings", headers=bearer(tokens), json=meta())).json()
    etags = await put_parts(h, created)
    wrong = await h.http.post(
        f"/v1/recordings/{created['id']}/upload-complete",
        headers=bearer(tokens),
        json={"parts": [{"part_number": n, "etag": '"x"' if n == 2 else e} for n, e in etags.items()]},
    )
    assert wrong.status_code == 409 and wrong.json()["error"]["code"] == "upload_mismatch"
    # A short part: the size check catches it before anything is joined.
    part = created["upload"]["parts"][1]
    await h.http.put(part["url"], content=b"short")
    short = await h.http.post(f"/v1/recordings/{created['id']}/upload-complete", headers=bearer(tokens))
    assert short.status_code == 409 and short.json()["error"]["code"] == "upload_incomplete"
    resumed = (await h.http.post(f"/v1/recordings/{created['id']}/upload", headers=bearer(tokens))).json()
    assert [p["done"] for p in resumed["upload"]["parts"]] == [True, False, True]


async def test_the_same_audio_is_uploaded_once_per_account(h):
    tokens = await h.sms_login()
    first = (await h.http.post("/v1/recordings", headers=bearer(tokens), json=meta())).json()
    # Before the upload finishes, the repeat resumes the same recording and upload.
    repeat = await h.http.post("/v1/recordings", headers=bearer(tokens), json=meta(title="改了标题"))
    assert repeat.status_code == 200 and repeat.json()["id"] == first["id"]
    assert repeat.json()["title"] == "周会"

    def upload_id(recording: dict) -> str:
        return recording["upload"]["parts"][0]["url"].split("upload=")[1][:32]

    assert upload_id(repeat.json()) == upload_id(first)
    await put_parts(h, first)
    await h.http.post(f"/v1/recordings/{first['id']}/upload-complete", headers=bearer(tokens))
    # Once stored, nothing to upload.
    after = await h.http.post("/v1/recordings", headers=bearer(tokens), json=meta())
    assert after.status_code == 200 and after.json()["upload"] is None
    assert await h.count("recordings") == 1
    # Another account with the same audio gets its own recording.
    other = await h.sms_login("13900000000")
    theirs = await h.http.post("/v1/recordings", headers=bearer(other), json=meta())
    assert theirs.status_code == 201 and theirs.json()["id"] != first["id"]


async def test_recordings_are_per_account(h):
    a = await h.sms_login()
    b = await h.sms_login("13900000000")
    mine = await uploaded(h, a)
    for path in ("", "/audio-url"):
        reply = await h.http.get(f"/v1/recordings/{mine['id']}{path}", headers=bearer(b))
        assert reply.status_code == 404 and reply.json()["error"]["code"] == "recording_not_found"
    assert (await h.http.delete(f"/v1/recordings/{mine['id']}", headers=bearer(b))).status_code == 404
    assert (await h.http.get("/v1/recordings", headers=bearer(b))).json()["items"] == []
    assert (await h.http.get("/v1/recordings")).status_code == 401


async def test_a_recording_without_audio(h):
    tokens = await h.sms_login()
    created = await h.http.post("/v1/recordings", headers=bearer(tokens), json=meta(None, source="import"))
    assert created.status_code == 201
    assert created.json()["audio"] is None and created.json()["upload"] is None
    rid = created.json()["id"]
    for path in ("upload", "upload-complete"):
        reply = await h.http.post(f"/v1/recordings/{rid}/{path}", headers=bearer(tokens))
        assert reply.status_code == 409 and reply.json()["error"]["code"] == "no_audio"
    link = await h.http.get(f"/v1/recordings/{rid}/audio-url", headers=bearer(tokens))
    assert link.status_code == 409 and link.json()["error"]["code"] == "audio_not_uploaded"


async def test_recordings_name_their_card_when_it_is_registered(h):
    tokens = await h.sms_login()
    await h.http.put(f"/v1/devices/{SN_HASH}", headers=bearer(tokens), json={"bond_id": BOND})
    known = await h.http.post("/v1/recordings", headers=bearer(tokens), json=meta(None, device_sn_hash=SN_HASH))
    assert known.json()["device_sn_hash"] == SN_HASH
    unknown = await h.http.post("/v1/recordings", headers=bearer(tokens), json=meta(None, device_sn_hash="0" * 64))
    assert unknown.status_code == 201 and unknown.json()["device_sn_hash"] is None
    await h.http.delete(f"/v1/devices/{SN_HASH}", headers=bearer(tokens))
    after = await h.http.get(f"/v1/recordings/{known.json()['id']}", headers=bearer(tokens))
    assert after.status_code == 200 and after.json()["device_sn_hash"] is None


async def test_listing_pages_newest_first(h):
    tokens = await h.sms_login()
    for day in range(1, 6):
        await h.http.post(
            "/v1/recordings", headers=bearer(tokens), json=meta(None, started_at=f"2026-11-0{day}T08:00:00Z")
        )
    first = (await h.http.get("/v1/recordings?limit=2", headers=bearer(tokens))).json()
    assert [r["started_at"][:10] for r in first["items"]] == ["2026-11-05", "2026-11-04"]
    second = (await h.http.get(f"/v1/recordings?limit=2&cursor={first['next_cursor']}", headers=bearer(tokens))).json()
    third = (await h.http.get(f"/v1/recordings?limit=2&cursor={second['next_cursor']}", headers=bearer(tokens))).json()
    days = [r["started_at"][:10] for r in second["items"] + third["items"]]
    assert days == ["2026-11-03", "2026-11-02", "2026-11-01"]
    assert third["next_cursor"] is None
    bad = await h.http.get("/v1/recordings?cursor=nonsense", headers=bearer(tokens))
    assert bad.status_code == 422 and bad.json()["error"]["code"] == "invalid_cursor"


async def test_deleting_a_recording_removes_its_audio_and_keeps_a_tombstone(h):
    tokens = await h.sms_login()
    recording = await uploaded(h, tokens)
    assert len(h.files) == 1
    assert (await h.http.delete(f"/v1/recordings/{recording['id']}", headers=bearer(tokens))).status_code == 204
    assert h.files == [] and await h.count("object_deletions") == 0
    assert (await h.http.get(f"/v1/recordings/{recording['id']}", headers=bearer(tokens))).status_code == 404
    async with h.run.engine.connect() as connection:
        row = (await connection.execute(text("SELECT deleted_at, audio_object_key, version FROM recordings"))).one()
    assert row.deleted_at is not None and row.audio_object_key is None and row.version == 3
    # The same audio can be uploaded again as a new recording.
    again = await h.http.post("/v1/recordings", headers=bearer(tokens), json=meta())
    assert again.status_code == 201 and again.json()["id"] != recording["id"]


async def test_deleting_a_recording_mid_upload_drops_the_parts(h):
    tokens = await h.sms_login()
    created = (await h.http.post("/v1/recordings", headers=bearer(tokens), json=meta())).json()
    await put_parts(h, created, only={1})
    assert len(h.files) == 1
    await h.http.delete(f"/v1/recordings/{created['id']}", headers=bearer(tokens))
    assert h.files == []
    late = await h.http.put(created["upload"]["parts"][1]["url"], content=AUDIO[1024:2048])
    assert late.status_code == 404 and late.json()["error"]["code"] == "upload_not_found"


async def test_deleting_the_account_removes_its_audio(h):
    tokens = await h.sms_login()
    other = await h.sms_login("13900000000")
    await uploaded(h, tokens)
    partial = (await h.http.post("/v1/recordings", headers=bearer(tokens), json=meta(os.urandom(3000)))).json()
    await put_parts(h, partial, os.urandom(3000), only={1})
    await uploaded(h, other)
    assert len(h.files) == 3
    assert (await h.http.delete("/v1/me", headers=bearer(tokens))).status_code == 204
    assert await h.count("recordings") == 1 and await h.count("object_deletions") == 0
    assert len(h.files) == 1  # the other account's


class FlakyStore(LocalStore):
    down = False

    async def delete(self, key: str) -> None:
        if self.down:
            raise OSError("storage down")
        await super().delete(key)

    async def start_upload(self, key: str, content_type: str) -> str:
        if self.down:
            raise OSError("storage down")
        return await super().start_upload(key, content_type)


async def test_audio_is_removed_later_when_storage_is_down(h):
    store = FlakyStore(h.run.store.root, h.run.store.base_url, h.run.store._secret)
    h.run.store = store
    tokens = await h.sms_login()
    recording = await uploaded(h, tokens)
    store.down = True
    # Deleting still works for the user; the removal waits in the queue.
    assert (await h.http.delete(f"/v1/recordings/{recording['id']}", headers=bearer(tokens))).status_code == 204
    assert len(h.files) == 1
    async with h.run.engine.connect() as connection:
        row = (await connection.execute(text("SELECT attempts, last_error FROM object_deletions"))).one()
    assert row.attempts == 1 and "storage down" in row.last_error
    # A new upload cannot start without storage: nothing is created.
    failed = await h.http.post("/v1/recordings", headers=bearer(tokens), json=meta(os.urandom(100)))
    assert failed.status_code == 502 and failed.json()["error"] == {
        "code": "storage_unavailable",
        "message": "存储服务暂时不可用，请稍后再试",
        "retryable": True,
    }
    assert await h.count("recordings") == 1
    store.down = False
    assert await drain_deletions(h.run) == 1
    assert h.files == [] and await h.count("object_deletions") == 0


async def test_unfinished_uploads_are_dropped_after_a_week(h):
    tokens = await h.sms_login()
    created = (await h.http.post("/v1/recordings", headers=bearer(tokens), json=meta())).json()
    await put_parts(h, created, only={1})
    h.clock.advance(days=6)
    assert await sweep_stale_uploads(h.run) == 0
    h.clock.advance(days=2)
    assert await sweep_stale_uploads(h.run) == 1
    assert await drain_deletions(h.run) == 1 and h.files == []
    tokens = await h.sms_login()  # the access token ran out meanwhile
    # The app still has the audio: asking again starts a new upload under a new key.
    resumed = await h.http.post(f"/v1/recordings/{created['id']}/upload", headers=bearer(tokens))
    assert [p["done"] for p in resumed.json()["upload"]["parts"]] == [False, False, False]
    assert resumed.json()["upload"]["parts"][0]["url"] != created["upload"]["parts"][0]["url"]
    await put_parts(h, resumed.json())
    done = await h.http.post(f"/v1/recordings/{created['id']}/upload-complete", headers=bearer(tokens))
    assert done.status_code == 200


async def test_a_forgotten_upload_starts_over(h):
    tokens = await h.sms_login()
    created = (await h.http.post("/v1/recordings", headers=bearer(tokens), json=meta())).json()
    await put_parts(h, created)
    for path in (h.run.settings.storage_dir / "uploads").iterdir():
        for f in path.iterdir():
            f.unlink()
        path.rmdir()
    expired = await h.http.post(f"/v1/recordings/{created['id']}/upload-complete", headers=bearer(tokens))
    assert expired.status_code == 409 and expired.json()["error"]["code"] == "upload_expired"
    again = await h.http.post(f"/v1/recordings/{created['id']}/upload", headers=bearer(tokens))
    assert again.status_code == 200 and not any(p["done"] for p in again.json()["upload"]["parts"])


async def test_storage_urls_are_signed_and_expire(h):
    tokens = await h.sms_login()
    created = (await h.http.post("/v1/recordings", headers=bearer(tokens), json=meta())).json()
    url = created["upload"]["parts"][0]["url"]
    tampered = url.replace("part=1", "part=2")
    assert (await h.http.put(tampered, content=b"x")).status_code == 403
    other_key = url.replace("/dev-storage/audio/", "/dev-storage/audio2/")
    assert (await h.http.put(other_key, content=b"x")).status_code == 403
    assert (await h.http.put(url, content=b"x" * 1025)).status_code == 413
    h.clock.advance(hours=1, seconds=1)
    expired = await h.http.put(url, content=AUDIO[:1024])
    assert expired.status_code == 403 and expired.json()["error"]["code"] == "signature_invalid"
    tokens = await h.sms_login()
    recording = await uploaded(h, tokens, os.urandom(10))
    link = (await h.http.get(f"/v1/recordings/{recording['id']}/audio-url", headers=bearer(tokens))).json()
    assert (await h.http.get(link["url"].replace("name=", "name=x"))).status_code == 403
    h.clock.advance(hours=1, seconds=1)
    assert (await h.http.get(link["url"])).status_code == 403


async def test_recording_input_is_checked(h):
    tokens = await h.sms_login()
    too_big = meta()
    too_big["audio"]["size"] = 1024 * 1024 + 1
    reply = await h.http.post("/v1/recordings", headers=bearer(tokens), json=too_big)
    assert reply.status_code == 413 and reply.json()["error"]["code"] == "audio_too_large"
    for bad in (
        meta(source="tape"),
        meta(started_at="2026-11-20T09:30:00"),  # no time zone
        meta(duration_ms=-1),
        meta(audio=None) | {"audio": {"sha256": "abc", "size": 1}},
        meta(audio=None) | {"audio": {"sha256": SHA, "size": 1, "content_type": "text/plain"}},
    ):
        reply = await h.http.post("/v1/recordings", headers=bearer(tokens), json=bad)
        assert reply.status_code == 422 and reply.json()["error"]["code"] == "invalid_request", bad
    assert (await h.http.post("/v1/recordings", json=meta())).status_code == 401


async def test_creating_with_an_idempotency_key_replays(h):
    tokens = await h.sms_login()
    key = {"Idempotency-Key": "rec-1"}
    body = meta(None, source="phone")
    one = await h.http.post("/v1/recordings", headers=bearer(tokens) | key, json=body)
    two = await h.http.post("/v1/recordings", headers=bearer(tokens) | key, json=body)
    assert one.json() == two.json() and two.headers.get("idempotent-replayed") == "true"
    assert await h.count("recordings") == 1
