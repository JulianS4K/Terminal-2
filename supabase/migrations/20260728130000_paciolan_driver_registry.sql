-- Migration 20260728130000 · level:data-collection · lane:D6 (author) → A1 (apply) · writes:paciolan_drivers,paciolan_pull_queue(+resolved_by),paciolan_driver_touch(),paciolan_driver_heartbeat(text,text,text,text),paciolan_next_pull(text,text)[replace],paciolan_pull_resolve(...+p_driver)[replace],v_paciolan_drivers,v_paciolan_pull_health[replace] · reads:paciolan_pull_queue · pre:20260727220000 (queue/next_pull/resolve), 20260727240000 (health view) · auth:OPERATOR-APPROVAL REQUIRED before apply (drops+recreates paciolan_pull_resolve with an added arg; anon EXECUTE on heartbeat)
--
-- Tie a STABLE identity to each Chrome instance so we can track extraction and
-- issues per instance. Each install gets a driver_id (+ operator label); every
-- poll/resolve records which instance did it, and a heartbeat keeps idle
-- instances visible. v_paciolan_drivers rolls it up (online, pulls_24h,
-- ok/empty/error/expired, last error) — the per-instance health surface.

-- ---- instance registry -----------------------------------------------------
create table if not exists public.paciolan_drivers (
  driver_id   text primary key,          -- stable per-install id (extension uuid)
  label       text,                       -- operator-friendly name ('kiosk-BGSU')
  user_agent  text,
  first_seen  timestamptz not null default now(),
  last_seen   timestamptz not null default now(),
  last_status text,                        -- last resolve outcome (ok/empty/error/…)
  last_error  text
);
alter table public.paciolan_drivers enable row level security;  -- service-role only
comment on table public.paciolan_drivers is
  'One row per Chrome instance driving pulls. driver_id = stable per-install id; label = operator name. last_seen updated on every poll/resolve/heartbeat; last_status/last_error = most recent outcome. Powers v_paciolan_drivers (per-instance extraction + issues).';
grant select on public.paciolan_drivers to service_role;

-- attribution: which instance actually completed each pull
alter table public.paciolan_pull_queue add column if not exists resolved_by text;

-- ---- internal upsert helper (called by the secret-gated RPCs) --------------
create or replace function public.paciolan_driver_touch(
  p_driver text, p_label text default null, p_ua text default null,
  p_status text default null, p_error text default null)
returns void
language plpgsql security definer set search_path = public as $$
begin
  if p_driver is null or btrim(p_driver) = '' then return; end if;
  insert into public.paciolan_drivers (driver_id, label, user_agent, last_seen, last_status, last_error)
  values (p_driver, p_label, p_ua, clock_timestamp(), p_status, p_error)
  on conflict (driver_id) do update set
    label       = coalesce(excluded.label, paciolan_drivers.label),
    user_agent  = coalesce(excluded.user_agent, paciolan_drivers.user_agent),
    last_seen   = clock_timestamp(),
    -- only overwrite status/error when this call carried a status (resolve),
    -- so a bare poll/heartbeat doesn't wipe the last known outcome.
    last_status = case when excluded.last_status is not null then excluded.last_status else paciolan_drivers.last_status end,
    last_error  = case when excluded.last_status is not null then excluded.last_error  else paciolan_drivers.last_error  end;
end $$;
revoke all on function public.paciolan_driver_touch(text, text, text, text, text) from public;
grant execute on function public.paciolan_driver_touch(text, text, text, text, text) to service_role;

-- ---- heartbeat: register/label + stay visible while idle (anon, secret-gated)
create or replace function public.paciolan_driver_heartbeat(
  p_secret text, p_driver text, p_label text default null, p_ua text default null)
returns void
language plpgsql security definer set search_path = public as $$
declare v_expected text;
begin
  select secret into v_expected from public.paciolan_ingest_config where id = 1;
  if v_expected is null then raise exception 'paciolan ingest not configured'; end if;
  if p_secret is null or length(p_secret) <> length(v_expected) or not (p_secret = v_expected) then
    raise exception 'unauthorized' using errcode = '28000';
  end if;
  perform public.paciolan_driver_touch(p_driver, p_label, p_ua);
end $$;
revoke all on function public.paciolan_driver_heartbeat(text, text, text, text) from public;
grant execute on function public.paciolan_driver_heartbeat(text, text, text, text) to anon, authenticated;
comment on function public.paciolan_driver_heartbeat(text, text, text, text) is
  'Extension registers its instance (driver_id + label + user_agent) and keeps last_seen fresh while idle. Secret-gated, anon-granted.';

-- ---- next_pull: record the polling instance (touch on every poll) ----------
create or replace function public.paciolan_next_pull(p_secret text, p_driver text default null)
returns table(id bigint, tenant text, event_code text, url text)
language plpgsql security definer set search_path = public as $$
declare
  v_expected text;
  v_id       bigint;
begin
  select cfg.secret into v_expected from public.paciolan_ingest_config cfg where cfg.id = 1;
  if v_expected is null then raise exception 'paciolan ingest not configured'; end if;
  if p_secret is null or length(p_secret) <> length(v_expected) or not (p_secret = v_expected) then
    raise exception 'unauthorized' using errcode = '28000';
  end if;

  -- register the instance's presence (idle polls count as "online")
  perform public.paciolan_driver_touch(p_driver);

  select q.id into v_id
  from public.paciolan_pull_queue q
  where q.resolved_at is null and q.claimed_at is null
  order by q.created_at asc
  for update skip locked
  limit 1;
  if v_id is null then return; end if;

  update public.paciolan_pull_queue q
     set claimed_at = clock_timestamp(), claimed_by = p_driver, attempts = q.attempts + 1
   where q.id = v_id;

  return query
    select q.id, q.tenant, q.event_code, q.url
    from public.paciolan_pull_queue q where q.id = v_id;
end $$;
revoke all on function public.paciolan_next_pull(text, text) from public;
grant execute on function public.paciolan_next_pull(text, text) to anon, authenticated;

-- ---- resolve: record resolving instance + its outcome ----------------------
-- Adds p_driver; drop the old 6-arg signature first so there's a single function.
drop function if exists public.paciolan_pull_resolve(text, bigint, text, bigint, integer, text);
create or replace function public.paciolan_pull_resolve(
  p_secret text, p_id bigint, p_status text,
  p_snapshot_id bigint default null, p_available integer default null,
  p_error text default null, p_driver text default null)
returns boolean
language plpgsql security definer set search_path = public as $$
declare
  v_expected text;
  v_tenant   text;
  v_code     text;
begin
  select secret into v_expected from public.paciolan_ingest_config where id = 1;
  if v_expected is null then raise exception 'paciolan ingest not configured'; end if;
  if p_secret is null or length(p_secret) <> length(v_expected) or not (p_secret = v_expected) then
    raise exception 'unauthorized' using errcode = '28000';
  end if;
  update public.paciolan_pull_queue q
     set resolved_at = clock_timestamp(), status = coalesce(p_status, 'ok'),
         snapshot_id = p_snapshot_id, available_seats = p_available,
         error_msg = left(p_error, 500), resolved_by = p_driver
   where q.id = p_id and q.resolved_at is null
   returning q.tenant, q.event_code into v_tenant, v_code;
  if v_tenant is null then return false; end if;
  update public.paciolan_pull_targets
     set last_pulled_at = clock_timestamp()
   where tenant = v_tenant and event_code = v_code;
  -- attribute the outcome to the instance
  perform public.paciolan_driver_touch(p_driver, null, null, coalesce(p_status, 'ok'), left(p_error, 500));
  return true;
end $$;
revoke all on function public.paciolan_pull_resolve(text, bigint, text, bigint, integer, text, text) from public;
grant execute on function public.paciolan_pull_resolve(text, bigint, text, bigint, integer, text, text) to anon, authenticated;
comment on function public.paciolan_pull_resolve(text, bigint, text, bigint, integer, text, text) is
  'Extension reports a pull outcome + its driver_id. Secret-gated, anon-granted. Stamps the queue row (resolved + resolved_by) + target last_pulled_at + the driver''s last_status/last_error. Returns false if the id is unknown or already resolved.';

-- ---- per-instance rollup: extraction + issues ------------------------------
create or replace view public.v_paciolan_drivers as
with q as (
  select resolved_by as driver_id,
    count(*) filter (where resolved_at >= now() - interval '24 hours')                      as pulls_24h,
    count(*) filter (where resolved_at >= now() - interval '24 hours' and status = 'ok')     as ok_24h,
    count(*) filter (where resolved_at >= now() - interval '24 hours' and status = 'empty')  as empty_24h,
    count(*) filter (where resolved_at >= now() - interval '24 hours' and status = 'error')  as error_24h,
    count(*) filter (where resolved_at >= now() - interval '24 hours' and status = 'expired') as expired_24h,
    max(resolved_at) as last_pull_at
  from public.paciolan_pull_queue
  where resolved_by is not null
  group by resolved_by
)
select
  d.driver_id, d.label, d.user_agent, d.first_seen, d.last_seen,
  (now() - d.last_seen < interval '5 minutes') as online,
  d.last_status, d.last_error,
  coalesce(q.pulls_24h, 0)   as pulls_24h,
  coalesce(q.ok_24h, 0)      as ok_24h,
  coalesce(q.empty_24h, 0)   as empty_24h,
  coalesce(q.error_24h, 0)   as error_24h,
  coalesce(q.expired_24h, 0) as expired_24h,
  q.last_pull_at
from public.paciolan_drivers d
left join q on q.driver_id = d.driver_id
order by d.last_seen desc;
comment on view public.v_paciolan_drivers is
  'Per-Chrome-instance extraction + issues: online (last_seen <5m), pulls_24h + ok/empty/error/expired split (by resolved_by), last_status/last_error. Service-role read. Powers the PACIOLAN tab drivers panel.';
grant select on public.v_paciolan_drivers to service_role;

-- ---- health screen: add instance counts ------------------------------------
create or replace view public.v_paciolan_pull_health as
select
  (select count(*) from public.paciolan_pull_targets where active)                  as targets_active,
  (select count(*) from public.paciolan_pull_targets)                               as targets_total,
  (select count(*) from public.paciolan_event_snapshots
     where tenant is not null and event_code is not null)                           as captures_total,
  count(*) filter (where resolved_at is null and claimed_at is null)                as pending,
  count(*) filter (where resolved_at is null and claimed_at is not null)            as inflight,
  count(*) filter (where resolved_at >= now() - interval '24 hours' and status = 'ok')      as ok_24h,
  count(*) filter (where resolved_at >= now() - interval '24 hours' and status = 'empty')   as empty_24h,
  count(*) filter (where resolved_at >= now() - interval '24 hours' and status = 'error')   as error_24h,
  count(*) filter (where resolved_at >= now() - interval '24 hours' and status = 'expired') as expired_24h,
  max(resolved_at)                                                                  as last_resolved_at,
  max(claimed_at) filter (where resolved_at is null)                               as oldest_inflight_claim,
  (select count(*) from public.paciolan_raw_captures)                              as raw_captures_total,
  (select count(*) from public.paciolan_raw_captures
     where captured_at >= now() - interval '24 hours'
       and coalesce(parsed_seats, 0) = 0 and coalesce(parsed_sections, 0) = 0)     as drift_24h,
  (select count(*) from public.paciolan_drivers)                                   as drivers_total,
  (select count(*) from public.paciolan_drivers
     where now() - last_seen < interval '5 minutes')                               as drivers_online
from public.paciolan_pull_queue;
comment on view public.v_paciolan_pull_health is
  'D0 PACIOLAN tab health screen: pull-loop rollup — targets, captures, queue depth, 24h outcomes, freshness, raw/drift counts, plus driver-instance counts (total + online). Service-role read.';
