-- app_users: custom username+password auth gate (live in prod, not in any prior migration).
-- RLS enabled with no policies = service_role only.
-- Captured here so a fresh project clone reproduces production.

create table if not exists app_users (
  username      text        primary key,
  password_hash text        not null,
  active        boolean     not null default true,
  created_at    timestamptz not null default now()
);

alter table app_users enable row level security;
