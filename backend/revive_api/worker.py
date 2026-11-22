"""The worker process (ADR-013): runs queued tasks and, every few minutes, the housekeeping in
`maintenance`. Run one or more next to the API:

    python -m revive_api.worker

Stops after the current task on SIGTERM or Ctrl-C."""

import asyncio
import logging
import signal
import time

from . import maintenance, summarize, transcription
from .runtime import Runtime
from .tasks import Handler, run_one

log = logging.getLogger("revive_api")

HANDLERS: dict[str, Handler] = {
    transcription.KIND: transcription.transcribe,
    summarize.KIND: summarize.summarize,
}


async def work(run: Runtime, stop: asyncio.Event, idle_seconds: float = 1.0, maintenance_seconds: float = 600) -> None:
    last_maintenance = -maintenance_seconds
    while not stop.is_set():
        try:
            if time.monotonic() - last_maintenance >= maintenance_seconds:
                last_maintenance = time.monotonic()
                await maintenance.sweep_stale_uploads(run)
                await maintenance.drain_deletions(run)
            if await run_one(run, HANDLERS):
                continue
        except Exception:
            # The database went away, say: wait and try again rather than exit.
            log.exception("worker loop")
        try:
            await asyncio.wait_for(stop.wait(), timeout=idle_seconds)
        except TimeoutError:
            pass


async def main() -> None:
    from .config import Settings

    run = Runtime.build(Settings())  # type: ignore[call-arg]
    stop = asyncio.Event()
    loop = asyncio.get_running_loop()
    for sig in (signal.SIGTERM, signal.SIGINT):
        loop.add_signal_handler(sig, stop.set)
    log.warning("worker started")
    try:
        await work(run, stop)
    finally:
        await run.engine.dispose()


if __name__ == "__main__":
    logging.basicConfig(level=logging.INFO)
    asyncio.run(main())
