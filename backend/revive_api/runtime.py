"""What the routes and the worker need: database, clock, code senders, object store, speech
recognition, language model, crypto helpers.

Built once in `create_app` and kept on `app.state.runtime`; tests build their own with a
movable clock and a sender that keeps codes in memory."""

import hashlib
import hmac
import logging
from collections.abc import AsyncIterator
from dataclasses import dataclass, field
from datetime import UTC, datetime, timedelta
from typing import Annotated, Protocol

from fastapi import Depends, Request
from sqlalchemy.ext.asyncio import AsyncEngine, AsyncSession, async_sessionmaker, create_async_engine

from .asr import StandInTranscriber, Transcriber
from .config import Settings
from .errors import AppError
from .llm import ChatModel, StandInChatModel
from .security import Box, Codes, DeviceVault, Tokens
from .storage import LocalStore, ObjectStore

log = logging.getLogger("revive_api")


class Clock(Protocol):
    def now(self) -> datetime: ...


class SystemClock:
    def now(self) -> datetime:
        return datetime.now(UTC)


@dataclass
class FixedClock:
    """For tests: time moves only when told to."""

    current: datetime = field(default_factory=lambda: datetime(2026, 11, 22, 8, 0, tzinfo=UTC))

    def now(self) -> datetime:
        return self.current

    def advance(self, **delta: float) -> None:
        self.current += timedelta(**delta)


class CodeSender(Protocol):
    """Delivers a verification code by SMS or email. The real ones (Tencent SMS, an SMTP relay)
    wait for the cloud account (ADR-003); until then `LoggingSender` stands in outside prod."""

    async def send(self, target: str, purpose: str, code: str) -> None: ...


class LoggingSender:
    async def send(self, target: str, purpose: str, code: str) -> None:
        log.warning("verification code for %s (%s): %s  [LoggingSender: not for production]", target, purpose, code)


@dataclass
class Runtime:
    settings: Settings
    engine: AsyncEngine
    sessions: async_sessionmaker[AsyncSession]
    clock: Clock
    sms: CodeSender
    email: CodeSender
    store: ObjectStore
    transcriber: Transcriber
    chat: ChatModel
    tokens: Tokens
    codes: Codes
    vault: DeviceVault
    box: Box

    @classmethod
    def build(
        cls,
        settings: Settings,
        clock: Clock | None = None,
        sms: CodeSender | None = None,
        email: CodeSender | None = None,
        store: ObjectStore | None = None,
        transcriber: Transcriber | None = None,
        chat: ChatModel | None = None,
    ) -> "Runtime":
        if settings.environment == "prod" and (sms is None or email is None):
            # Codes must never end up only in a log in production.
            raise RuntimeError("production needs real SMS and email senders")
        if settings.environment == "prod" and store is None:
            # Audio on the API server's disk, served by the API, is for development only.
            raise RuntimeError("production needs a real object store")
        if settings.environment == "prod" and transcriber is None:
            raise RuntimeError("production needs a real speech recognition engine")
        if settings.environment == "prod" and chat is None:
            raise RuntimeError("production needs a real language model")
        if settings.environment == "prod" and (
            settings.asr_monthly_seconds is None or settings.llm_monthly_tokens is None
        ):
            # Unlimited ASR and model use is a cost decision someone must make on purpose.
            raise RuntimeError("production needs REVIVE_ASR_MONTHLY_SECONDS and REVIVE_LLM_MONTHLY_TOKENS")
        engine = create_async_engine(settings.database_url, pool_pre_ping=True)
        return cls(
            settings=settings,
            engine=engine,
            sessions=async_sessionmaker(engine, expire_on_commit=False),
            clock=clock or SystemClock(),
            sms=sms or LoggingSender(),
            email=email or LoggingSender(),
            store=store or local_store(settings),
            transcriber=transcriber or StandInTranscriber(),
            chat=chat or StandInChatModel(),
            tokens=Tokens(settings),
            codes=Codes(settings),
            vault=DeviceVault(settings),
            box=Box(settings),
        )


def local_store(settings: Settings) -> LocalStore:
    secret = hmac.new(settings.code_secret.get_secret_value().encode(), b"local-store", hashlib.sha256).digest()
    return LocalStore(settings.storage_dir, settings.public_base_url, secret)


def runtime(request: Request) -> Runtime:
    return request.app.state.runtime


async def session(request: Request) -> AsyncIterator[AsyncSession]:
    """One transaction per request: committed when the route returns, rolled back on an error
    unless the error says to keep its changes."""
    async with runtime(request).sessions() as db:
        try:
            yield db
        except AppError as error:
            await (db.commit() if error.keep_changes else db.rollback())
            raise
        except BaseException:
            await db.rollback()
            raise
        else:
            await db.commit()


# scope="function": the commit happens before the response is sent. With the default ("request")
# it would happen after, and a client could use a just-issued refresh token before it exists.
DB = Annotated[AsyncSession, Depends(session, scope="function")]
Run = Annotated[Runtime, Depends(runtime)]
