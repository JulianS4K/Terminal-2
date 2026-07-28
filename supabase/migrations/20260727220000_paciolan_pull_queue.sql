-- Migration 20260727220000 · level:data-collection · lane:D6 (author) → A1 (apply) · writes:paciolan_pull_targets,paciolan_pull_queue,paciolan_seed_targets(),paciolan_target_url(text,text,text),paciolan_enqueue_due(int),paciolan_next_pull(text,text),paciolan_pull_resolve(text,bigint,text,bigint,int,text),paciolan_pull_sweep(),paciolan_pull_stats(text),cron_policy(2 rows),cron.schedule(2 jobs) · reads:paciolan_ingest_config,paciolan_event_snapshots · pre:20260727190000 (paciolan_ingest_config secret gate), 20260527100000 (td_pull_queue pattern mirrored), 20260515250000 (cron_should_fire/cron_policy) · auth:OPERATOR-APPROVAL REQUIRED before apply (cron.schedule + anon EXECUTE on secret-gated claim/resolve RPCs)
--
-- SQL-driven autonomous pull loop for Paciolan/eVenue — the browser-side twin of
-- TicketsData's td_pull_queue (mig 20260527100000). eVenue can't be fetched
-- server-side (evenue.net is a FORBIDDEN_HOST + egress-blocked + anti-bot), so
-- Postgres CANNOT run td_pull_drain's net.http_get against it. Instead SQL keeps
-- the QUEUE and the extension's autonomous background driver PULLS the work in a
-- real, logged-in Chrome:
--
--   pg_cron  paciolan_enqueue_due()  → marks due targets → paciolan_pull_queue
--   browser  paciolan_next_pull(sec) → claims one due row (SKIP LOCKED), returns URL
--            driver opens the eVenue tab, scrapes, uploads via paciolan_ingest_secure
--            paciolan_pull_resolve(sec, id, …) → marks the row done
--   pg_cron  paciolan_pull_sweep()   → re-claims stuck rows, expires stale ones
--
-- The claim/resolve/stats RPCs are anon-granted but SECRET-GATED (reusing the
-- paciolan_ingest_config secret — no service_role key in the browser). RULE 2:
-- nothing here fetches eVenue; the queue only names URLs for the browser to open.

-- ─────────────────────────────────────────────────────────────────────────────
-- 1) watchlist — the events the driver should keep pulling
-- ─────────────────────────────────────────────────────────────────────────────
create table if not exists public.paciolan_pull_targets (
  tenant            text not null,
  event_code        text not null,           -- 'F26/F01'
  url               text,                     -- override; else derived from tenant+code
  pull_interval_min int  not null default 60, -- re-enqueue cadence
  active            boolean not null default true,
  note              text,
  last_enqueued_at  timestamptz,
  last_pulled_at    timestamptz,
  created_at        timestamptz not null default now(),
  primary key (tenant, event_code)
);
alter table public.paciolan_pull_targets enable row level security;  -- service-role only
comment on table public.paciolan_pull_targets is
  'Watchlist for the autonomous Paciolan driver: (tenant,event_code) the extension should keep re-pulling every pull_interval_min. url derived from tenant+event_code when null. Operator/A1 seeds rows; paciolan_enqueue_due reads it. Mirror of ticketsdata_event_xref.';

-- Auto-seed: any event we've captured at least once becomes a self-refreshing
-- target (active, upcoming only). So once you scrape an eVenue event by hand, the
-- driver keeps it fresh — no manual watchlist upkeep. Mirrors td_watchlist_refresh.
create or replace function public.paciolan_seed_targets()
returns integer
language plpgsql security definer set search_path = public as $$
declare v_count int;
begin
  insert into public.paciolan_pull_targets (tenant, event_code, note)
  select distinct e.tenant, e.event_code, 'auto-seeded from capture'
  from public.paciolan_event_snapshots e
  where e.tenant is not null and e.event_code is not null
    and (e.occurs_at is null or e.occurs_at > clock_timestamp() - interval '2 hours')
  on conflict (tenant, event_code) do nothing;
  get diagnostics v_count = row_count;
  return v_count;
end $$;
revoke all on function public.paciolan_seed_targets() from public;
grant execute on function public.paciolan_seed_targets() to service_role;
comment on function public.paciolan_seed_targets() is
  'Auto-add every previously-captured (tenant,event_code) as an active pull target (upcoming only). Called by paciolan_enqueue_due so a hand-scraped event becomes self-refreshing. Mirrors td_watchlist_refresh.';

-- Derive the eVenue URL from tenant + event_code when a target has no override.
create or replace function public.paciolan_target_url(p_tenant text, p_event_code text, p_url text)
returns text
language sql immutable set search_path = public as $$
  select coalesce(nullif(btrim(p_url), ''),
                  'https://' || p_tenant || '.evenue.net/event/' || p_event_code);
$$;
revoke all on function public.paciolan_target_url(text, text, text) from public;

-- ─────────────────────────────────────────────────────────────────────────────
-- 2) the work queue (browser-drained twin of td_pull_queue)
-- ─────────────────────────────────────────────────────────────────────────────
create table if not exists public.paciolan_pull_queue (
  id               bigint generated always as identity primary key,
  tenant           text not null,
  event_code       text not null,
  url              text not null,
  interval_tag     text,
  created_at       timestamptz not null default now(),
  claimed_at       timestamptz,              -- a driver claimed it (via next_pull)
  claimed_by       text,                     -- opaque driver id
  attempts         int not null default 0,   -- claim count (sweep uses it)
  resolved_at      timestamptz,
  status           text,                     -- ok | empty | error | expired
  snapshot_id      bigint,                   -- paciolan_event_snapshots.id on success
  available_seats  int,
  error_msg        text
);
create index if not exists idx_paciolan_pq_claimable
  on public.paciolan_pull_queue (created_at)
  where resolved_at is null and claimed_at is null;
create index if not exists idx_paciolan_pq_open
  on public.paciolan_pull_queue (tenant, event_code)
  where resolved_at is null;
alter table public.paciolan_pull_queue enable row level security;  -- service-role only
comment on table public.paciolan_pull_queue is
  'Autonomous-driver work queue for Paciolan/eVenue. One row per due (tenant,event_code). The extension claims a row via paciolan_next_pull (SKIP LOCKED), opens the URL, scrapes, uploads, then paciolan_pull_resolve marks it done. Browser-drained twin of td_pull_queue — SQL never fetches eVenue itself.';

-- ─────────────────────────────────────────────────────────────────────────────
-- 3) enqueue_due — pg_cron pushes due targets onto the queue (server-side, no egress)
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.paciolan_enqueue_due(p_max integer default 100)
returns integer
language plpgsql security definer set search_path = public as $$
declare
  r       record;
  v_count int := 0;
  v_now   timestamptz := clock_timestamp();
  v_gate  boolean := true;
begin
  -- Honour the cron_policy kill-switch when the gate exists (fail-open otherwise).
  if to_regprocedure('public.cron_should_fire(text)') is not null then
    v_gate := public.cron_should_fire('paciolan_enqueue_due');
  end if;
  if not v_gate then return 0; end if;

  -- Fold in newly-captured events so a hand-scraped event self-refreshes.
  perform public.paciolan_seed_targets();

  for r in
    select t.tenant, t.event_code,
           public.paciolan_target_url(t.tenant, t.event_code, t.url) as url
    from public.paciolan_pull_targets t
    where t.active
      and (t.last_enqueued_at is null
           or t.last_enqueued_at < v_now - make_interval(mins => t.pull_interval_min))
      -- pileup guard: no open (unresolved) queue row for this event already
      and not exists (
        select 1 from public.paciolan_pull_queue q
        where q.tenant = t.tenant and q.event_code = t.event_code
          and q.resolved_at is null
      )
    order by t.last_enqueued_at asc nulls first
    limit p_max
  loop
    insert into public.paciolan_pull_queue (tenant, event_code, url, interval_tag, created_at)
    values (r.tenant, r.event_code, r.url, 'cron', v_now);

    update public.paciolan_pull_targets
       set last_enqueued_at = v_now
     where tenant = r.tenant and event_code = r.event_code;

    v_count := v_count + 1;
  end loop;

  return v_count;
end $$;
revoke all on function public.paciolan_enqueue_due(integer) from public;
grant execute on function public.paciolan_enqueue_due(integer) to service_role;
comment on function public.paciolan_enqueue_due(integer) is
  'pg_cron: push due paciolan_pull_targets (last_enqueued_at older than pull_interval_min, no open queue row) onto paciolan_pull_queue. Server-side/no egress — the browser does the fetching. Returns rows enqueued.';

-- ─────────────────────────────────────────────────────────────────────────────
-- 4) next_pull — the "SQL sends the signal" surface the extension polls
--    Secret-gated (paciolan_ingest_config), anon-granted, claims one row.
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.paciolan_next_pull(p_secret text, p_driver text default null)
returns table(id bigint, tenant text, event_code text, url text)
language plpgsql security definer set search_path = public as $$
declare
  v_expected text;
  v_id       bigint;
begin
  -- qualify the column: this function's RETURNS TABLE(id …) shadows a bare `id`.
  select cfg.secret into v_expected from public.paciolan_ingest_config cfg where cfg.id = 1;
  if v_expected is null then raise exception 'paciolan ingest not configured'; end if;
  if p_secret is null or length(p_secret) <> length(v_expected) or not (p_secret = v_expected) then
    raise exception 'unauthorized' using errcode = '28000';
  end if;

  -- Claim the oldest unclaimed, unresolved row. SKIP LOCKED so concurrent
  -- drivers never hand out the same URL twice.
  select q.id into v_id
  from public.paciolan_pull_queue q
  where q.resolved_at is null and q.claimed_at is null
  order by q.created_at asc
  for update skip locked
  limit 1;

  if v_id is null then return; end if;

  update public.paciolan_pull_queue q
     set claimed_at = clock_timestamp(),
         claimed_by = p_driver,
         attempts   = q.attempts + 1
   where q.id = v_id;

  return query
    select q.id, q.tenant, q.event_code, q.url
    from public.paciolan_pull_queue q where q.id = v_id;
end $$;
revoke all on function public.paciolan_next_pull(text, text) from public;
grant execute on function public.paciolan_next_pull(text, text) to anon, authenticated;
comment on function public.paciolan_next_pull(text, text) is
  'Extension autonomous driver polls this: secret-gated (paciolan_ingest_config), claims the oldest due paciolan_pull_queue row (FOR UPDATE SKIP LOCKED) and returns its URL to open. Empty result = nothing due. anon-granted (called with the public anon key + shared secret) — no service_role in the browser.';

-- ─────────────────────────────────────────────────────────────────────────────
-- 5) resolve — the driver reports the outcome after uploading
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.paciolan_pull_resolve(
  p_secret text, p_id bigint, p_status text,
  p_snapshot_id bigint default null, p_available integer default null,
  p_error text default null)
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
     set resolved_at     = clock_timestamp(),
         status          = coalesce(p_status, 'ok'),
         snapshot_id     = p_snapshot_id,
         available_seats = p_available,
         error_msg       = left(p_error, 500)
   where q.id = p_id and q.resolved_at is null
   returning q.tenant, q.event_code into v_tenant, v_code;

  if v_tenant is null then return false; end if;   -- unknown id or already resolved

  update public.paciolan_pull_targets
     set last_pulled_at = clock_timestamp()
   where tenant = v_tenant and event_code = v_code;

  return true;
end $$;
revoke all on function public.paciolan_pull_resolve(text, bigint, text, bigint, integer, text) from public;
grant execute on function public.paciolan_pull_resolve(text, bigint, text, bigint, integer, text) to anon, authenticated;
comment on function public.paciolan_pull_resolve(text, bigint, text, bigint, integer, text) is
  'Extension reports a pull outcome (ok/empty/error + snapshot_id/available/error). Secret-gated, anon-granted. Stamps the queue row resolved and the target last_pulled_at. Returns false if the id is unknown or already resolved.';

-- ─────────────────────────────────────────────────────────────────────────────
-- 6) sweep — re-claim stuck rows, expire stale ones, prune history (pg_cron)
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.paciolan_pull_sweep()
returns void
language plpgsql security definer set search_path = public as $$
declare
  v_now  timestamptz := clock_timestamp();
  v_gate boolean := true;
begin
  if to_regprocedure('public.cron_should_fire(text)') is not null then
    v_gate := public.cron_should_fire('paciolan_pull_sweep');
  end if;
  if not v_gate then return; end if;

  -- Claimed but not resolved after 10 min: the tab likely never rendered.
  -- Re-open for claiming if under the attempt cap, else give up (expired).
  update public.paciolan_pull_queue
     set claimed_at = null, claimed_by = null
   where resolved_at is null and claimed_at is not null
     and claimed_at < v_now - interval '10 minutes'
     and attempts < 3;

  update public.paciolan_pull_queue
     set resolved_at = v_now, status = 'expired',
         error_msg = 'no driver completed after ' || attempts || ' attempts'
   where resolved_at is null and claimed_at is not null
     and claimed_at < v_now - interval '10 minutes'
     and attempts >= 3;

  -- Unclaimed but ancient (driver offline all window): expire after 1 day so the
  -- target can be re-enqueued fresh rather than serving a stale URL.
  update public.paciolan_pull_queue
     set resolved_at = v_now, status = 'expired', error_msg = 'stale, never claimed'
   where resolved_at is null and claimed_at is null
     and created_at < v_now - interval '1 day';

  -- Prune resolved history older than 7 days.
  delete from public.paciolan_pull_queue
   where resolved_at is not null and created_at < v_now - interval '7 days';
end $$;
revoke all on function public.paciolan_pull_sweep() from public;
grant execute on function public.paciolan_pull_sweep() to service_role;
comment on function public.paciolan_pull_sweep() is
  'pg_cron hourly: re-open claimed-but-unresolved rows (<3 attempts), expire the rest, expire never-claimed rows >1d, prune resolved >7d. Twin of td_pending_sweep.';

-- ─────────────────────────────────────────────────────────────────────────────
-- 7) stats — small secret-gated read so the popup can show queue depth
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.paciolan_pull_stats(p_secret text)
returns table(pending int, claimed int, resolved_24h int)
language plpgsql security definer set search_path = public as $$
declare v_expected text;
begin
  select secret into v_expected from public.paciolan_ingest_config where id = 1;
  if v_expected is null then raise exception 'paciolan ingest not configured'; end if;
  if p_secret is null or length(p_secret) <> length(v_expected) or not (p_secret = v_expected) then
    raise exception 'unauthorized' using errcode = '28000';
  end if;
  return query
    select count(*) filter (where resolved_at is null and claimed_at is null)::int,
           count(*) filter (where resolved_at is null and claimed_at is not null)::int,
           count(*) filter (where resolved_at >= clock_timestamp() - interval '24 hours')::int
    from public.paciolan_pull_queue;
end $$;
revoke all on function public.paciolan_pull_stats(text) from public;
grant execute on function public.paciolan_pull_stats(text) to anon, authenticated;
comment on function public.paciolan_pull_stats(text) is
  'Popup queue-depth read: pending/claimed/resolved_24h counts. Secret-gated, anon-granted.';

-- ─────────────────────────────────────────────────────────────────────────────
-- 8) cron_policy rows + schedule (guarded — only where the infra exists)
-- ─────────────────────────────────────────────────────────────────────────────
do $sched$
begin
  -- cron_policy kill-switch rows (A1 can disable without a deploy).
  if to_regclass('public.cron_policy') is not null then
    insert into public.cron_policy
      (jobname, peak_hours_et, peak_min_interval_min, offpeak_min_interval_min,
       daily_max_fires, work_check_sql, enabled, notes)
    values
      ('paciolan_enqueue_due', '{}'::int[], 5, 5, null,
       -- fire when there is anything to seed OR anything to enqueue (seeding
       -- happens inside the job, so gating on targets alone would deadlock).
       'SELECT EXISTS (SELECT 1 FROM public.paciolan_pull_targets WHERE active) OR EXISTS (SELECT 1 FROM public.paciolan_event_snapshots)',
       true,
       'Paciolan autonomous-driver enqueue. Every 5 min: auto-seed captures → due targets → paciolan_pull_queue. Browser drains it (eVenue unreachable server-side).'),
      ('paciolan_pull_sweep', '{}'::int[], 60, 60, 24,
       'SELECT true', true,
       'Paciolan queue sweep. Hourly: re-open stuck claims (<3 tries), expire the rest, prune 7d.')
    on conflict (jobname) do update
      set peak_min_interval_min    = excluded.peak_min_interval_min,
          offpeak_min_interval_min = excluded.offpeak_min_interval_min,
          work_check_sql           = excluded.work_check_sql,
          notes                    = excluded.notes,
          updated_at               = now();
  end if;

  -- Schedule only where pg_cron is installed (prod). Safe no-op on a bare DB.
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.schedule(
      'paciolan_enqueue_due', '*/5 * * * *',
      $cron$DO $body$ BEGIN PERFORM public.paciolan_enqueue_due(100); END $body$;$cron$
    );
    perform cron.schedule(
      'paciolan_pull_sweep', '20 * * * *',
      $cron$DO $body$ BEGIN PERFORM public.paciolan_pull_sweep(); END $body$;$cron$
    );
  end if;
end $sched$;
