"""Tests run against a real PostgreSQL named by TEST_DATABASE_URL; its public schema is wiped and
rebuilt with the migrations. Senders keep codes in memory, the clock only moves when told, and
audio goes to a LocalStore in a temporary directory, uploaded through its /dev-storage URLs."""

import base64
import os
import shutil
from dataclasses import dataclass, field
from pathlib import Path

import httpx
import pytest
from alembic import command
from alembic.config import Config
from sqlalchemy import create_engine, text

from revive_api.config import Settings
from revive_api.main import create_app
from revive_api.runtime import FixedClock, Runtime

TEST_URL = os.environ.get("TEST_DATABASE_URL")
if not TEST_URL:
    pytest.exit("set TEST_DATABASE_URL=postgresql+psycopg://... to a database the tests may wipe", returncode=2)

BACKEND = Path(__file__).resolve().parent.parent
TABLES = [
    "usage_records",
    "transcripts",
    "tasks",
    "idempotency_records",
    "object_deletions",
    "recordings",
    "feedback",
    "devices",
    "refresh_tokens",
    "verification_codes",
    "users",
]


@dataclass
class MemorySender:
    sent: list[tuple[str, str, str]] = field(default_factory=list)
    fail: bool = False

    async def send(self, target: str, purpose: str, code: str) -> None:
        if self.fail:
            raise RuntimeError("provider down")
        self.sent.append((target, purpose, code))

    def last(self, target: str) -> str:
        return next(code for t, _, code in reversed(self.sent) if t == target)


@dataclass
class Harness:
    http: httpx.AsyncClient
    clock: FixedClock
    sms: MemorySender
    email: MemorySender
    run: Runtime

    @property
    def files(self) -> list[Path]:
        """Every object and unfinished part the store holds."""
        root = self.run.settings.storage_dir
        return sorted(p for p in root.rglob("*") if p.is_file() and p.name not in {"key", "content-type"})

    async def count(self, table: str) -> int:
        async with self.run.engine.connect() as connection:
            return (await connection.execute(text(f"SELECT count(*) FROM {table}"))).scalar_one()  # noqa: S608

    async def sms_login(self, phone: str = "13812345678") -> dict:
        assert (await self.http.post("/v1/auth/sms/send", json={"phone": phone})).status_code == 202
        reply = await self.http.post(
            "/v1/auth/sms/login", json={"phone": phone, "code": self.sms.last("+86" + phone[-11:])}
        )
        assert reply.status_code == 200, reply.text
        self.clock.advance(seconds=61)  # past the resend wait, for the next code
        return reply.json()

    async def email_account(self, email: str = "a@example.com", password: str = "correct horse") -> dict:
        assert (
            await self.http.post("/v1/auth/email/register", json={"email": email, "password": password})
        ).status_code == 202
        reply = await self.http.post("/v1/auth/email/verify", json={"email": email, "code": self.email.last(email)})
        assert reply.status_code == 200, reply.text
        self.clock.advance(seconds=61)
        return reply.json()


def bearer(tokens: dict) -> dict:
    return {"Authorization": f"Bearer {tokens['access_token']}"}


@pytest.fixture(scope="session")
def settings(tmp_path_factory) -> Settings:
    return Settings(
        environment="test",
        database_url=TEST_URL,
        jwt_secret="j" * 40,
        code_secret="c" * 40,
        sn_pepper="p" * 40,
        bond_key=base64.b64encode(bytes(range(32))).decode(),
        public_base_url="http://test",
        storage_dir=tmp_path_factory.mktemp("storage"),
        # Small parts so a few kilobytes of test audio spans several.
        upload_part_bytes=1024,
        max_audio_bytes=1024 * 1024,
    )


@pytest.fixture(scope="session", autouse=True)
def schema() -> None:
    engine = create_engine(TEST_URL)
    with engine.begin() as connection:
        connection.execute(text("DROP SCHEMA public CASCADE"))
        connection.execute(text("CREATE SCHEMA public"))
    engine.dispose()
    config = Config(str(BACKEND / "alembic.ini"))
    config.set_main_option("script_location", str(BACKEND / "migrations"))
    os.environ["REVIVE_DATABASE_URL"] = TEST_URL
    command.upgrade(config, "head")


@pytest.fixture
async def h(settings: Settings):
    clock, sms, email = FixedClock(), MemorySender(), MemorySender()
    run = Runtime.build(settings, clock=clock, sms=sms, email=email)
    async with run.engine.begin() as connection:
        await connection.execute(text(f"TRUNCATE {', '.join(TABLES)} CASCADE"))
    shutil.rmtree(settings.storage_dir, ignore_errors=True)
    transport = httpx.ASGITransport(app=create_app(run))
    async with httpx.AsyncClient(transport=transport, base_url="http://test") as client:
        yield Harness(client, clock, sms, email, run)
    await run.engine.dispose()
