"""Database access used by SyncService; no policy decisions live here."""
from __future__ import annotations

from typing import Any
from uuid import UUID

from datetime import UTC, datetime, timedelta

from sqlalchemy import delete, func, select, text
from sqlalchemy.dialects.postgresql import insert as pg_insert
from sqlalchemy.ext.asyncio import AsyncSession

from ..models.entities import Device, ProcessedMutation, SyncChange, SyncHead


class SyncRepository:
    def __init__(self, session: AsyncSession) -> None:
        self.session = session

    async def processed(self, mutation_id: UUID) -> ProcessedMutation | None:
        return await self.session.scalar(select(ProcessedMutation).where(ProcessedMutation.mutation_id == mutation_id))

    async def lock_mutation(self, mutation_id: UUID) -> None:
        """Serialize concurrent retries of one idempotency key in PostgreSQL.

        This is transaction-scoped and survives process restarts. It prevents a
        second request from observing a missing ProcessedMutation while the
        first request has already written its business row/change but not yet
        committed.
        """
        await self.session.execute(text(
            "SELECT pg_advisory_xact_lock(hashtextextended(CAST(:mutation_id AS text), 0))"
        ), {"mutation_id": str(mutation_id)})

    async def save_processed(self, mutation_id: UUID, device_id: UUID, result: dict[str, Any]) -> None:
        self.session.add(ProcessedMutation(mutation_id=mutation_id, device_id=device_id, result_json=result))

    async def append_change(self, entity_type: str, entity_id: UUID, operation: str, version: int,
                            payload: dict[str, Any] | None, *, source_mutation_id: UUID | None = None,
                            source_device_id: UUID | None = None) -> SyncChange:
        """Append under the sync-head lock so seq order equals commit order.

        This runs inside the request transaction. PostgreSQL retains the row
        lock until that transaction commits, so a later committed change can
        never be assigned a cursor before an earlier uncommitted one.
        """
        await self._ensure_head()
        head = await self.session.scalar(select(SyncHead).where(SyncHead.id == 1).with_for_update())
        if head is None:  # Defensive: `_ensure_head` is idempotent.
            raise RuntimeError("sync head is unavailable")
        next_seq = head.committed_seq + 1
        change = SyncChange(
            seq=next_seq, entity_type=entity_type, entity_id=entity_id,
            operation=operation, version=version, payload=payload,
            source_mutation_id=source_mutation_id, source_device_id=source_device_id,
        )
        self.session.add(change)
        head.committed_seq = next_seq
        await self.session.flush()
        return change

    async def latest_cursor(self) -> int:
        return int((await self.session.scalar(select(SyncHead.committed_seq).where(SyncHead.id == 1))) or 0)

    async def earliest_cursor(self) -> int | None:
        return await self.session.scalar(select(func.min(SyncChange.seq)))

    async def changes_after(self, after: int, limit: int) -> list[SyncChange]:
        return list((await self.session.scalars(select(SyncChange).where(SyncChange.seq > after).order_by(SyncChange.seq).limit(limit + 1))).all())

    async def acknowledge_cursor(self, device_id: UUID, cursor: int) -> None:
        device = await self.session.get(Device, device_id)
        if device is None:
            raise RuntimeError("synchronizing device disappeared")
        if cursor > device.last_acked_sync_seq:
            device.last_acked_sync_seq = cursor
            # The session deliberately has autoflush disabled. Retention reads
            # all device acknowledgements immediately afterwards, so persist
            # this monotonically advancing acknowledgement before that query.
            await self.session.flush()

    async def prune_retained_changes(self, retention_days: int, now: datetime | None = None) -> int:
        """Safely remove only changes acknowledged by every active device.

        A retention period is not allowed to evict a change that a non-revoked
        device has not acknowledged. Cursor expiry remains detectable while at
        least one retained row exists; when no row is eligible this is a no-op.
        """
        if retention_days <= 0:
            return 0
        active_acks = list((await self.session.scalars(
            select(Device.last_acked_sync_seq).where(Device.revoked_at.is_(None))
        )).all())
        if not active_acks:
            return 0
        acknowledged_through = min(active_acks)
        if acknowledged_through <= 0:
            return 0
        cutoff = (now or datetime.now(UTC)) - timedelta(days=retention_days)
        result = await self.session.execute(
            delete(SyncChange).where(
                SyncChange.seq <= acknowledged_through,
                SyncChange.updated_at < cutoff,
            )
        )
        return max(0, int(result.rowcount or 0))

    async def _ensure_head(self) -> None:
        # The unique singleton key makes concurrent first writes harmless;
        # PostgreSQL's ON CONFLICT avoids a race without committing early.
        statement = pg_insert(SyncHead).values(id=1, committed_seq=0).on_conflict_do_nothing(index_elements=[SyncHead.id])
        await self.session.execute(statement)
