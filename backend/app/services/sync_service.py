"""Idempotent push, cursor pull and bootstrap for a future local-first client.

The service accepts mutations only after the client has committed locally. It
never implements last-write-wins for versioned entities.
"""
from __future__ import annotations

from datetime import UTC, date, datetime, timedelta
import json
from typing import Any, Callable
from uuid import UUID

from sqlalchemy import exists, select
from sqlalchemy.ext.asyncio import AsyncSession

from ..config import Settings
from ..errors import ConflictError, ForbiddenError, NotFoundError, ValidationError
from ..member_identity import FAMILY_CHAT_ID, member_status_id
from ..models import entities as models
from ..repositories.sync import SyncRepository
from ..schemas.contracts import ImportBatchRollbackOut, MutationAck, MutationConflict, MutationIn, SyncChangeOut
from .media_service import CHAT_FILE_MIME_BY_EXTENSION


VERSIONED_TYPES: dict[str, type[models.Base]] = {
    "member": models.Member, "memberStatus": models.MemberStatus, "semester": models.Semester,
    "schedule": models.Schedule, "scheduleException": models.ScheduleException,
    "calendarOverride": models.CalendarOverride, "importBatch": models.ImportBatch,
    "agenda": models.Agenda, "agendaException": models.AgendaException,
    "memo": models.Memo, "notice": models.Notice, "memberPlace": models.MemberPlace,
    "mediaAsset": models.MediaAsset, "message": models.Message,
    "messageReceipt": models.MessageReceipt, "noticeRead": models.NoticeRead,
    "foodRead": models.FoodRead, "agendaParticipant": models.AgendaParticipant,
    "importBatchItem": models.ImportBatchItem, "geofenceEvent": models.GeofenceEvent,
}
APPEND_ONLY_TYPES: dict[str, type[models.Base]] = {
    "locationSnapshot": models.LocationSnapshot,
}
ALL_TYPES = VERSIONED_TYPES | APPEND_ONLY_TYPES
RECOVERABLE_TYPES: dict[str, type[models.Base]] = {
    "message": models.Message, "memo": models.Memo,
    "notice": models.Notice, "agenda": models.Agenda,
}

_DATE_FIELDS = {"week1_start", "week1_end", "occurrence_date", "date"}
_DATETIME_FIELDS = {"start_at", "end_at", "due_at", "estimated_arrival", "captured_at", "sent_at", "recalled_at", "read_at", "delivered_at", "occurred_at", "finalized_at", "expires_at"}


class SyncService:
    def __init__(self, session: AsyncSession, settings: Settings) -> None:
        self.session = session
        self.settings = settings
        self.repository = SyncRepository(session)

    async def push(self, actor_id: UUID, device_id: UUID, mutations: list[MutationIn]) -> tuple[list[MutationAck], list[MutationConflict], int]:
        applied: list[MutationAck] = []
        conflicts: list[MutationConflict] = []
        seen_mutation_ids: set[UUID] = set()
        for mutation in mutations:
            if mutation.mutation_id in seen_mutation_ids:
                raise ValidationError("duplicate mutation_id in one push")
            seen_mutation_ids.add(mutation.mutation_id)
            await self.repository.lock_mutation(mutation.mutation_id)
            duplicate = await self.repository.processed(mutation.mutation_id)
            if duplicate is not None:
                applied.append(MutationAck.model_validate({**duplicate.result_json, "duplicate": True}))
                continue
            try:
                # A conflict for one mutation must not leak ORM changes into a
                # later mutation in the same push. The savepoint rolls back
                # every flush/change/processed-mutation write for that item.
                async with self.session.begin_nested():
                    ack = await self._apply(actor_id, device_id, mutation)
                    await self.repository.save_processed(mutation.mutation_id, device_id, ack.model_dump(mode="json"))
                    await self.session.flush()
            except ConflictError as error:
                conflicts.append(MutationConflict(mutation_id=mutation.mutation_id, entity_type=mutation.entity_type, entity_id=mutation.entity_id, code=error.args[0], current_version=int(error.args[1]), current_payload=error.args[2] if len(error.args) > 2 else None))
                continue
            applied.append(ack)
        return applied, conflicts, await self.repository.latest_cursor()

    async def deleted_items(
        self, actor_id: UUID, entity_type: str, *, after_id: UUID | None = None, limit: int = 100
    ) -> list[dict[str, Any]]:
        """A separate, owner-scoped recycle query; normal queries stay active-only."""
        model = RECOVERABLE_TYPES.get(entity_type)
        if model is None:
            raise ValidationError("entity type does not support recycle")
        cutoff = datetime.now(UTC) - timedelta(days=30)
        owner_column = {
            "message": models.Message.sender_id,
            "memo": models.Memo.creator_id,
            "notice": models.Notice.publisher_id,
            "agenda": models.Agenda.creator_id,
        }[entity_type]
        statement = select(model).where(
            model.deleted_at.is_not(None), model.deleted_at >= cutoff,
            model.purged_at.is_(None), owner_column == actor_id,
        ).order_by(model.id).limit(limit)
        if after_id is not None:
            statement = statement.where(model.id > after_id)
        result = []
        for record in (await self.session.scalars(statement)).all():
            try:
                await self._authorize_existing(entity_type, actor_id, record, "delete")
            except ForbiddenError:
                continue
            result.append(self._serialize(record))
        return result

    async def change_deleted_item(
        self, actor_id: UUID, device_id: UUID, entity_type: str, entity_id: UUID,
        mutation_id: UUID, expected_version: int, *, permanent: bool,
    ) -> MutationAck:
        """Restore an original row or erase its content, never clone an ID.

        The caller commits this request transaction after all child changes,
        the parent change, and the idempotency result are written. A stale
        version or expired recycle window fails before any ORM mutation.
        """
        model = RECOVERABLE_TYPES.get(entity_type)
        if model is None:
            raise ValidationError("entity type does not support recycle")
        await self.repository.lock_mutation(mutation_id)
        duplicate = await self.repository.processed(mutation_id)
        if duplicate is not None:
            result = MutationAck.model_validate(duplicate.result_json)
            if result.entity_type != entity_type or result.entity_id != entity_id or result.operation != ("delete" if permanent else "upsert"):
                raise ConflictError("version_conflict", result.version, None)
            return result.model_copy(update={"duplicate": True})
        async with self.session.begin_nested():
            record = await self.session.scalar(select(model).where(model.id == entity_id).with_for_update())
            if record is None or record.deleted_at is None or record.purged_at is not None:
                raise ConflictError("tombstone_conflict", getattr(record, "version", 0), None)
            if record.version != expected_version:
                raise ConflictError("version_conflict", record.version, None)
            await self._authorize_existing(entity_type, actor_id, record, "delete")
            if record.deleted_at < datetime.now(UTC) - timedelta(days=30) and not permanent:
                raise ConflictError("tombstone_conflict", record.version, None)
            if permanent:
                await self._purge_content(record, entity_type)
                record.purged_at = datetime.now(UTC)
                operation = "delete"
                payload = None
            else:
                if entity_type == "message" and record.media_id is not None:
                    asset = await self.session.get(models.MediaAsset, record.media_id)
                    if asset is None or asset.deleted_at is not None or asset.status != "ready":
                        raise ConflictError("tombstone_conflict", record.version, None)
                await self._restore_dependents(record, entity_type)
                record.deleted_at = None
                operation = "upsert"
                payload = self._serialize(record)
                payload["deleted_at"] = None
            record.version += 1
            await self.session.flush()
            if payload is not None:
                payload["version"] = record.version
            change = await self.repository.append_change(
                entity_type, entity_id, operation, record.version, payload,
                source_mutation_id=mutation_id, source_device_id=device_id,
            )
            if permanent:
                # Earlier create/update changes may contain the erased body.
                # Evicting the complete prior prefix forces stale devices to
                # bootstrap instead of leaking content or skipping seq holes.
                await self.repository.discard_prefix_before(change.seq)
            ack = MutationAck(
                mutation_id=mutation_id, entity_type=entity_type, entity_id=entity_id,
                operation=operation, version=record.version, seq=change.seq,
            )
            await self.repository.save_processed(mutation_id, device_id, ack.model_dump(mode="json"))
            await self.session.flush()
            return ack

    async def _restore_dependents(self, record: models.Base, entity_type: str) -> None:
        relations = {
            "message": (("messageReceipt", models.MessageReceipt, models.MessageReceipt.message_id),),
            "notice": (("noticeRead", models.NoticeRead, models.NoticeRead.notice_id),),
            "agenda": (
                ("agendaException", models.AgendaException, models.AgendaException.agenda_id),
                ("agendaParticipant", models.AgendaParticipant, models.AgendaParticipant.agenda_id),
                ("foodRead", models.FoodRead, models.FoodRead.agenda_id),
            ),
        }.get(entity_type, ())
        prepared: list[tuple[str, models.Base]] = []
        for child_type, child_model, parent_column in relations:
            children = (await self.session.scalars(select(child_model).where(
                parent_column == record.id,
            ).order_by(child_model.id).with_for_update())).all()
            for child in children:
                if child.deleted_at is not None and child.deleted_at > record.deleted_at:
                    # Legacy cascades used independently sampled timestamps.
                    # Their full original relationship cannot be proven, so
                    # fail closed rather than restoring a partial parent.
                    raise ConflictError("tombstone_conflict", record.version, None)
                if child.deleted_at == record.deleted_at:
                    prepared.append((child_type, child))
        for child_type, child in prepared:
            child.deleted_at = None
            child.version += 1
            await self.session.flush()
            await self.repository.append_change(
                child_type, child.id, "upsert", child.version, self._serialize(child)
            )

    async def _purge_content(self, record: models.Base, entity_type: str) -> None:
        if entity_type == "message":
            if record.media_id is not None:
                other = await self.session.scalar(select(models.Message.id).where(
                    models.Message.media_id == record.media_id,
                    models.Message.id != record.id,
                ).limit(1))
                if other is None:
                    asset = await self.session.scalar(select(models.MediaAsset).where(
                        models.MediaAsset.id == record.media_id,
                    ).with_for_update())
                    if asset is not None and asset.deleted_at is None:
                        asset.deleted_at = datetime.now(UTC)
                        asset.version += 1
                        await self.session.flush()
                        await self.repository.append_change("mediaAsset", asset.id, "delete", asset.version, None)
            record.body = None
            record.media_id = None
            record.kind = "recalled"
            record.recalled_at = record.recalled_at or datetime.now(UTC)
        elif entity_type == "memo":
            record.title = None
            record.content = ""
        elif entity_type == "notice":
            record.title = ""
            record.content = ""
        elif entity_type == "agenda":
            record.title = ""
            record.detail_json = {}
            record.recurrence_rule = None
            record.start_at = record.end_at = record.due_at = None
            children = (await self.session.scalars(select(models.AgendaException).where(
                models.AgendaException.agenda_id == record.id,
            ).with_for_update())).all()
            for child in children:
                child.replacement_json = None

    async def expire_deleted_content(self, now: datetime, *, batch_size: int = 100) -> int:
        """Purge expired recycle contents, retaining their versioned tombstones.

        Invoked only by the existing maintenance entrypoint. Each call is a
        bounded database transaction, and the caller may repeat until empty.
        """
        cutoff = now - timedelta(days=30)
        count = 0
        for entity_type, model in RECOVERABLE_TYPES.items():
            records = (await self.session.scalars(select(model).where(
                model.deleted_at < cutoff, model.purged_at.is_(None),
            ).order_by(model.id).limit(batch_size).with_for_update(skip_locked=True))).all()
            for record in records:
                await self._purge_content(record, entity_type)
                record.purged_at = now
                record.version += 1
                await self.session.flush()
                await self.repository.append_change(
                    entity_type, record.id, "delete", record.version, None
                )
                count += 1
        return count

    async def rollback_import_batch(
        self, actor_id: UUID, device_id: UUID, batch_id: UUID, mutation_id: UUID, expected_version: int
    ) -> ImportBatchRollbackOut:
        """Authoritatively undo one imported batch or fail without changing it.

        The client deliberately does not send per-course restore instructions.
        This service uses the server-sealed ImportBatchItem snapshot, schedule
        version and canonical post-import fingerprint while all rows are locked
        in one transaction/savepoint. A repeated request returns its recorded
        result instead of applying a second rollback.
        """
        await self.repository.lock_mutation(mutation_id)
        duplicate = await self.repository.processed(mutation_id)
        if duplicate is not None:
            result = ImportBatchRollbackOut.model_validate(duplicate.result_json)
            return result.model_copy(update={"duplicate": True})

        async with self.session.begin_nested():
            batch = await self.session.scalar(
                select(models.ImportBatch).where(models.ImportBatch.id == batch_id).with_for_update()
            )
            if batch is None or batch.deleted_at is not None:
                raise ConflictError("import_batch_rollback_conflict", 0, None)
            if batch.owner_id != actor_id:
                raise ForbiddenError("import batch owner permission required")
            if batch.version != expected_version:
                raise ConflictError("import_batch_rollback_conflict", batch.version, self._serialize(batch))

            items = list((await self.session.scalars(
                select(models.ImportBatchItem)
                .where(models.ImportBatchItem.batch_id == batch.id, models.ImportBatchItem.deleted_at.is_(None))
                .order_by(models.ImportBatchItem.id)
                .with_for_update()
            )).all())
            if not items:
                raise ConflictError("import_batch_rollback_conflict", batch.version, self._serialize(batch))

            prepared: list[tuple[models.ImportBatchItem, models.Schedule, dict[str, Any] | None]] = []
            for item in items:
                schedule = await self.session.scalar(
                    select(models.Schedule).where(models.Schedule.id == item.schedule_id).with_for_update()
                )
                if schedule is None or schedule.deleted_at is not None:
                    raise ConflictError("import_batch_rollback_conflict", batch.version, self._serialize(batch))
                sealed = item.before_snapshot
                if not isinstance(sealed, dict) or "after_version" not in sealed or "restore" not in sealed:
                    # Historic rows were not written with an authoritative
                    # post-import version. Guessing here could erase a later
                    # same-value manual edit, so old batches remain fail-closed.
                    raise ConflictError("import_batch_rollback_conflict", batch.version, self._serialize(batch))
                after_version = sealed.get("after_version")
                restore = sealed.get("restore")
                if not isinstance(after_version, int) or schedule.version != after_version:
                    raise ConflictError("import_batch_rollback_conflict", schedule.version, self._serialize(schedule))
                if self._schedule_fingerprint(schedule) != item.after_fingerprint:
                    raise ConflictError("import_batch_rollback_conflict", schedule.version, self._serialize(schedule))
                if item.operation == "updated":
                    if not isinstance(restore, dict):
                        raise ConflictError("import_batch_rollback_conflict", schedule.version, self._serialize(schedule))
                    values = self._payload(models.Schedule, restore)
                    self._protect_immutable_update("schedule", actor_id, schedule, values)
                    await self._validate_record("schedule", schedule, overrides=values)
                    prepared.append((item, schedule, values))
                elif item.operation == "created":
                    if restore is not None:
                        raise ConflictError("import_batch_rollback_conflict", schedule.version, self._serialize(schedule))
                    exceptions = await self.session.scalar(select(models.ScheduleException.id).where(
                        models.ScheduleException.schedule_id == schedule.id,
                        models.ScheduleException.deleted_at.is_(None),
                    ).limit(1))
                    if exceptions is not None:
                        # Import never creates exceptions. An active child is a
                        # later edit and must not be silently deleted.
                        raise ConflictError("import_batch_rollback_conflict", schedule.version, self._serialize(schedule))
                    prepared.append((item, schedule, None))
                else:
                    raise ConflictError("import_batch_rollback_conflict", batch.version, self._serialize(batch))

            now = datetime.now(UTC)
            for item, schedule, restore in prepared:
                if restore is None:
                    schedule.deleted_at = now
                    schedule.version += 1
                    await self.session.flush()
                    await self.repository.append_change("schedule", schedule.id, "delete", schedule.version, None)
                else:
                    for key, value in restore.items():
                        setattr(schedule, key, value)
                    schedule.version += 1
                    await self.session.flush()
                    await self.repository.append_change("schedule", schedule.id, "update", schedule.version, self._serialize(schedule))
                item.deleted_at = now
                item.version += 1
                await self.session.flush()
                await self.repository.append_change("importBatchItem", item.id, "delete", item.version, None)

            batch.deleted_at = now
            batch.version += 1
            await self.session.flush()
            final_change = await self.repository.append_change(
                "importBatch", batch.id, "delete", batch.version, None,
                source_mutation_id=mutation_id, source_device_id=device_id,
            )
            result = ImportBatchRollbackOut(
                mutation_id=mutation_id, batch_id=batch.id, version=batch.version,
                latest_cursor=final_change.seq,
            )
            await self.repository.save_processed(mutation_id, device_id, result.model_dump(mode="json"))
            await self.session.flush()
            return result

    @staticmethod
    def _schedule_fingerprint(record: models.Schedule) -> str:
        """Match iOS `RemoteBusinessPayload.scheduleFingerprint` exactly."""
        payload = {
            "owner_id": str(record.owner_id), "semester_id": str(record.semester_id),
            "kind": record.kind, "title": record.title, "weekday": record.weekday,
            "start_minutes": record.start_minutes, "end_minutes": record.end_minutes,
            "start_week": record.start_week, "end_week": record.end_week,
            "week_type": record.week_type, "metadata_json": record.metadata_json or {},
        }
        return json.dumps(payload, sort_keys=True, separators=(",", ":"), ensure_ascii=False)

    async def _seal_import_batch_item(self, record: models.Base) -> None:
        """Bind a rollback item to the server's exact post-import version."""
        if not isinstance(record, models.ImportBatchItem):
            raise ValidationError("import batch item is invalid")
        schedule = await self._active_schedule(record.schedule_id)
        restore = record.before_snapshot
        if restore is not None and not isinstance(restore, dict):
            raise ValidationError("import batch restore snapshot is invalid")
        record.before_snapshot = {"restore": restore, "after_version": schedule.version}
        record.after_fingerprint = self._schedule_fingerprint(schedule)

    async def pull(self, after: int, limit: int, device_id: UUID) -> tuple[list[SyncChangeOut], int, bool]:
        if after < 0:
            raise ValidationError("cursor must be non-negative")
        latest = await self.repository.latest_cursor()
        if after > latest:
            raise ConflictError("invalid_sync_cursor", latest, None)
        earliest = await self.repository.earliest_cursor()
        if earliest is None:
            if after != latest:
                raise ConflictError("sync_cursor_expired", latest, None)
        elif after < earliest - 1:
            raise ConflictError("sync_cursor_expired", earliest, None)

        # The supplied cursor is an acknowledgement of all preceding changes.
        # Retention can now safely consider it, but only after every active
        # device has acknowledged the same sequence.
        await self.repository.acknowledge_cursor(device_id, after)
        await self.repository.prune_retained_changes(self.settings.sync_retention_days)

        values = await self.repository.changes_after(after, limit)
        has_more = len(values) > limit
        values = values[:limit]
        latest = await self.repository.latest_cursor()
        return [self._change_out(value) for value in values], latest, has_more

    async def bootstrap(self) -> tuple[dict[str, list[dict[str, Any]]], int]:
        # The router opens this service on a dedicated REPEATABLE READ session.
        # Thus the watermark and entity rows below share one PostgreSQL view;
        # writes committed later are fetched by pull(after: snapshot_cursor).
        snapshot_cursor = await self.repository.latest_cursor()
        snapshots: dict[str, list[dict[str, Any]]] = {}
        for name, model in ALL_TYPES.items():
            statement = self._active_snapshot_statement(name, model)
            snapshots[name] = [self._serialize(item) for item in (await self.session.scalars(statement)).all()]
        return snapshots, snapshot_cursor

    @staticmethod
    def _active_snapshot_statement(entity_type: str, model: type[models.Base]):
        """Return only records whose complete soft-delete ancestry is active."""
        statement = select(model)
        if entity_type in VERSIONED_TYPES and entity_type != "member":
            statement = statement.where(model.deleted_at.is_(None))  # type: ignore[attr-defined]
        if entity_type == "mediaAsset":
            # Upload grants have no shared meaning until object verification
            # succeeds. New devices receive metadata, not file bytes or URLs.
            return statement.where(
                models.MediaAsset.finalized_at.is_not(None),
            )
        if entity_type == "schedule":
            return statement.where(exists(select(1).where(
                models.Semester.id == models.Schedule.semester_id,
                models.Semester.deleted_at.is_(None),
            )))
        if entity_type == "scheduleException":
            return statement.where(
                exists(select(1).where(
                    models.Schedule.id == models.ScheduleException.schedule_id,
                    models.Schedule.deleted_at.is_(None),
                    exists(select(1).where(
                        models.Semester.id == models.Schedule.semester_id,
                        models.Semester.deleted_at.is_(None),
                    )),
                ))
            )
        if entity_type == "calendarOverride":
            return statement.where(exists(select(1).where(
                models.Semester.id == models.CalendarOverride.semester_id,
                models.Semester.deleted_at.is_(None),
            )))
        if entity_type == "importBatch":
            return statement.where(exists(select(1).where(
                models.Semester.id == models.ImportBatch.semester_id,
                models.Semester.deleted_at.is_(None),
            )))
        if entity_type == "importBatchItem":
            return statement.where(
                exists(select(1).where(
                    models.ImportBatch.id == models.ImportBatchItem.batch_id,
                    models.ImportBatch.deleted_at.is_(None),
                    exists(select(1).where(
                        models.Semester.id == models.ImportBatch.semester_id,
                        models.Semester.deleted_at.is_(None),
                    )),
                )),
                exists(select(1).where(
                    models.Schedule.id == models.ImportBatchItem.schedule_id,
                    models.Schedule.deleted_at.is_(None),
                    exists(select(1).where(
                        models.Semester.id == models.Schedule.semester_id,
                        models.Semester.deleted_at.is_(None),
                    )),
                )),
            )
        if entity_type in {"agendaException", "agendaParticipant", "foodRead"}:
            relation = {
                "agendaException": models.AgendaException.agenda_id,
                "agendaParticipant": models.AgendaParticipant.agenda_id,
                "foodRead": models.FoodRead.agenda_id,
            }[entity_type]
            clauses = [exists(select(1).where(
                models.Agenda.id == relation,
                models.Agenda.deleted_at.is_(None),
            ))]
            if entity_type == "foodRead":
                clauses.append(exists(select(1).where(
                    models.AgendaParticipant.agenda_id == models.FoodRead.agenda_id,
                    models.AgendaParticipant.member_id == models.FoodRead.member_id,
                    models.AgendaParticipant.deleted_at.is_(None),
                )))
            return statement.where(*clauses)
        if entity_type == "noticeRead":
            return statement.where(exists(select(1).where(
                models.Notice.id == models.NoticeRead.notice_id,
                models.Notice.deleted_at.is_(None),
            )))
        if entity_type == "message":
            return statement.where(exists(select(1).where(
                models.Chat.id == models.Message.chat_id,
                models.Chat.deleted_at.is_(None),
            )))
        if entity_type == "messageReceipt":
            return statement.where(exists(select(1).where(
                models.Message.id == models.MessageReceipt.message_id,
                models.Message.deleted_at.is_(None),
                exists(select(1).where(
                    models.Chat.id == models.Message.chat_id,
                    models.Chat.deleted_at.is_(None),
                )),
            )))
        if entity_type == "geofenceEvent":
            return statement.where(exists(select(1).where(
                models.MemberPlace.id == models.GeofenceEvent.place_id,
                models.MemberPlace.deleted_at.is_(None),
            )))
        return statement

    async def _apply(self, actor_id: UUID, device_id: UUID, mutation: MutationIn) -> MutationAck:
        model = ALL_TYPES.get(mutation.entity_type)
        if model is None:
            raise ValidationError("unsupported entity type")
        # Version checks must observe the row after any concurrent writer has
        # committed. Without FOR UPDATE, two devices can both accept the same
        # base_version and the later flush silently overwrites the first.
        existing = await self.session.get(
            model, mutation.entity_id, with_for_update=True, populate_existing=True
        )
        if mutation.entity_type == "mediaAsset":
            # Object keys, finalization and checksums are issued by the media
            # endpoint after object-store verification. Letting generic sync
            # mutations create a ready asset would let a sender forge a
            # Message.media_id without a completed upload.
            raise ValidationError("media assets must use the media upload API")
        if mutation.entity_type == "importBatchItem" and existing is not None:
            # Rollback history is sealed at creation. Mutable restore payloads
            # would turn a later rollback into a client-controlled overwrite.
            raise ValidationError("import batch items are immutable")
        if mutation.entity_type == "member":
            # Member provisioning and removal remain explicit control-plane
            # operations. Sync may distribute members but never creates them.
            raise ValidationError("member mutations are not supported")
        if mutation.entity_type == "memberStatus" and mutation.entity_id != member_status_id(actor_id):
            raise ValidationError("member status must use the stable member status ID")
        if mutation.entity_type in APPEND_ONLY_TYPES:
            return await self._apply_append(actor_id, device_id, model, existing, mutation)
        return await self._apply_versioned(actor_id, device_id, model, existing, mutation)

    async def _apply_append(self, actor_id: UUID, device_id: UUID, model: type[models.Base], existing: models.Base | None, mutation: MutationIn) -> MutationAck:
        if existing is not None:
            # Same-mutation retries are resolved through ProcessedMutation.
            # A different mutation ID reusing an immutable entity ID must not
            # be treated as a successful no-op.
            raise ConflictError("version_conflict", 1, self._serialize(existing))
        if mutation.operation not in {"create", "upsert"}:
            raise ValidationError("append-only records can only be created")
        values = self._payload(model, mutation.payload)
        values["id"] = mutation.entity_id
        self._inject_actor_identity(mutation.entity_type, actor_id, values)
        await self._authorize_create(mutation.entity_type, actor_id, device_id, values)
        record = model(**values)
        await self._validate_record(mutation.entity_type, record)
        self.session.add(record)
        await self.session.flush()
        change = await self.repository.append_change(mutation.entity_type, mutation.entity_id, "create", 1, self._serialize(record), source_mutation_id=mutation.mutation_id, source_device_id=device_id)
        return MutationAck(mutation_id=mutation.mutation_id, entity_type=mutation.entity_type, entity_id=mutation.entity_id, operation="create", version=1, seq=change.seq)

    async def _apply_versioned(self, actor_id: UUID, device_id: UUID, model: type[models.Base], existing: models.Base | None, mutation: MutationIn) -> MutationAck:
        if existing is None:
            if mutation.operation not in {"create", "upsert"} or mutation.base_version not in {None, 0}:
                raise ConflictError("version_conflict", 0, None)
            values = self._payload(model, mutation.payload)
            values["id"] = mutation.entity_id
            self._inject_actor_identity(mutation.entity_type, actor_id, values)
            await self._authorize_create(mutation.entity_type, actor_id, device_id, values)
            record = model(**values)
            try:
                await self._validate_record(mutation.entity_type, record)
            except Exception:
                # The candidate has not been added to the session yet, so a
                # per-mutation conflict cannot leak into a later commit.
                raise
            self.session.add(record)
            await self.session.flush()
            if mutation.entity_type == "importBatchItem":
                await self._seal_import_batch_item(record)
                await self.session.flush()
            change = await self.repository.append_change(mutation.entity_type, record.id, "create", record.version, self._serialize(record), source_mutation_id=mutation.mutation_id, source_device_id=device_id)
            return MutationAck(mutation_id=mutation.mutation_id, entity_type=mutation.entity_type, entity_id=record.id, operation="create", version=record.version, seq=change.seq)
        record = existing
        deleted_at = getattr(record, "deleted_at")
        current_version = int(getattr(record, "version"))
        if deleted_at is not None:
            if mutation.entity_type == "agendaParticipant" and mutation.operation == "upsert" and mutation.base_version == current_version:
                values = self._payload(model, mutation.payload)
                self._protect_immutable_update(mutation.entity_type, actor_id, record, values)
                await self._authorize_existing(mutation.entity_type, actor_id, record, mutation.operation)
                record.deleted_at = None  # type: ignore[attr-defined]
                for key, value in values.items():
                    setattr(record, key, value)
                record.version = current_version + 1  # type: ignore[attr-defined]
                await self.session.flush()
                change = await self.repository.append_change(mutation.entity_type, mutation.entity_id, "upsert", record.version, self._serialize(record), source_mutation_id=mutation.mutation_id, source_device_id=device_id)  # type: ignore[attr-defined]
                return MutationAck(mutation_id=mutation.mutation_id, entity_type=mutation.entity_type, entity_id=mutation.entity_id, operation="upsert", version=record.version, seq=change.seq)  # type: ignore[attr-defined]
            raise ConflictError("tombstone_conflict", current_version, self._serialize(record))
        if mutation.base_version != current_version:
            raise ConflictError("version_conflict", current_version, self._serialize(record))
        await self._authorize_existing(mutation.entity_type, actor_id, record, mutation.operation)
        if mutation.operation == "delete":
            if mutation.payload:
                raise ValidationError("delete mutations must not include payload fields")
            deleted_at = datetime.now(UTC)
            record.deleted_at = deleted_at  # type: ignore[attr-defined]
            record.version = current_version + 1  # type: ignore[attr-defined]
            await self.session.flush()
            await self._soft_delete_dependents(record, mutation.entity_type, deleted_at)
            change = await self.repository.append_change(mutation.entity_type, mutation.entity_id, "delete", record.version, None, source_mutation_id=mutation.mutation_id, source_device_id=device_id)  # type: ignore[attr-defined]
            return MutationAck(mutation_id=mutation.mutation_id, entity_type=mutation.entity_type, entity_id=mutation.entity_id, operation="delete", version=record.version, seq=change.seq)  # type: ignore[attr-defined]
        if mutation.operation not in {"update", "upsert"}:
            raise ValidationError("invalid mutation operation")
        values = self._payload(model, mutation.payload)
        self._protect_immutable_update(mutation.entity_type, actor_id, record, values)
        # Validate a value-level candidate before writing to the managed ORM
        # instance. Validation queries must never cause an autoflush of an
        # invalid partial update.
        await self._validate_record(mutation.entity_type, record, overrides=values)
        for key, value in values.items():
            setattr(record, key, value)
        record.version = current_version + 1  # type: ignore[attr-defined]
        await self.session.flush()
        change = await self.repository.append_change(mutation.entity_type, mutation.entity_id, "update", record.version, self._serialize(record), source_mutation_id=mutation.mutation_id, source_device_id=device_id)  # type: ignore[attr-defined]
        return MutationAck(mutation_id=mutation.mutation_id, entity_type=mutation.entity_type, entity_id=mutation.entity_id, operation="update", version=record.version, seq=change.seq)  # type: ignore[attr-defined]

    def _payload(self, model: type[models.Base], source: dict[str, Any]) -> dict[str, Any]:
        allowed = {column.key for column in model.__table__.columns} - {"id", "version", "created_at", "updated_at", "deleted_at", "purged_at", "password_hash", "token_hash"}
        unknown = set(source) - allowed
        if unknown:
            raise ValidationError("mutation includes immutable or unknown fields")
        return {key: self._coerce(key, value) for key, value in source.items()}

    @staticmethod
    def _coerce(key: str, value: Any) -> Any:
        if value is None:
            return None
        if key == "id" or key.endswith("_id") or key in {"owner_id", "creator_id", "publisher_id", "member_id", "schedule_id", "agenda_id", "batch_id", "semester_id", "place_id"}:
            return UUID(str(value))
        if key in _DATE_FIELDS:
            return date.fromisoformat(str(value))
        if key in _DATETIME_FIELDS:
            parsed = datetime.fromisoformat(str(value).replace("Z", "+00:00"))
            if parsed.tzinfo is None:
                raise ValidationError("timestamps must include UTC offset")
            return parsed
        return value

    @staticmethod
    def _inject_actor_identity(entity_type: str, actor_id: UUID, values: dict[str, Any]) -> None:
        owner_field = {"schedule": "owner_id", "importBatch": "owner_id", "agenda": "creator_id", "memo": "creator_id", "notice": "publisher_id", "memberPlace": "member_id", "memberStatus": "member_id", "mediaAsset": "owner_id", "message": "sender_id", "locationSnapshot": "member_id", "messageReceipt": "member_id", "noticeRead": "member_id", "foodRead": "member_id", "geofenceEvent": "member_id"}.get(entity_type)
        if owner_field:
            supplied = values.get(owner_field)
            if supplied is not None and supplied != actor_id:
                raise ForbiddenError("actor cannot impersonate another member")
            values[owner_field] = actor_id
        if entity_type == "memo":
            values["updated_by"] = actor_id

    @staticmethod
    def _protect_immutable_update(
        entity_type: str, actor_id: UUID, record: models.Base, values: dict[str, Any]
    ) -> None:
        """Keep client payloads from changing identity or ownership in place."""
        immutable_fields = {
            "memberStatus": ("member_id",),
            "schedule": ("owner_id", "semester_id"),
            "scheduleException": ("schedule_id",),
            "calendarOverride": ("semester_id",),
            "importBatch": ("owner_id", "semester_id"),
            "importBatchItem": ("batch_id", "schedule_id"),
            "agenda": ("creator_id",),
            "agendaException": ("agenda_id",),
            "agendaParticipant": ("agenda_id", "member_id"),
            "foodRead": ("agenda_id", "member_id"),
            "memo": ("creator_id",),
            "notice": ("publisher_id",),
            "noticeRead": ("notice_id", "member_id"),
            "message": ("chat_id", "sender_id", "sent_at"),
            "messageReceipt": ("message_id", "member_id"),
            "memberPlace": ("member_id",),
            "mediaAsset": ("owner_id", "object_key"),
            "geofenceEvent": ("place_id", "member_id", "occurred_at"),
        }.get(entity_type, ())
        for field in immutable_fields:
            if field in values and values[field] != getattr(record, field):
                raise ValidationError("mutation cannot change a record identity or owner")
        if entity_type == "memo":
            values["updated_by"] = actor_id

    async def _authorize_create(
        self, entity_type: str, actor_id: UUID, device_id: UUID, values: dict[str, Any],
    ) -> None:
        if entity_type == "locationSnapshot" and values.get("source") == "automatic":
            source_device = await self.session.scalar(
                select(models.Device).where(
                    models.Device.id == device_id,
                    models.Device.member_id == actor_id,
                    models.Device.revoked_at.is_(None),
                    models.Device.is_location_source.is_(True),
                )
            )
            if source_device is None:
                raise ForbiddenError("automatic location requires the active source device")
        if entity_type in {"scheduleException", "agendaException", "agendaParticipant", "importBatchItem"}:
            parent_type, parent_field = (("schedule", "schedule_id") if entity_type == "scheduleException" else ("agenda", "agenda_id") if entity_type in {"agendaException", "agendaParticipant"} else ("importBatch", "batch_id"))
            parent = await self.session.get(VERSIONED_TYPES[parent_type], values.get(parent_field))
            if parent is None or parent.deleted_at is not None:  # type: ignore[attr-defined]
                raise NotFoundError("parent record not found")
            await self._authorize_existing(parent_type, actor_id, parent, "update")
            if entity_type == "importBatchItem":
                schedule = await self._active_schedule(values.get("schedule_id"))
                if schedule.semester_id != parent.semester_id:  # type: ignore[attr-defined]
                    raise ValidationError("import batch item must use the batch semester")
        if entity_type == "foodRead":
            participant = await self.session.scalar(
                select(models.AgendaParticipant)
                .join(models.Agenda, models.AgendaParticipant.agenda_id == models.Agenda.id)
                .where(
                    models.AgendaParticipant.agenda_id == values.get("agenda_id"),
                    models.AgendaParticipant.member_id == actor_id,
                    models.AgendaParticipant.deleted_at.is_(None),
                    models.Agenda.deleted_at.is_(None),
                )
            )
            if participant is None:
                raise ForbiddenError("only agenda participants may record food reads")
        if entity_type == "noticeRead":
            await self._active_record(models.Notice, values.get("notice_id"), "notice")
        if entity_type == "messageReceipt":
            await self._active_record(models.Message, values.get("message_id"), "message")
        if entity_type == "geofenceEvent":
            place = await self._active_record(models.MemberPlace, values.get("place_id"), "member place")
            if place.member_id != actor_id:  # type: ignore[attr-defined]
                raise ForbiddenError("member place ownership permission required")

    async def _active_record(self, model: type[models.Base], record_id: UUID | None, label: str) -> models.Base:
        if record_id is None:
            raise ValidationError(f"{label} ID is required")
        record = await self.session.get(model, record_id)
        if record is None or getattr(record, "deleted_at", None) is not None:
            raise NotFoundError(f"active {label} not found")
        return record

    async def _active_schedule(self, schedule_id: UUID | None) -> models.Schedule:
        schedule = await self._active_record(models.Schedule, schedule_id, "schedule")
        await self._active_record(models.Semester, schedule.semester_id, "semester")  # type: ignore[attr-defined]
        return schedule  # type: ignore[return-value]

    async def _authorize_existing(self, entity_type: str, actor_id: UUID, record: models.Base, operation: str) -> None:
        if entity_type == "scheduleException":
            schedule = await self.session.get(models.Schedule, record.schedule_id)  # type: ignore[attr-defined]
            if schedule is None or schedule.deleted_at is not None or schedule.owner_id != actor_id:
                raise ForbiddenError("schedule owner permission required")
            return
        if entity_type == "agendaException":
            agenda = await self.session.get(models.Agenda, record.agenda_id)  # type: ignore[attr-defined]
            if agenda is None or agenda.deleted_at is not None or agenda.creator_id != actor_id:
                raise ForbiddenError("agenda creator permission required")
            return
        if entity_type == "agendaParticipant":
            agenda = await self.session.get(models.Agenda, record.agenda_id)  # type: ignore[attr-defined]
            if agenda is None or agenda.deleted_at is not None or agenda.creator_id != actor_id:
                raise ForbiddenError("agenda creator permission required")
            return
        if entity_type == "importBatchItem":
            batch = await self.session.get(models.ImportBatch, record.batch_id)  # type: ignore[attr-defined]
            if batch is None or batch.deleted_at is not None or batch.owner_id != actor_id:
                raise ForbiddenError("import batch owner permission required")
            return
        if entity_type == "memo":
            if operation == "delete" and record.creator_id != actor_id:  # type: ignore[attr-defined]
                raise ForbiddenError("memo creator permission required")
            return
        field = {"schedule": "owner_id", "importBatch": "owner_id", "agenda": "creator_id", "notice": "publisher_id", "memberPlace": "member_id", "memberStatus": "member_id", "mediaAsset": "owner_id", "message": "sender_id", "locationSnapshot": "member_id", "messageReceipt": "member_id", "noticeRead": "member_id", "foodRead": "member_id", "geofenceEvent": "member_id"}.get(entity_type)
        if field and getattr(record, field) != actor_id:
            raise ForbiddenError("record ownership permission required")

    async def _soft_delete_dependents(self, record: models.Base, entity_type: str, deleted_at: datetime) -> None:
        """Emit tombstones for real children in the same transaction.

        Foreign-key cascades cannot represent a replicated deletion: a pull
        page needs an explicit change for each child so an older device never
        retains an active orphan. Induced changes intentionally have no source
        mutation ID because that ID is unique to the user's parent mutation.
        """
        children: list[tuple[str, models.Base]] = []

        async def collect(type_name: str, model: type[models.Base], column: object, parent_id: UUID) -> None:
            statement = select(model).where(column == parent_id, model.deleted_at.is_(None))  # type: ignore[attr-defined]
            children.extend((type_name, child) for child in (await self.session.scalars(statement)).all())

        if entity_type == "semester":
            await collect("schedule", models.Schedule, models.Schedule.semester_id, record.id)  # type: ignore[attr-defined]
            await collect("calendarOverride", models.CalendarOverride, models.CalendarOverride.semester_id, record.id)  # type: ignore[attr-defined]
            await collect("importBatch", models.ImportBatch, models.ImportBatch.semester_id, record.id)  # type: ignore[attr-defined]
        elif entity_type == "schedule":
            await collect("scheduleException", models.ScheduleException, models.ScheduleException.schedule_id, record.id)  # type: ignore[attr-defined]
            await collect("importBatchItem", models.ImportBatchItem, models.ImportBatchItem.schedule_id, record.id)  # type: ignore[attr-defined]
        elif entity_type == "importBatch":
            await collect("importBatchItem", models.ImportBatchItem, models.ImportBatchItem.batch_id, record.id)  # type: ignore[attr-defined]
        elif entity_type == "agenda":
            await collect("agendaException", models.AgendaException, models.AgendaException.agenda_id, record.id)  # type: ignore[attr-defined]
            await collect("agendaParticipant", models.AgendaParticipant, models.AgendaParticipant.agenda_id, record.id)  # type: ignore[attr-defined]
        elif entity_type == "agendaParticipant":
            statement = select(models.FoodRead).where(
                models.FoodRead.agenda_id == record.agenda_id,  # type: ignore[attr-defined]
                models.FoodRead.member_id == record.member_id,  # type: ignore[attr-defined]
                models.FoodRead.deleted_at.is_(None),
            )
            children.extend(("foodRead", child) for child in (await self.session.scalars(statement)).all())
        elif entity_type == "notice":
            await collect("noticeRead", models.NoticeRead, models.NoticeRead.notice_id, record.id)  # type: ignore[attr-defined]
        elif entity_type == "message":
            await collect("messageReceipt", models.MessageReceipt, models.MessageReceipt.message_id, record.id)  # type: ignore[attr-defined]
        elif entity_type == "memberPlace":
            await collect("geofenceEvent", models.GeofenceEvent, models.GeofenceEvent.place_id, record.id)  # type: ignore[attr-defined]

        for child_type, child in children:
            await self._soft_delete_dependents(child, child_type, deleted_at)
            child.deleted_at = deleted_at  # type: ignore[attr-defined]
            child.version += 1  # type: ignore[attr-defined]
            await self.session.flush()
            await self.repository.append_change(child_type, child.id, "delete", child.version, None)  # type: ignore[attr-defined]

    async def _validate_record(
        self,
        entity_type: str,
        record: models.Base,
        *,
        overrides: dict[str, Any] | None = None,
    ) -> None:
        def value(name: str) -> Any:
            return overrides[name] if overrides is not None and name in overrides else getattr(record, name)

        if entity_type == "schedule":
            semester = await self._active_record(models.Semester, value("semester_id"), "semester")
            weekday, start_minutes, end_minutes = value("weekday"), value("start_minutes"), value("end_minutes")
            start_week, end_week = value("start_week"), value("end_week")
            if not (1 <= weekday <= 7 and 0 <= start_minutes < end_minutes <= 1440):
                raise ValidationError("schedule weekday or time range is invalid")
            if not (1 <= start_week <= end_week <= semester.total_weeks):
                raise ValidationError("schedule weeks must fit the semester")
        if entity_type == "calendarOverride":
            await self._active_record(models.Semester, value("semester_id"), "semester")
            kind, mapped_weekday = value("kind"), value("mapped_weekday")
            if kind == "mappedWeekday" and mapped_weekday is None:
                raise ValidationError("mappedWeekday requires mapped_weekday")
            if kind != "mappedWeekday" and mapped_weekday is not None:
                raise ValidationError("mapped_weekday is only valid for mappedWeekday")
            if mapped_weekday is not None and not 1 <= mapped_weekday <= 7:
                raise ValidationError("mapped_weekday is invalid")
            duplicate = await self.session.scalar(select(models.CalendarOverride).where(
                models.CalendarOverride.semester_id == value("semester_id"),
                models.CalendarOverride.date == value("date"),
                models.CalendarOverride.id != record.id,
                models.CalendarOverride.deleted_at.is_(None),
            ))
            if duplicate is not None:
                raise ConflictError("version_conflict", duplicate.version, self._serialize(duplicate))
        if entity_type == "importBatch":
            await self._active_record(models.Semester, value("semester_id"), "semester")
        if entity_type == "scheduleException":
            await self._active_schedule(value("schedule_id"))
        if entity_type == "message":
            await self._validate_message_media(value)
        if entity_type == "locationSnapshot":
            accuracy, source = value("horizontal_accuracy"), value("source")
            if accuracy is not None and (not isinstance(accuracy, (int, float)) or accuracy < 0):
                raise ValidationError("horizontal_accuracy is invalid")
            if source is not None and source not in {"automatic", "manual"}:
                raise ValidationError("location source is invalid")
            captured_at = value("captured_at")
            if not isinstance(captured_at, datetime) or captured_at.tzinfo is None:
                raise ValidationError("location timestamp must be timezone aware")
            if captured_at < datetime.now(UTC) - timedelta(days=30):
                raise ValidationError("location snapshot is older than retention window")
        if entity_type == "memberPlace" and value("enabled") and value("type") in {"home", "school"}:
            duplicate = await self.session.scalar(select(models.MemberPlace).where(
                models.MemberPlace.member_id == value("member_id"),
                models.MemberPlace.type == value("type"),
                models.MemberPlace.id != record.id,  # type: ignore[attr-defined]
                models.MemberPlace.enabled.is_(True),
                models.MemberPlace.deleted_at.is_(None),
            ))
            if duplicate is not None:
                raise ConflictError("version_conflict", duplicate.version, self._serialize(duplicate))

    async def _validate_message_media(self, value: Callable[[str], Any]) -> None:
        """Keep a shared chat attachment bound to its real owner and parent.

        The fixed family chat is the only current chat model. A message may
        expose an object only after its sender's MediaAsset was finalized. A
        recalled message cannot retain an attachment that would continue to
        authorize other family members' short-lived download grants.
        """
        chat_id = value("chat_id")
        if chat_id != FAMILY_CHAT_ID:
            raise ValidationError("messages must target the fixed family chat")
        await self._active_record(models.Chat, chat_id, "family chat")

        kind = value("kind")
        media_id = value("media_id")
        recalled_at = value("recalled_at")
        if kind == "recalled":
            if media_id is not None or recalled_at is None:
                raise ValidationError("recalled messages must have a recall time and no media")
            return
        if recalled_at is not None:
            raise ValidationError("active messages cannot have a recall time")
        if kind in {"image", "audio", "file"}:
            if media_id is None:
                raise ValidationError("attachment messages require finalized media")
            if recalled_at is not None:
                raise ValidationError("recalled messages cannot retain media")
            asset = await self._active_record(models.MediaAsset, media_id, "media asset")
            if asset.owner_id != value("sender_id"):
                raise ForbiddenError("message media must belong to its sender")
            if asset.status != "ready" or asset.finalized_at is None:
                raise ValidationError("message media must be finalized before sending")
            matching_kind = (
                asset.mime_type.startswith("image/") if kind == "image" else
                asset.mime_type.startswith("audio/") if kind == "audio" else
                asset.mime_type in CHAT_FILE_MIME_BY_EXTENSION.values()
            )
            if not matching_kind:
                raise ValidationError("message media type does not match the message kind")
            if kind == "file" and not asset.file_name:
                raise ValidationError("file message requires a filename")
            if kind == "file" and value("body") != asset.file_name:
                raise ValidationError("file message name must match its finalized asset")
            return

        if media_id is not None:
            raise ValidationError("only attachment messages may attach media")

    @staticmethod
    def _serialize(record: models.Base) -> dict[str, Any]:
        result: dict[str, Any] = {}
        for column in record.__table__.columns:
            if column.key in {"password_hash", "token_hash"}:
                continue
            value = getattr(record, column.key)
            if isinstance(value, UUID):
                result[column.key] = str(value)
            elif isinstance(value, (datetime, date)):
                result[column.key] = value.isoformat()
            else:
                result[column.key] = value
        return result

    def _change_out(self, value: models.SyncChange) -> SyncChangeOut:
        return SyncChangeOut(seq=value.seq, entity_type=value.entity_type, entity_id=value.entity_id, operation=value.operation, version=value.version, updated_at=value.updated_at, payload=value.payload, source_mutation_id=value.source_mutation_id, source_device_id=value.source_device_id)
