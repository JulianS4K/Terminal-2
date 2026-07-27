-- =============================================================
-- Retail chat rate limit + bot_messages retention cron
-- =============================================================
-- FIX 2: per-IP rate limit for the public retail chat endpoint
--   (anonymous /functions/v1/chat had unlimited cost exposure).
-- FIX 3: schedule the bot_messages 30-day retention sweep
--   (function existed but was never scheduled).

create table if not exists chat_rate_limits (
  ip          text        not null,
  ts          timestamptz not null default now()
);
alter table chat_rate_limits enable row level security;
create index if not exists idx_chat_rl_ip_ts on chat_rate_limits(ip, ts desc);

-- Sliding-window per-IP rate limiter for the retail chat.
-- 10 requests / 60 seconds default. Returns true if allowed, false if blocked.
create or replace function check_chat_rate_limit(
  p_ip          text,
  p_window_sec  integer default 60,
  p_max_calls   integer default 10
) returns boolean
language plpgsql
volatile
as $$
declare
  v_count integer;
begin
  delete from chat_rate_limits where ts < now() - interval '1 hour';
  select count(*) into v_count
  from chat_rate_limits
  where ip = p_ip and ts > now() - make_interval(secs => p_window_sec);
  if v_count >= p_max_calls then
    return false;
  end if;
  insert into chat_rate_limits (ip) values (p_ip);
  return true;
end;
$$;

revoke all on function check_chat_rate_limit(text, integer, integer) from public;
grant execute on function check_chat_rate_limit(text, integer, integer) to service_role;

-- Schedule sweep_old_bot_messages — daily at 04:10 UTC
do $$
begin
  if not exists (select 1 from cron.job where jobname = 'sweep-bot-messages') then
    perform cron.schedule(
      'sweep-bot-messages',
      '10 4 * * *',
      $cron$select sweep_old_bot_messages()$cron$
    );
  end if;
end $$;
