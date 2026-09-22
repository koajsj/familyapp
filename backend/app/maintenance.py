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


def main() -> int:
    parser = argparse.ArgumentParser(description="FamilyApp one-shot maintenance")
    parser.add_argument("command", choices=("media-cleanup",))
    args = parser.parse_args()
    if args.command == "media-cleanup":
        return asyncio.run(cleanup_media())
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
