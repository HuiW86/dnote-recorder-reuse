"""/me, devices (A4b), feedback (O1b), idempotency and the error shape."""

import base64
import hashlib

import pytest
from conftest import bearer
from cryptography.exceptions import InvalidTag
from sqlalchemy import text

SN_HASH = hashlib.sha256(b"DN12345678").hexdigest()
BOND = base64.b64encode(bytes(range(16))).decode()


async def test_me_and_password_change(h):
    account = await h.email_account("c@example.com", "old password")
    other = await h.http.post("/v1/auth/password/login", json={"email": "c@example.com", "password": "old password"})
    me = await h.http.get("/v1/me", headers=bearer(account))
    assert me.json()["email"] == "c@example.com" and me.json()["has_password"] is True
    wrong = await h.http.post(
        "/v1/me/password", headers=bearer(account), json={"current_password": "nope", "new_password": "new password"}
    )
    assert wrong.status_code == 401
    changed = await h.http.post(
        "/v1/me/password",
        headers=bearer(account),
        json={"current_password": "old password", "new_password": "new password"},
    )
    assert changed.status_code == 200
    # Every earlier sign-in is out; the returned tokens work.
    for stale in (account, other.json()):
        assert (
            await h.http.post("/v1/auth/refresh", json={"refresh_token": stale["refresh_token"]})
        ).status_code == 401
    assert (
        await h.http.post("/v1/auth/refresh", json={"refresh_token": changed.json()["refresh_token"]})
    ).status_code == 200


async def test_phone_accounts_have_no_password_to_change(h):
    tokens = await h.sms_login()
    reply = await h.http.post(
        "/v1/me/password", headers=bearer(tokens), json={"current_password": "x", "new_password": "new password"}
    )
    assert reply.status_code == 400 and reply.json()["error"]["code"] == "password_not_set"


async def test_deleting_the_account_deletes_everything(h):
    tokens = await h.sms_login()
    await h.http.put(f"/v1/devices/{SN_HASH}", headers=bearer(tokens), json={"bond_id": BOND})
    await h.http.post("/v1/feedback", headers=bearer(tokens), json={"content": "好用"})
    keep = await h.sms_login("13900000000")
    assert (await h.http.delete("/v1/me", headers=bearer(tokens))).status_code == 204
    assert await h.count("users") == 1
    assert await h.count("devices") == await h.count("feedback") == 0
    assert await h.count("refresh_tokens") == 1  # the other account's
    gone = await h.http.get("/v1/me", headers=bearer(tokens))
    assert gone.status_code == 401 and gone.json()["error"]["code"] == "invalid_token"
    assert (await h.http.get("/v1/me", headers=bearer(keep))).status_code == 200


async def test_devices_round_trip_without_storing_secrets_in_the_clear(h):
    tokens = await h.sms_login()
    put = await h.http.put(
        f"/v1/devices/{SN_HASH.upper()}",
        headers=bearer(tokens),
        json={"bond_id": BOND, "name": "会议室卡", "firmware": "1.50"},
    )
    assert put.status_code == 200
    assert put.json()["sn_hash"] == SN_HASH and put.json()["bond_id"] == BOND
    renamed = await h.http.put(
        f"/v1/devices/{SN_HASH}", headers=bearer(tokens), json={"bond_id": BOND, "name": "我的卡", "firmware": "1.50"}
    )
    assert renamed.json()["name"] == "我的卡"
    listed = (await h.http.get("/v1/devices", headers=bearer(tokens))).json()
    assert [(d["sn_hash"], d["bond_id"], d["name"]) for d in listed] == [(SN_HASH, BOND, "我的卡")]
    async with h.run.engine.connect() as connection:
        row = (await connection.execute(text("SELECT sn_key, secret FROM devices"))).one()
    assert row.sn_key != SN_HASH
    assert SN_HASH.encode() not in row.secret and bytes(range(16)) not in row.secret


async def test_devices_are_per_account(h):
    a = await h.sms_login()
    b = await h.sms_login("13900000000")
    await h.http.put(f"/v1/devices/{SN_HASH}", headers=bearer(a), json={"bond_id": BOND})
    assert (await h.http.get("/v1/devices", headers=bearer(b))).json() == []
    other_bond = base64.b64encode(b"\x01" * 16).decode()
    await h.http.put(f"/v1/devices/{SN_HASH}", headers=bearer(b), json={"bond_id": other_bond})
    assert (await h.http.get("/v1/devices", headers=bearer(a))).json()[0]["bond_id"] == BOND
    assert (await h.http.delete(f"/v1/devices/{SN_HASH}", headers=bearer(b))).status_code == 204
    again = await h.http.delete(f"/v1/devices/{SN_HASH}", headers=bearer(b))
    assert again.status_code == 404 and again.json()["error"]["code"] == "device_not_found"
    assert len((await h.http.get("/v1/devices", headers=bearer(a))).json()) == 1


async def test_device_input_is_checked(h):
    tokens = await h.sms_login()
    assert (await h.http.put("/v1/devices/abc", headers=bearer(tokens), json={"bond_id": BOND})).status_code == 422
    bad = await h.http.put(f"/v1/devices/{SN_HASH}", headers=bearer(tokens), json={"bond_id": "%%%not base64"})
    assert bad.status_code == 422 and bad.json()["error"]["code"] == "invalid_request"
    assert (await h.http.get("/v1/devices")).status_code == 401


def test_a_sealed_device_secret_only_opens_where_it_was_sealed(settings):
    import uuid

    from revive_api.security import DeviceSecret, DeviceVault

    vault = DeviceVault(settings)
    owner, stranger = uuid.uuid4(), uuid.uuid4()
    key = vault.lookup_key(SN_HASH)
    sealed = vault.seal(owner, key, DeviceSecret(SN_HASH, b"\x02" * 16))
    assert vault.open(owner, key, sealed).bond_id == b"\x02" * 16
    with pytest.raises(InvalidTag):
        vault.open(stranger, key, sealed)


async def test_feedback(h):
    tokens = await h.sms_login()
    sent = await h.http.post(
        "/v1/feedback", headers=bearer(tokens), json={"content": " 同步很快 ", "app_version": "0.1.0 (6)"}
    )
    assert sent.status_code == 201 and "id" in sent.json()
    empty = await h.http.post("/v1/feedback", headers=bearer(tokens), json={"content": ""})
    assert empty.status_code == 422
    assert (await h.http.post("/v1/feedback", json={"content": "x"})).status_code == 401


async def test_idempotency_keys_replay_the_first_answer_per_caller(h):
    a = await h.sms_login()
    b = await h.sms_login("13900000000")
    key = {"Idempotency-Key": "fb-1"}
    one = await h.http.post("/v1/feedback", headers=bearer(a) | key, json={"content": "第一次"})
    two = await h.http.post("/v1/feedback", headers=bearer(a) | key, json={"content": "第一次"})
    assert one.json() == two.json() and two.headers.get("idempotent-replayed") == "true"
    assert await h.count("feedback") == 1
    different = await h.http.post("/v1/feedback", headers=bearer(a) | key, json={"content": "改了内容"})
    assert different.status_code == 422 and different.json()["error"]["code"] == "idempotency_key_reused"
    # Another caller with the same key is a different request.
    theirs = await h.http.post("/v1/feedback", headers=bearer(b) | key, json={"content": "第一次"})
    assert theirs.status_code == 201 and theirs.json() != one.json()
    # A renewed access token is the same caller: the key still replays.
    renewed = (await h.http.post("/v1/auth/refresh", json={"refresh_token": a["refresh_token"]})).json()
    replay = await h.http.post("/v1/feedback", headers=bearer(renewed) | key, json={"content": "第一次"})
    assert replay.json() == one.json() and replay.headers.get("idempotent-replayed") == "true"
    # After 24 hours the key is free again.
    h.clock.advance(hours=24, seconds=1)
    renewed = (await h.http.post("/v1/auth/refresh", json={"refresh_token": renewed["refresh_token"]})).json()
    later = await h.http.post("/v1/feedback", headers=bearer(renewed) | key, json={"content": "第一次"})
    assert later.status_code == 201 and later.json() != one.json()
    assert await h.count("feedback") == 3
    too_long = await h.http.post(
        "/v1/feedback", headers=bearer(a) | {"Idempotency-Key": "k" * 256}, json={"content": "x"}
    )
    assert too_long.status_code == 400


async def test_stored_replies_are_encrypted(h):
    tokens = await h.sms_login()
    reply = await h.http.post(
        "/v1/auth/refresh", json={"refresh_token": tokens["refresh_token"]}, headers={"Idempotency-Key": "r-1"}
    )
    async with h.run.engine.connect() as connection:
        body = (await connection.execute(text("SELECT body FROM idempotency_records"))).scalar_one()
    assert reply.json()["refresh_token"].encode() not in body


async def test_error_shape_for_unknown_routes_and_health(h):
    missing = await h.http.get("/v1/nothing-here")
    assert missing.status_code == 404
    assert missing.json() == {"error": {"code": "not_found", "message": "接口不存在", "retryable": False}}
    assert (await h.http.get("/healthz")).json() == {"ok": True}
