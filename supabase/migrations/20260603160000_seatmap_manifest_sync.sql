-- Migration 20260603160000 · lane:D0 (author) → operator-authorized apply 2026-06-03 · writes:seatmap_manifest table + seatmap_manifest_targets() + cron · reads:events
--
-- ## Already applied to prod — applied via MCP apply_migration 2026-06-03 (operator-authorized).
--    Edge fn `seatmap-manifest-sync` deployed (v1) same session; cron live (*/30).
--    First runs verified: 280 configs cached, ~89% has_map, 0 errors.
--
-- D0 — cache the TEvo seat-map MANIFESTS (the section-key lists) server-side so the
-- section matcher can be validated/tuned across every venue without the manual
-- browser-paste loop. The manifests live on a PUBLIC CDN
-- (maps.ticketevolution.com/{venue}/{config}/manifest.json) that the agent/SQL
-- sandbox cannot reach (egress allowlist), but Supabase EDGE FUNCTIONS can. The
-- companion edge fn `seatmap-manifest-sync` fetches + upserts into this table;
-- this migration adds the table, the target picker, and the driving cron.
--
-- `has_map` (manifest.json → 200 with sections) replaces the `fanvenues_key`
-- proxy as the real "this venue/config has an interactive map" signal.

create table if not exists public.seatmap_manifest (
  venue_id          bigint  not null,
  configuration_id  integer not null,
  has_map           boolean not null default false,
  http_status       int,
  section_count     int     not null default 0,
  section_keys      text[]  not null default '{}',
  fetched_at        timestamptz not null default now(),
  primary key (venue_id, configuration_id)
);
comment on table public.seatmap_manifest is
  'Cached TEvo seat-map manifests (section keys) per venue/config, fetched by the seatmap-manifest-sync edge fn. has_map = real interactive-map availability (replaces fanvenues_key proxy). D0, mig 20260603160000.';

-- Internal-only: service_role (edge fn) reads/writes; RLS on with no policy denies
-- anon/authenticated. A future FE read path would go through a view/RPC.
alter table public.seatmap_manifest enable row level security;

-- Distinct upcoming venue/config pairs not fetched in the last 7 days, never-fetched
-- first. Drives the edge fn's bounded per-run batch.
create or replace function public.seatmap_manifest_targets(p_limit int default 60)
returns table(venue_id bigint, configuration_id integer)
language sql stable security definer set search_path = public, pg_temp
as $$
  select q.venue_id, q.configuration_id
  from (
    select distinct e.venue_id, e.configuration_id
    from public.events e
    where e.venue_id is not null and e.configuration_id is not null
      and e.occurs_at_local >= to_char(now(), 'YYYY-MM-DD"T"HH24:MI:SS')
  ) q
  left join public.seatmap_manifest m
    on m.venue_id = q.venue_id and m.configuration_id = q.configuration_id
  where m.fetched_at is null or m.fetched_at < now() - interval '7 days'
  order by m.fetched_at asc nulls first
  limit p_limit;
$$;
revoke all on function public.seatmap_manifest_targets(int) from public, anon, authenticated;
grant execute on function public.seatmap_manifest_targets(int) to service_role;

-- Driving cron: every 30 min, gated by cron_should_fire (default-fires, logs to
-- cron_gate_decisions). Bounded per run by the edge fn (~60 configs / 50s budget),
-- so ~1,200 upcoming pairs sweep in under a day, then steady-state refresh (7d).
select cron.schedule(
  'seatmap-manifest-sync', '*/30 * * * *',
  $cron$ DO $b$ BEGIN
    IF NOT public.cron_should_fire('seatmap-manifest-sync') THEN RETURN; END IF;
    PERFORM public._cron_invoke_edge_fn(
      'https://hzrizjeaxlqcxfrtczpq.supabase.co/functions/v1/seatmap-manifest-sync',
      '{}'::jsonb);
  END $b$; $cron$
);
