-- On-demand pull tracking + rate limiting for the bot, terminal UI, and any
-- other client that wants a fresh listings snapshot for a single event.
--
-- Flow:
--   1. Caller invokes get_or_authorize_pull(event_id, source, requester, max_age_seconds)
--   2. Function logs the pull to event_pulls (every call gets a row) and returns
--      one of: 'serve_cache' | 'fetch_fresh' | 'rate_limited'
--   3. Caller reads listings_snapshots / event_metrics for the answer
--   4. If decision was 'fetch_fresh', caller invokes the collect-listings Edge
--      Function with ?event_id=X. After the upstream call returns, caller
--      UPDATEs the event_pulls row with tevo_calls (and any error in meta).
--
-- The function is the sole writer of event_pulls so rate-limit windows are
-- enforced atomically: a fresh pull is "reserved" before the upstream fetch
-- begins, so concurrent callers see it and back off.

create table if not exists event_pulls (
  id                   bigserial primary key,
  event_id             bigint not null,
  source               text   not null,                          -- 'sms' | 'whatsapp' | 'web' | 'cron' | 'api'
  requester            text,                                     -- phone (E.164) or email; null for cron
  requested_at         timestamptz not null default now(),
  served_from          text   not null check (served_from in ('cache','fresh','rate_limited','error')),
  snapshot_age_seconds integer,
  tevo_calls           integer not null default 0,
  meta                 jsonb
);
alter table event_pulls enable row level security;
create index if not exists idx_event_pulls_event_time
  on event_pulls (event_id, requested_at desc);
create index if not exists idx_event_pulls_requester_time
  on event_pulls (requester, requested_at desc) where requester is not null;
create index if not exists idx_event_pulls_event_requester_fresh_time
  on event_pulls (event_id, requester, requested_at desc) where served_from = 'fresh';
create index if not exists idx_event_pulls_event_fresh_time
  on event_pulls (event_id, requested_at desc) where served_from = 'fresh';

create table if not exists pull_rate_limits (
  scope               text primary key check (scope in ('per_event','per_requester','per_event_requester')),
  min_seconds_between integer not null check (min_seconds_between >= 0),
  meta                jsonb,
  updated_at          timestamptz not null default now()
);
alter table pull_rate_limits enable row level security;

insert into pull_rate_limits (scope, min_seconds_between, meta) values
  ('per_event',           60,  '{"note":"min seconds between FRESH upstream pulls for the same event_id, regardless of caller"}'),
  ('per_requester',       10,  '{"note":"min seconds between any pulls from the same requester; bursty callers are throttled"}'),
  ('per_event_requester', 60,  '{"note":"min seconds between FRESH pulls for the same (event_id, requester); a single user cannot force-refresh one event repeatedly"}')
on conflict (scope) do nothing;

-- Atomic decision + log.
-- Returns jsonb: { decision, pull_id, last_snapshot_at, age_seconds, reason?, retry_after_seconds? }
create or replace function get_or_authorize_pull(
  p_event_id bigint,
  p_source text,
  p_requester text,
  p_max_age_seconds integer default 60
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_now                       timestamptz := now();
  v_last_snapshot             timestamptz;
  v_age                       integer;
  v_per_event                 integer;
  v_per_requester             integer;
  v_per_event_requester       integer;
  v_last_fresh_event          timestamptz;
  v_last_pull_requester       timestamptz;
  v_last_fresh_event_req      timestamptz;
  v_pull_id                   bigint;
  v_reason                    text;
  v_retry                     integer;
begin
  -- Snapshot age
  select max(captured_at) into v_last_snapshot
  from listings_snapshots
  where event_id = p_event_id;

  v_age := case
    when v_last_snapshot is null then null
    else extract(epoch from (v_now - v_last_snapshot))::int
  end;

  -- Cache hit?
  if v_age is not null and v_age <= coalesce(p_max_age_seconds, 60) then
    insert into event_pulls (event_id, source, requester, served_from, snapshot_age_seconds, tevo_calls)
    values (p_event_id, p_source, p_requester, 'cache', v_age, 0)
    returning id into v_pull_id;
    return jsonb_build_object(
      'decision',         'serve_cache',
      'pull_id',          v_pull_id,
      'last_snapshot_at', v_last_snapshot,
      'age_seconds',      v_age
    );
  end if;

  -- Need to fetch fresh — check rate limits
  select min_seconds_between into v_per_event           from pull_rate_limits where scope = 'per_event';
  select min_seconds_between into v_per_requester       from pull_rate_limits where scope = 'per_requester';
  select min_seconds_between into v_per_event_requester from pull_rate_limits where scope = 'per_event_requester';

  select max(requested_at) into v_last_fresh_event
  from event_pulls
  where event_id = p_event_id and served_from = 'fresh';

  if p_requester is not null then
    select max(requested_at) into v_last_pull_requester
    from event_pulls
    where requester = p_requester;

    select max(requested_at) into v_last_fresh_event_req
    from event_pulls
    where event_id = p_event_id and requester = p_requester and served_from = 'fresh';
  end if;

  -- per_event window
  if v_per_event is not null and v_last_fresh_event is not null
     and extract(epoch from (v_now - v_last_fresh_event)) < v_per_event then
    v_reason := 'per_event';
    v_retry  := ceil(v_per_event - extract(epoch from (v_now - v_last_fresh_event)))::int;
  -- per_requester window (any pull, any event)
  elsif v_per_requester is not null and v_last_pull_requester is not null
     and extract(epoch from (v_now - v_last_pull_requester)) < v_per_requester then
    v_reason := 'per_requester';
    v_retry  := ceil(v_per_requester - extract(epoch from (v_now - v_last_pull_requester)))::int;
  -- per_event_requester window
  elsif v_per_event_requester is not null and v_last_fresh_event_req is not null
     and extract(epoch from (v_now - v_last_fresh_event_req)) < v_per_event_requester then
    v_reason := 'per_event_requester';
    v_retry  := ceil(v_per_event_requester - extract(epoch from (v_now - v_last_fresh_event_req)))::int;
  end if;

  if v_reason is not null then
    insert into event_pulls (event_id, source, requester, served_from, snapshot_age_seconds, tevo_calls, meta)
    values (p_event_id, p_source, p_requester, 'rate_limited', v_age, 0,
            jsonb_build_object('reason', v_reason, 'retry_after_seconds', v_retry))
    returning id into v_pull_id;
    return jsonb_build_object(
      'decision',            'rate_limited',
      'pull_id',             v_pull_id,
      'reason',              v_reason,
      'retry_after_seconds', v_retry,
      'last_snapshot_at',    v_last_snapshot,
      'age_seconds',         v_age
    );
  end if;

  -- Greenlight: reserve the slot before the upstream fetch begins.
  insert into event_pulls (event_id, source, requester, served_from, snapshot_age_seconds, tevo_calls)
  values (p_event_id, p_source, p_requester, 'fresh', v_age, 0)
  returning id into v_pull_id;

  return jsonb_build_object(
    'decision',         'fetch_fresh',
    'pull_id',          v_pull_id,
    'last_snapshot_at', v_last_snapshot,
    'age_seconds',      v_age
  );
end
$$;

revoke all on function get_or_authorize_pull(bigint, text, text, integer) from public;
grant execute on function get_or_authorize_pull(bigint, text, text, integer) to service_role;
