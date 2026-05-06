-- Channel-agnostic messaging bot. v1 uses 'sms'; 'whatsapp' will land later.
-- RLS on, no policies = service-role only.

create table if not exists bot_users (
  phone       text        primary key,                     -- E.164, e.g. +14253728504
  label       text        not null,
  active      boolean     not null default true,
  channels    text[]      not null default array['sms']::text[],
  created_at  timestamptz not null default now()
);
alter table bot_users enable row level security;

create table if not exists bot_messages (
  id           bigserial   primary key,
  channel      text        not null check (channel in ('sms','whatsapp')),
  direction    text        not null check (direction in ('in','out')),
  phone        text        not null,
  body         text,
  message_sid  text,
  meta         jsonb,
  created_at   timestamptz not null default now()
);
alter table bot_messages enable row level security;
create index if not exists idx_bot_messages_phone_time
  on bot_messages (phone, created_at desc);
create index if not exists idx_bot_messages_channel_time
  on bot_messages (channel, created_at desc);

-- Auto-purge messages older than 30 days
create or replace function sweep_old_bot_messages()
returns void language sql as $$
  delete from bot_messages
  where created_at < now() - interval '30 days';
$$;
