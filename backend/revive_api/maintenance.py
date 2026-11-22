"""Housekeeping that must happen even if a request could not finish it: removing stored audio that
nothing refers to any more, and dropping uploads that were never finished.

Requests that delete audio drain their own rows right after the response; anything left (the
store was down) is retried here. The worker runs this every 10 minutes (worker.py); it can also be
run by hand:

    python -m revive_api.maintenance

"""

import asyncio
import logging
from datetime import datetime, timedelta

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from .models import ObjectDeletion, Recording
from .runtime import Runtime

log = logging.getLogger("revive_api")


async def drain_deletions(run: Runtime, limit: int = 200) -> int:
    """Removes up to `limit` queued objects; returns how many went. Failures stay queued with the
    error and an attempt count. Rows are locked one at a time with SKIP LOCKED, so several
    drainers (a request's own and cron's) never work on the same row."""
    removed = 0
    for _ in range(limit):
        async with run.sessions() as db, db.begin():
            row = await db.scalar(
                select(ObjectDeletion)
                .order_by(ObjectDeletion.attempts, ObjectDeletion.created_at)
                .limit(1)
                # Rows that keep failing go to the back.
                .with_for_update(skip_locked=True)
            )
            if row is None:
                break
            try:
                if row.upload_id:
                    await run.store.abort_upload(row.object_key, row.upload_id)
                else:
                    await run.store.delete(row.object_key)
            except Exception as error:  # noqa: BLE001 - any failure is retried later
                log.warning("could not remove %s: %s", row.object_key, error)
                row.attempts += 1
                row.last_error = str(error)[:500]
                # Leave the rest for the next run rather than hammering a store that is down.
                return removed
            await db.delete(row)
            removed += 1
    return removed


async def sweep_stale_uploads(run: Runtime) -> int:
    """Queues for removal every upload unfinished after `stale_upload_days`; the app starts a new
    one if it still has the audio. Returns how many were dropped."""
    now = run.clock.now()
    cutoff = now - timedelta(days=run.settings.stale_upload_days)
    async with run.sessions() as db, db.begin():
        stale = (
            await db.scalars(
                select(Recording)
                .where(
                    Recording.upload_id.is_not(None),
                    Recording.uploaded_at.is_(None),
                    Recording.updated_at < cutoff,
                )
                .with_for_update(skip_locked=True)
            )
        ).all()
        for recording in stale:
            queue_deletion(db, recording, now)
            recording.upload_id = None
            recording.updated_at = now
    return len(stale)


def queue_deletion(db: AsyncSession, recording: Recording, now: datetime) -> bool:
    """Queues the recording's stored audio, or its unfinished upload, for removal in the caller's
    transaction. False when there is nothing to remove. Every upload gets a fresh object key
    (routers/recordings.py), so a queued removal can never hit audio uploaded after it."""
    if recording.audio_object_key is None:
        return False
    if recording.uploaded_at is not None:
        db.add(ObjectDeletion(object_key=recording.audio_object_key, created_at=now))
    elif recording.upload_id is not None:
        db.add(ObjectDeletion(object_key=recording.audio_object_key, upload_id=recording.upload_id, created_at=now))
    else:
        return False
    return True


async def main() -> None:
    from .config import Settings

    run = Runtime.build(Settings())  # type: ignore[call-arg]
    try:
        dropped = await sweep_stale_uploads(run)
        removed = await drain_deletions(run, limit=10_000)
        log.warning("dropped %d stale uploads, removed %d objects", dropped, removed)
    finally:
        await run.engine.dispose()


if __name__ == "__main__":
    logging.basicConfig(level=logging.INFO)
    asyncio.run(main())
