"""The ASGI app. Run with `uvicorn revive_api.main:app` (settings from REVIVE_* variables)."""

from contextlib import asynccontextmanager

from fastapi import APIRouter, FastAPI
from sqlalchemy import text

from . import errors
from .config import Settings
from .idempotency import IdempotencyMiddleware
from .routers import auth, dev_storage, devices, feedback, me, recordings, summaries, transcripts
from .runtime import Run, Runtime


def create_app(runtime: Runtime | None = None) -> FastAPI:
    @asynccontextmanager
    async def lifespan(app: FastAPI):
        if not hasattr(app.state, "runtime"):
            app.state.runtime = Runtime.build(Settings())  # type: ignore[call-arg]
        yield
        await app.state.runtime.engine.dispose()

    app = FastAPI(title="闻笺 API", version="0.1.0", lifespan=lifespan)
    if runtime is not None:
        app.state.runtime = runtime
    errors.install(app)
    app.add_middleware(IdempotencyMiddleware)

    v1 = APIRouter(prefix="/v1")
    for module in (auth, me, devices, recordings, transcripts, summaries, feedback):
        v1.include_router(module.router)
    app.include_router(v1)
    app.include_router(dev_storage.router)

    @app.get("/healthz", include_in_schema=False)
    async def healthz(run: Run) -> dict:
        async with run.engine.connect() as connection:
            await connection.execute(text("SELECT 1"))
        return {"ok": True}

    return app


app = create_app()
