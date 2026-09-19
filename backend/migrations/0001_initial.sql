-- DRAFT ALEMBIC-equivalent SQL ONLY. Do not execute this file.
-- PostgreSQL schema mirrors backend/app/models/entities.py and iOS ownership.

create table members (
  id uuid primary key, display_name varchar(80) not null, password_hash varchar(255) not null,
  created_at timestamptz not null default now()
);
create table auth_sessions (
  id uuid primary key, member_id uuid not null references members(id) on delete cascade,
  token_hash varchar(255) not null unique, expires_at timestamptz not null
);
create index ix_auth_sessions_member on auth_sessions(member_id);

create table chats (id uuid primary key, created_at timestamptz not null default now());
create table messages (
  id uuid primary key, chat_id uuid not null references chats(id) on delete cascade,
  sender_id uuid not null references members(id) on delete restrict, kind varchar(32) not null,
  body text, media_key varchar(512), reply_to_id uuid references messages(id) on delete set null,
  sent_at timestamptz not null default now(), recalled_at timestamptz
);
create index ix_messages_chat_sent on messages(chat_id, sent_at);
create table message_receipts (
  id uuid primary key, message_id uuid not null references messages(id) on delete cascade,
  member_id uuid not null references members(id) on delete cascade, delivered_at timestamptz, read_at timestamptz,
  constraint uq_message_receipt_member unique(message_id, member_id)
);

create table semesters (
  id uuid primary key, name varchar(120) not null, week1_start date not null, week1_end date not null,
  total_weeks integer not null check(total_weeks between 1 and 52), is_current boolean not null default false,
  check(week1_end >= week1_start)
);
create unique index uq_current_semester on semesters((is_current)) where is_current;
create table schedules (
  id uuid primary key, owner_id uuid not null references members(id) on delete cascade,
  semester_id uuid not null references semesters(id) on delete cascade, kind varchar(32) not null,
  title varchar(200) not null, weekday smallint not null check(weekday between 1 and 7),
  start_minutes integer not null check(start_minutes between 0 and 1439),
  end_minutes integer not null check(end_minutes between 1 and 1440),
  start_week integer not null check(start_week >= 1), end_week integer not null check(end_week >= start_week),
  week_type varchar(20) not null, metadata_json jsonb not null default '{}'::jsonb,
  check(start_minutes < end_minutes)
);
create index ix_schedule_owner_semester on schedules(owner_id, semester_id);
create table schedule_exceptions (
  id uuid primary key, schedule_id uuid not null references schedules(id) on delete cascade,
  scope varchar(32) not null, kind varchar(32) not null, occurrence_date date not null, replacement_json jsonb
);
create index ix_schedule_exception_schedule on schedule_exceptions(schedule_id);
create table calendar_overrides (
  id uuid primary key, semester_id uuid not null references semesters(id) on delete cascade,
  date date not null, kind varchar(32) not null, mapped_weekday smallint, note text,
  constraint uq_calendar_override_day unique(semester_id, date),
  check(mapped_weekday is null or mapped_weekday between 1 and 7)
);

create table agendas (
  id uuid primary key, creator_id uuid not null references members(id) on delete restrict,
  kind varchar(32) not null, title varchar(200) not null, start_at timestamptz, end_at timestamptz,
  due_at timestamptz, participant_ids jsonb not null default '[]'::jsonb,
  recurrence_rule jsonb, detail_json jsonb not null default '{}'::jsonb,
  check(end_at is null or start_at is null or start_at < end_at)
);
create index ix_agenda_creator on agendas(creator_id);
create table agenda_exceptions (
  id uuid primary key, agenda_id uuid not null references agendas(id) on delete cascade,
  scope varchar(32) not null, kind varchar(32) not null, occurrence_date date not null, replacement_json jsonb
);
create index ix_agenda_exception_agenda on agenda_exceptions(agenda_id);

create table memos (
  id uuid primary key, creator_id uuid not null references members(id) on delete restrict,
  content text not null, version integer not null default 1 check(version > 0),
  updated_by uuid not null references members(id) on delete restrict
);
create table notices (
  id uuid primary key, publisher_id uuid not null references members(id) on delete restrict,
  title varchar(200) not null, content text not null, pinned boolean not null default false,
  created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);
create index ix_notices_order on notices(pinned desc, updated_at desc, created_at desc);
create table notice_reads (
  id uuid primary key, notice_id uuid not null references notices(id) on delete cascade,
  member_id uuid not null references members(id) on delete cascade, read_at timestamptz not null default now(),
  constraint uq_notice_read_member unique(notice_id, member_id)
);

create table location_snapshots (
  id uuid primary key, member_id uuid not null references members(id) on delete cascade,
  latitude double precision not null check(latitude between -90 and 90),
  longitude double precision not null check(longitude between -180 and 180),
  captured_at timestamptz not null, event_type varchar(32)
);
create index ix_location_member_captured on location_snapshots(member_id, captured_at);
create table member_places (
  id uuid primary key, member_id uuid not null references members(id) on delete cascade,
  type varchar(32) not null, name varchar(120) not null,
  latitude double precision not null check(latitude between -90 and 90),
  longitude double precision not null check(longitude between -180 and 180),
  radius_m integer not null check(radius_m in (100, 200, 500, 1000)), enabled boolean not null default true
);
create index ix_member_places_member on member_places(member_id);
create table geofence_events (
  id uuid primary key, place_id uuid not null references member_places(id) on delete cascade,
  member_id uuid not null references members(id) on delete cascade,
  event_type varchar(16) not null check(event_type in ('arrive', 'leave')), occurred_at timestamptz not null
);
create index ix_geofence_place_time on geofence_events(place_id, occurred_at);
