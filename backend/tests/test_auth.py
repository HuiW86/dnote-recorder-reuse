"""K1 accounts (prd.md §7.1, §7.2): SMS login, email sign-up, passwords, refresh rotation."""

from conftest import bearer


async def test_sms_login_creates_the_account_once(h):
    sent = await h.http.post("/v1/auth/sms/send", json={"phone": "+86 138-1234-5678"})
    assert sent.status_code == 202 and sent.json() == {"resend_after_seconds": 60}
    assert h.sms.sent[-1][:2] == ("+8613812345678", "sms_login")
    first = await h.http.post("/v1/auth/sms/login", json={"phone": "13812345678", "code": h.sms.last("+8613812345678")})
    assert first.status_code == 200
    body = first.json()
    assert body["token_type"] == "bearer" and body["expires_in"] == 900
    assert body["user"]["phone"] == "+8613812345678" and body["user"]["has_password"] is False
    h.clock.advance(seconds=61)
    again = await h.sms_login("13812345678")
    assert again["user"]["id"] == body["user"]["id"]
    assert await h.count("users") == 1


async def test_only_mainland_mobile_numbers(h):
    for phone in ["12345", "+14155550123", "1381234567x"]:
        reply = await h.http.post("/v1/auth/sms/send", json={"phone": phone})
        assert reply.status_code == 422 and reply.json()["error"]["code"] == "invalid_phone"
    assert h.sms.sent == []


async def test_codes_are_throttled(h):
    phone = {"phone": "13812345678"}
    assert (await h.http.post("/v1/auth/sms/send", json=phone)).status_code == 202
    soon = await h.http.post("/v1/auth/sms/send", json=phone)
    assert soon.status_code == 429
    assert soon.json()["error"] == {
        "code": "code_too_frequent",
        "message": "验证码发得太频繁，请 60 秒后再试",
        "retryable": True,
    }
    for _ in range(9):
        h.clock.advance(seconds=61)
        assert (await h.http.post("/v1/auth/sms/send", json=phone)).status_code == 202
    h.clock.advance(seconds=61)
    capped = await h.http.post("/v1/auth/sms/send", json=phone)
    assert capped.status_code == 429 and capped.json()["error"]["code"] == "code_daily_limit"
    h.clock.advance(days=1)
    assert (await h.http.post("/v1/auth/sms/send", json=phone)).status_code == 202


async def test_wrong_codes_count_even_though_the_request_fails(h):
    await h.http.post("/v1/auth/sms/send", json={"phone": "13812345678"})
    right = h.sms.last("+8613812345678")
    wrong = "000000" if right != "000000" else "111111"
    for _ in range(5):
        reply = await h.http.post("/v1/auth/sms/login", json={"phone": "13812345678", "code": wrong})
        assert reply.status_code == 400 and reply.json()["error"]["code"] == "code_invalid"
    # The attempts were committed despite the errors, so even the right code is now refused.
    locked = await h.http.post("/v1/auth/sms/login", json={"phone": "13812345678", "code": right})
    assert locked.status_code == 429 and locked.json()["error"]["code"] == "code_attempts_exceeded"
    assert await h.count("users") == 0


async def test_codes_expire_and_work_once(h):
    await h.http.post("/v1/auth/sms/send", json={"phone": "13812345678"})
    code = h.sms.last("+8613812345678")
    h.clock.advance(seconds=601)
    late = await h.http.post("/v1/auth/sms/login", json={"phone": "13812345678", "code": code})
    assert late.json()["error"]["code"] == "code_expired"
    await h.http.post("/v1/auth/sms/send", json={"phone": "13812345678"})
    fresh = h.sms.last("+8613812345678")
    assert (await h.http.post("/v1/auth/sms/login", json={"phone": "13812345678", "code": fresh})).status_code == 200
    reused = await h.http.post("/v1/auth/sms/login", json={"phone": "13812345678", "code": fresh})
    assert reused.json()["error"]["code"] == "code_invalid"


async def test_a_failing_sms_provider_stores_no_code(h):
    h.sms.fail = True
    reply = await h.http.post("/v1/auth/sms/send", json={"phone": "13812345678"})
    assert reply.status_code == 502 and reply.json()["error"] == {
        "code": "code_send_failed",
        "message": "验证码发送失败，请稍后再试",
        "retryable": True,
    }
    assert await h.count("verification_codes") == 0
    h.sms.fail = False
    assert (await h.http.post("/v1/auth/sms/send", json={"phone": "13812345678"})).status_code == 202


async def test_email_sign_up_verify_and_password_login(h):
    reg = await h.http.post("/v1/auth/email/register", json={"email": "Ann@Example.com", "password": "first password"})
    assert reg.status_code == 202
    # Registering again before verifying replaces the password and sends a new code.
    h.clock.advance(seconds=61)
    await h.http.post("/v1/auth/email/register", json={"email": "ann@example.com", "password": "second password"})
    early = await h.http.post(
        "/v1/auth/password/login", json={"email": "ann@example.com", "password": "second password"}
    )
    assert early.status_code == 403 and early.json()["error"]["code"] == "email_not_verified"
    verified = await h.http.post(
        "/v1/auth/email/verify", json={"email": "ann@example.com", "code": h.email.last("ann@example.com")}
    )
    assert verified.status_code == 200 and verified.json()["user"]["email_verified"] is True
    ok = await h.http.post("/v1/auth/password/login", json={"email": "ANN@example.com", "password": "second password"})
    assert ok.status_code == 200
    old = await h.http.post("/v1/auth/password/login", json={"email": "ann@example.com", "password": "first password"})
    unknown = await h.http.post("/v1/auth/password/login", json={"email": "nobody@example.com", "password": "x"})
    assert old.status_code == unknown.status_code == 401
    assert old.json() == unknown.json()
    taken = await h.http.post("/v1/auth/email/register", json={"email": "ann@example.com", "password": "another one"})
    assert taken.status_code == 409 and taken.json()["error"]["code"] == "email_taken"


async def test_short_passwords_and_bad_emails_are_refused(h):
    short = await h.http.post("/v1/auth/email/register", json={"email": "a@example.com", "password": "short"})
    bad = await h.http.post("/v1/auth/email/register", json={"email": "not-an-email", "password": "long enough"})
    assert short.status_code == bad.status_code == 422
    assert short.json()["error"]["code"] == "invalid_request"


async def test_password_reset_signs_everyone_out(h):
    account = await h.email_account("b@example.com", "old password")
    unknown = await h.http.post("/v1/auth/password/reset/send", json={"email": "ghost@example.com"})
    known = await h.http.post("/v1/auth/password/reset/send", json={"email": "b@example.com"})
    assert unknown.status_code == known.status_code == 202 and unknown.json() == known.json()
    assert [t for t, purpose, _ in h.email.sent if purpose == "password_reset"] == ["b@example.com"]
    reset = await h.http.post(
        "/v1/auth/password/reset",
        json={"email": "b@example.com", "code": h.email.last("b@example.com"), "new_password": "new password"},
    )
    assert reset.status_code == 204
    stale = await h.http.post("/v1/auth/refresh", json={"refresh_token": account["refresh_token"]})
    assert stale.status_code == 401
    assert (
        await h.http.post("/v1/auth/password/login", json={"email": "b@example.com", "password": "new password"})
    ).status_code == 200
    assert (
        await h.http.post("/v1/auth/password/login", json={"email": "b@example.com", "password": "old password"})
    ).status_code == 401


async def test_refresh_rotates_and_reuse_revokes_the_family(h):
    first = await h.sms_login()
    second = await h.http.post("/v1/auth/refresh", json={"refresh_token": first["refresh_token"]})
    assert second.status_code == 200
    tokens = second.json()
    assert tokens["refresh_token"] != first["refresh_token"]
    # The spent token shows up again: someone else has it. Both copies stop working.
    reused = await h.http.post("/v1/auth/refresh", json={"refresh_token": first["refresh_token"]})
    assert reused.status_code == 401 and reused.json()["error"]["code"] == "refresh_reused"
    after = await h.http.post("/v1/auth/refresh", json={"refresh_token": tokens["refresh_token"]})
    assert after.status_code == 401
    # Another sign-in (another family) is untouched.
    other = await h.sms_login()
    assert (await h.http.post("/v1/auth/refresh", json={"refresh_token": other["refresh_token"]})).status_code == 200


async def test_a_retried_refresh_with_an_idempotency_key_is_safe(h):
    first = await h.sms_login()
    headers = {"Idempotency-Key": "refresh-1"}
    one = await h.http.post("/v1/auth/refresh", json={"refresh_token": first["refresh_token"]}, headers=headers)
    two = await h.http.post("/v1/auth/refresh", json={"refresh_token": first["refresh_token"]}, headers=headers)
    assert one.status_code == two.status_code == 200
    assert one.json() == two.json() and two.headers["idempotent-replayed"] == "true"
    # No reuse was detected: the new token still works.
    assert (
        await h.http.post("/v1/auth/refresh", json={"refresh_token": one.json()["refresh_token"]})
    ).status_code == 200


async def test_refresh_tokens_expire_after_30_days(h):
    tokens = await h.sms_login()
    h.clock.advance(days=30, seconds=1)
    late = await h.http.post("/v1/auth/refresh", json={"refresh_token": tokens["refresh_token"]})
    assert late.status_code == 401 and late.json()["error"]["code"] == "refresh_invalid"


async def test_logout_spends_the_refresh_token(h):
    tokens = await h.sms_login()
    assert (await h.http.post("/v1/auth/logout", json={"refresh_token": tokens["refresh_token"]})).status_code == 204
    assert (await h.http.post("/v1/auth/refresh", json={"refresh_token": tokens["refresh_token"]})).status_code == 401
    assert (await h.http.post("/v1/auth/logout", json={"refresh_token": "never-issued"})).status_code == 204


async def test_access_tokens_expire_after_15_minutes(h):
    tokens = await h.sms_login()
    assert (await h.http.get("/v1/me", headers=bearer(tokens))).status_code == 200
    h.clock.advance(minutes=15)
    expired = await h.http.get("/v1/me", headers=bearer(tokens))
    assert expired.status_code == 401
    assert expired.json()["error"] == {"code": "token_expired", "message": "登录已过期", "retryable": True}
    fresh = await h.http.post("/v1/auth/refresh", json={"refresh_token": tokens["refresh_token"]})
    assert (await h.http.get("/v1/me", headers=bearer(fresh.json()))).status_code == 200


async def test_missing_or_forged_tokens(h):
    assert (await h.http.get("/v1/me")).json()["error"]["code"] == "unauthorized"
    forged = await h.http.get("/v1/me", headers={"Authorization": "Bearer abc.def.ghi"})
    assert forged.status_code == 401 and forged.json()["error"]["code"] == "invalid_token"
