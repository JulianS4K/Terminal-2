-- Migration 20260727230000 · level:data-collection · lane:D6 (author) → A1 (apply) · writes:v_paciolan_events,v_paciolan_pull_health · reads:paciolan_event_snapshots,paciolan_event_xref,paciolan_pull_queue,paciolan_pull_targets,v_paciolan_listings · pre:20260727200000 (xref+occurs_at cols), 20260727220000 (pull_queue/targets) · auth:read-only views, but ships alongside the pull-queue apply
--
-- Backing views for the D0 terminal "PACIOLAN" tab (URL layer + health screen),
-- the browser twin of the AXS tab (static/terminal/axs.html + /api/axs/events).
-- The paciolan_* tables are RLS service-role-only, so the terminal reads these
-- through the backend (routers/paciolan.py, service-role) — same posture as AXS.

-- ---- 1) URL layer: one row per captured event, latest snapshot + mapping +
--         pull-queue health. Mirrors the axs_events enrichment. ----------------
create or replace view public.v_paciolan_events as
with latest as (
  select distinct on (tenant, event_code)
         id as snapshot_id, tenant, event_code, source_url, event_name,
         venue_name, occurs_at, home_team, away_team,
         section_count, seat_count, captured_at,
         tevo_event_id, aq_short_event_id
  from public.paciolan_event_snapshots
  where tenant is not null and event_code is not null
  order by tenant, event_code, captured_at desc
),
face as (
  select snapshot_id,
         min(retail_price) as getin,
         max(retail_price) as price_max,
         sum(quantity)     as seats_available,
         count(*)          as blocks
  from public.v_paciolan_listings
  group by snapshot_id
),
last_pull as (
  select distinct on (tenant, event_code)
         tenant, event_code, status as last_status,
         resolved_at as last_pulled_at, available_seats as last_available,
         error_msg as last_error
  from public.paciolan_pull_queue
  where resolved_at is not null
  order by tenant, event_code, resolved_at desc
),
openq as (
  select tenant, event_code,
         count(*) filter (where resolved_at is null and claimed_at is null)     as pending,
         count(*) filter (where resolved_at is null and claimed_at is not null) as inflight
  from public.paciolan_pull_queue
  group by tenant, event_code
)
select
  l.snapshot_id, l.tenant, l.event_code, l.source_url,
  l.event_name, l.venue_name, l.occurs_at, l.home_team, l.away_team,
  l.section_count, l.seat_count, l.captured_at,
  -- mapping to the canonical AQ hub (xref wins; snapshot columns as fallback)
  coalesce(x.tevo_event_id, l.tevo_event_id)         as map_tevo_event_id,
  coalesce(x.aq_short_event_id, l.aq_short_event_id) as map_aq_short_event_id,
  x.confidence                                       as map_confidence,
  x.method                                           as map_method,
  (coalesce(x.tevo_event_id, l.tevo_event_id) is not null) as mapped,
  -- face price band + live availability from the listing view
  f.getin, f.price_max, f.seats_available, f.blocks,
  -- pull-loop health for this event
  p.last_status, p.last_pulled_at, p.last_available, p.last_error,
  coalesce(o.pending, 0)  as pending,
  coalesce(o.inflight, 0) as inflight,
  -- autonomous-driver target state
  t.active            as target_active,
  t.pull_interval_min as pull_interval_min,
  t.last_enqueued_at  as last_enqueued_at
from latest l
left join public.paciolan_event_xref  x on x.tenant = l.tenant and x.event_code = l.event_code
left join face                         f on f.snapshot_id = l.snapshot_id
left join last_pull                    p on p.tenant = l.tenant and p.event_code = l.event_code
left join openq                        o on o.tenant = l.tenant and o.event_code = l.event_code
left join public.paciolan_pull_targets t on t.tenant = l.tenant and t.event_code = l.event_code;

comment on view public.v_paciolan_events is
  'D0 PACIOLAN tab URL layer: one row per captured (tenant,event_code) — latest snapshot, face get-in/band + live availability (v_paciolan_listings), AQ mapping (paciolan_event_xref), and pull-loop health (last status/pulled/pending/inflight + target state). Browser twin of the axs_events enrichment. Service-role read (paciolan_* are RLS-locked).';

-- ---- 2) health screen: one-row rollup of the autonomous pull loop -----------
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
  max(claimed_at) filter (where resolved_at is null)                               as oldest_inflight_claim
from public.paciolan_pull_queue;

comment on view public.v_paciolan_pull_health is
  'D0 PACIOLAN tab health screen: single-row rollup of the autonomous pull loop — active targets, total captures, live queue depth (pending/inflight), and 24h outcome mix (ok/empty/error/expired) + freshness. Twin of the AXS pull-health surface. Service-role read.';

-- ---- grants: views are read by the service-role backend (RLS-locked base) ----
grant select on public.v_paciolan_events      to service_role;
grant select on public.v_paciolan_pull_health to service_role;
