"""One-shot operational commands; never invoked by normal API requests."""
from __future__ import annotations

import argparse
import asyncio
from datetime import UTC, datetime
import sys

from .config import Settings
from .db import make_session_factory
from .errors import MediaUnavailableError
from .services.media_service import MediaService, build_media_storage
from .repositories.sync import SyncRepository
from .services.sync_service import SyncService


async def cleanup_media() -> int:
    """Run existing MediaService cleanup routines in one maintenance session."""
    settings = Settings.from_environment()
    if settings.media_backend == "unconfigured":
        print("Media cleanup skipped: private object storage is unconfigured.")
        return 0

    factory = make_session_factory(settings)
    try:
        async with factory() as session:
            try:
                service = MediaService(session, settings, build_media_storage(settings))
                now = datetime.now(UTC)
                expired = await service.cleanup_expired_uploads(now)
                orphans = await service.cleanup_orphan_objects(now)
                missing = await service.reconcile_ready_objects()
                await session.commit()
            except Exception:
                await session.rollback()
                raise
    except MediaUnavailableError:
        print("Media cleanup failed: private object storage is unavailable.", file=sys.stderr)
        return 2
    except Exception:
        # Provider/database details can include sensitive endpoints or object
        # metadata, so the timer emits only a safe failure summary.
        print("Media cleanup failed; inspect privileged container logs.", file=sys.stderr)
        return 1

    print(
        "Media cleanup complete: "
        f"expired_pending={len(expired)} orphan_objects={len(orphans)} missing_ready={len(missing)}"
    )
    return 0


async def cleanup_data_retention() -> int:
    """One-shot, explicit maintenance; never started by a normal API request."""
    settings = Settings.from_environment()
    factory = make_session_factory(settings)
    try:
        async with factory() as session:
            purged = 0
            while True:
                async with session.begin():
                    processed = await SyncService(session, settings).expire_deleted_content(datetime.now(UTC))
                purged += processed
                if processed == 0:
                    break
            async with session.begin():
                locations, changes = await SyncRepository(session).prune_expired_history(datetime.now(UTC))
    except Exception:
        print("Data retention failed; inspect privileged container logs.", file=sys.stderr)
        return 1
    print(f"Data retention complete: purged_content={purged} old_locations={locations} expired_changes={changes}")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description="FamilyApp one-shot maintenance")
    parser.add_argument("command", choices=("media-cleanup", "data-retention"))
    args = parser.parse_args()
    if args.command == "media-cleanup":
        return asyncio.run(cleanup_media())
    if args.command == "data-retention":
        return asyncio.run(cleanup_data_retention())
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
