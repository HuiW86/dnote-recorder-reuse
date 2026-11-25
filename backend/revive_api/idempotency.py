"""Idempotency-Key on writes (prd.md §7.1): the first response to a key is kept for 24 hours and
replayed to repeats, so a request retried after a dropped connection is not applied twice.

Keys are per caller: the user of a valid access token (expired or not, so a key survives the
token being renewed), else a hash of whatever Authorization was sent, else "anonymous". The same key with a different
request is refused; a repeat while the first is still running is told to retry. A first request
that never recorded an answer (its server died) counts as abandoned after
`idempotency_abandoned_seconds`, and a repeat of the same request then runs it again instead of
being told to retry for the rest of the 24 hours. Stored bodies are encrypted: a refresh response
holds tokens."""

import hashlib
import json
import secrets
from datetime import timedelta

from sqlalchemy import delete, select, update
from sqlalchemy.dialects.postgresql import insert
from starlette.datastructures import Headers
from starlette.types import ASGIApp, Message, Receive, Scope, Send

from .errors import error_body
from .models import IdempotencyRecord
from .runtime import Runtime
from .security import sha256_hex

WRITES = {"POST", "PUT", "PATCH", "DELETE"}


class IdempotencyMiddleware:
    def __init__(self, app: ASGIApp):
        self.app = app

    async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
        if scope["type"] != "http" or scope["method"] not in WRITES:
            return await self.app(scope, receive, send)
        headers = Headers(scope=scope)
        key = headers.get("idempotency-key")
        if key is None:
            return await self.app(scope, receive, send)
        if not 1 <= len(key) <= 255:
            return await _json(send, 400, error_body("invalid_idempotency_key", "Idempotency-Key 太长或为空"))

        body = b""
        more = True
        while more:
            message = await receive()
            body += message.get("body", b"")
            more = message.get("more_body", False)

        run: Runtime = scope["app"].state.runtime
        caller = _caller(run, headers.get("authorization"))
        target = f"{scope['method']} {scope['path']}?{scope.get('query_string', b'').decode()}\n".encode()
        request_hash = hashlib.sha256(target + body).hexdigest()
        now = run.clock.now()
        cutoff = now - timedelta(hours=run.settings.idempotency_ttl_hours)

        async with run.sessions() as db, db.begin():
            await db.execute(
                delete(IdempotencyRecord).where(
                    IdempotencyRecord.scope == caller,
                    IdempotencyRecord.key == key,
                    IdempotencyRecord.created_at < cutoff,
                )
            )
            if secrets.randbelow(100) == 0:  # now and then, sweep everyone's expired records
                await db.execute(delete(IdempotencyRecord).where(IdempotencyRecord.created_at < cutoff))
            inserted = await db.scalar(
                insert(IdempotencyRecord)
                .values(scope=caller, key=key, request_hash=request_hash, created_at=now)
                .on_conflict_do_nothing(constraint="idempotency_scope_key")
                .returning(IdempotencyRecord.id)
            )
            if not inserted:
                # Take over a first attempt that died before recording its answer.
                inserted = await db.scalar(
                    update(IdempotencyRecord)
                    .where(
                        IdempotencyRecord.scope == caller,
                        IdempotencyRecord.key == key,
                        IdempotencyRecord.request_hash == request_hash,
                        IdempotencyRecord.status_code.is_(None),
                        IdempotencyRecord.created_at
                        < now - timedelta(seconds=run.settings.idempotency_abandoned_seconds),
                    )
                    .values(created_at=now)
                    .returning(IdempotencyRecord.id)
                )
            existing = (
                None
                if inserted
                else await db.scalar(
                    select(IdempotencyRecord).where(IdempotencyRecord.scope == caller, IdempotencyRecord.key == key)
                )
            )

        if existing is not None:
            if existing.request_hash != request_hash:
                return await _json(
                    send, 422, error_body("idempotency_key_reused", "这个 Idempotency-Key 已经用于另一个请求")
                )
            if existing.status_code is None:
                return await _json(
                    send, 409, error_body("idempotency_in_progress", "同一个请求还在处理，请稍后再试", retryable=True)
                )
            stored = run.box.open(f"idempotency:{caller}:{key}", existing.body) if existing.body else b""
            return await _raw(send, existing.status_code, existing.content_type, stored, replayed=True)

        status = 500
        content_type = None
        chunks: list[bytes] = []
        sent_body = False

        async def replay_receive() -> Message:
            nonlocal sent_body
            if not sent_body:
                sent_body = True
                return {"type": "http.request", "body": body, "more_body": False}
            return await receive()

        async def capture(message: Message) -> None:
            nonlocal status, content_type
            if message["type"] == "http.response.start":
                status = message["status"]
                content_type = Headers(raw=message.get("headers", [])).get("content-type")
            elif message["type"] == "http.response.body":
                chunks.append(message.get("body", b""))
            await send(message)

        try:
            await self.app(scope, replay_receive, capture)
        finally:
            async with run.sessions() as db, db.begin():
                where = (IdempotencyRecord.scope == caller, IdempotencyRecord.key == key)
                if status < 500:
                    data = b"".join(chunks)
                    await db.execute(
                        update(IdempotencyRecord)
                        .where(*where)
                        .values(
                            status_code=status,
                            content_type=content_type,
                            body=run.box.seal(f"idempotency:{caller}:{key}", data) if data else None,
                        )
                    )
                else:
                    # A server error is not an answer: let the retry run again.
                    await db.execute(delete(IdempotencyRecord).where(*where))


def _caller(run: Runtime, authorization: str | None) -> str:
    if authorization and authorization.lower().startswith("bearer "):
        owner = run.tokens.owner(authorization[7:].strip())
        if owner is not None:
            return f"user:{owner}"
    return sha256_hex(authorization) if authorization else "anonymous"


async def _json(send: Send, status: int, payload: dict) -> None:
    await _raw(send, status, "application/json", json.dumps(payload, ensure_ascii=False).encode(), replayed=False)


async def _raw(send: Send, status: int, content_type: str | None, body: bytes, replayed: bool) -> None:
    headers = [(b"content-length", str(len(body)).encode())]
    if content_type:
        headers.append((b"content-type", content_type.encode()))
    if replayed:
        headers.append((b"idempotent-replayed", b"true"))
    await send({"type": "http.response.start", "status": status, "headers": headers})
    await send({"type": "http.response.body", "body": body})
