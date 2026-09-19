# FamilyApp backend scaffold

Status: **Backend code only / 未运行 / 未验证服务可用**.

This folder deliberately has no running service configuration, no Docker files,
and no iOS network integration. It is a future FastAPI + PostgreSQL boundary
for replacing the local Demo repositories without changing the app's domain
names.

Included code-only layers:

- `models/`: SQLAlchemy entities for member/auth, chat/message/receipt,
  agenda/exception, semester/schedule/exception/calendar override, memo,
  notice/read, location, member place and geofence event.
- `schemas/`: Pydantic validation for pagination, timed agendas, schedules,
  semesters, calendar overrides, notices and member places.
- `repositories/`: async repository and cursor-page interfaces only.
- `services/`: domain validation boundary; no database session is created.
- `routers/`: versioned route composition placeholder only.
- `permissions/`: owner, creator, publisher and member-place checks matching iOS.
- `migrations/0001_initial.sql`: PostgreSQL draft with foreign keys, cascades,
  indexes, unique constraints and database-level bounds checks.

The supplied migration is intentionally a draft, not an executed Alembic
revision. Before any future execution, set a non-demo `DATABASE_URL`, implement
password hashing and token rotation, wire repositories to a transaction/session
factory, add Alembic revisions, and perform authorization and migration tests
against an isolated database.

No FastAPI, PostgreSQL, Redis, Docker, WebSocket, APNs, AI proxy or iOS remote
connection was started or configured by this scaffold.
