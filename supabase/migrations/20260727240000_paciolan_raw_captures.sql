-- Migration 20260727240000 · level:data-collection · lane:D6 (author) → A1 (apply) · writes:paciolan_raw_captures,paciolan_ingest(jsonb)[replace],paciolan_ingest_secure(text,jsonb)[replace],paciolan_pull_sweep()[replace],v_paciolan_events[replace],v_paciolan_pull_health[replace] · reads:paciolan_event_snapshots,paciolan_pull_queue · pre:20260727200000 (ingest), 20260727220000 (sweep), 20260727230000 (views) · auth:OPERATOR-APPROVAL REQUIRED before apply (SECDEF ingest replace; new table)
--
-- Format-drift safety net: "pull all site data because formats change." Rather
-- than trust the parser is right forever, keep the WHOLE rendered page + every
-- inline JSON blob with each capture, so a layout change never silently loses
-- data — we can re-parse history server-side — and so drift (raw present but 0
-- parsed) is a visible signal, not a silent "0 seats". The extension only sends
-- raw on UPLOAD captures (never the local buffer); RULE 2 unchanged (eVenue is
-- only READ).

-- ---- 1) raw store: one row per capture that carried raw ---------------------
create table if not exists public.paciolan_raw_captures (
  id              bigint generated always as identity primary key,
  snapshot_id     bigint not null references public.paciolan_event_snapshots(id) on delete cascade,
  captured_at     timestamptz not null default now(),
  tenant          text,
  event_code      text,
  source_url      text,
  raw_html        text,                 -- full document.documentElement.outerHTML (extension caps ~2 MB)
  raw_blobs       jsonb,                -- inline JSON: ld+json / application/json / __NEXT_DATA__
  html_bytes      int,                  -- pre-truncation size, for drift/size tracking
  html_truncated  boolean default false,
  parsed_seats    int,                  -- what the parser got from this capture (0 = drift signal)
  parsed_sections int
);
create index if not exists idx_paciolan_raw_snapshot on public.paciolan_raw_captures (snapshot_id);
create index if not exists idx_paciolan_raw_captured  on public.paciolan_raw_captures (captured_at desc);
alter table public.paciolan_raw_captures enable row level security;  -- service-role only
comment on table public.paciolan_raw_captures is
  'Raw eVenue page + inline JSON per capture (format-drift safety net). Kept so a Paciolan layout change never loses data — re-parse from here — and so drift (parsed_seats=0 AND parsed_sections=0 while raw present) is a visible signal. Written by paciolan_ingest; pruned to 14d by paciolan_pull_sweep.';
grant select on public.paciolan_raw_captures to service_role;

-- ---- 2) ingest: also persist raw when the capture carries it ----------------
-- CREATE OR REPLACE of paciolan_ingest (mig 20260727200000) — identical body,
-- plus a raw_captures insert at the end when raw_html/raw_blobs are present.
create or replace function public.paciolan_ingest(p_payload jsonb)
returns bigint
language plpgsql security definer set search_path = public as $$
declare
  v_snap_id bigint;
  v_seat_count int;
  v_section_count int;
begin
  insert into public.paciolan_event_snapshots (
    platform, tenant, event_code, source_url, event_name, venue_name,
    occurs_at, home_team, away_team, section_count, seat_count, raw
  ) values (
    coalesce(p_payload->>'platform', 'paciolan'),
    p_payload->>'tenant', p_payload->>'event_code', p_payload->>'source_url',
    p_payload->>'event_name', p_payload->>'venue_name',
    nullif(p_payload->>'occurs_at','')::timestamptz,
    p_payload->>'home_team', p_payload->>'away_team',
    coalesce(jsonb_array_length(p_payload->'sections'), 0),
    coalesce(jsonb_array_length(p_payload->'seats'), 0),
    p_payload - 'sections' - 'seats' - 'raw_html' - 'raw_blobs'
  ) returning id into v_snap_id;

  insert into public.paciolan_section_snapshots (
    snapshot_id, tenant, level, section_label, pct_available, disabled, raw
  )
  select v_snap_id, p_payload->>'tenant', s->>'level', s->>'section_label',
         nullif(s->>'pct_available','')::numeric,
         coalesce((s->>'disabled')::boolean, false), s
  from jsonb_array_elements(coalesce(p_payload->'sections', '[]'::jsonb)) s;
  get diagnostics v_section_count = row_count;

  insert into public.paciolan_seat_snapshots (
    snapshot_id, tenant, level, section_label, row_label, seat_number,
    seat_no, seat_type, price, is_ga, available, data_seat_key, raw_item
  )
  select v_snap_id, p_payload->>'tenant', st->>'level', st->>'section_label',
         st->>'row_label', st->>'seat_number', nullif(st->>'seat_no','')::int,
         st->>'seat_type', nullif(st->>'price','')::numeric,
         coalesce((st->>'is_ga')::boolean, false),
         coalesce((st->>'available')::boolean, true),
         st->>'data_seat_key', st
  from jsonb_array_elements(coalesce(p_payload->'seats', '[]'::jsonb)) st;
  get diagnostics v_seat_count = row_count;

  update public.paciolan_event_snapshots
     set section_count = v_section_count, seat_count = v_seat_count
   where id = v_snap_id;

  -- raw safety net: keep the full page + inline JSON when the capture sent it.
  if (p_payload ? 'raw_html') or (p_payload ? 'raw_blobs') then
    insert into public.paciolan_raw_captures (
      snapshot_id, tenant, event_code, source_url, raw_html, raw_blobs,
      html_bytes, html_truncated, parsed_seats, parsed_sections
    ) values (
      v_snap_id, p_payload->>'tenant', p_payload->>'event_code',
      p_payload->>'source_url', p_payload->>'raw_html',
      coalesce(p_payload->'raw_blobs', '[]'::jsonb),
      nullif(p_payload->>'raw_html_bytes','')::int,
      coalesce((p_payload->>'raw_html_truncated')::boolean, false),
      v_seat_count, v_section_count
    );
  end if;

  return v_snap_id;
end;
$$;

-- ---- 3) secure wrapper: allow a raw-only capture (the drift case) -----------
-- CREATE OR REPLACE of paciolan_ingest_secure (mig 20260727190000) — same secret
-- gate + seat cap, but the "empty payload" reject now permits a capture that
-- carries raw_html even with 0 seats/sections (exactly the format-drift signal).
create or replace function public.paciolan_ingest_secure(p_secret text, p_payload jsonb)
returns bigint
language plpgsql security definer set search_path = public as $$
declare
  v_expected text;
  v_n int;
begin
  select secret into v_expected from public.paciolan_ingest_config where id = 1;
  if v_expected is null then
    raise exception 'paciolan ingest not configured';
  end if;
  if p_secret is null or length(p_secret) <> length(v_expected)
     or not (p_secret = v_expected) then
    raise exception 'unauthorized' using errcode = '28000';
  end if;
  v_n := coalesce(jsonb_array_length(p_payload->'seats'), 0)
       + coalesce(jsonb_array_length(p_payload->'sections'), 0);
  -- empty only if there is nothing parsed AND no raw page to keep (drift ok).
  if v_n = 0 and coalesce(p_payload->>'raw_html', '') = '' then
    raise exception 'empty payload';
  end if;
  if coalesce(jsonb_array_length(p_payload->'seats'), 0) > 20000 then
    raise exception 'payload too large';
  end if;
  return public.paciolan_ingest(p_payload);
end;
$$;

-- ---- 4) sweep: also prune old raw (heavy) --------------------------------
-- CREATE OR REPLACE of paciolan_pull_sweep (mig 20260727220000) — same body plus
-- a 14-day retention prune of paciolan_raw_captures (raw HTML is bulky).
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

  update public.paciolan_pull_queue
     set resolved_at = v_now, status = 'expired', error_msg = 'stale, never claimed'
   where resolved_at is null and claimed_at is null
     and created_at < v_now - interval '1 day';

  delete from public.paciolan_pull_queue
   where resolved_at is not null and created_at < v_now - interval '7 days';

  -- raw HTML is bulky — keep 14 days for re-parsing after a format change.
  delete from public.paciolan_raw_captures
   where captured_at < v_now - interval '14 days';
end $$;

-- ---- 5) health screen: add raw/drift signals -------------------------------
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
  -- drift: raw kept but the parser found nothing — the layout likely changed.
  (select count(*) from public.paciolan_raw_captures
     where captured_at >= now() - interval '24 hours'
       and coalesce(parsed_seats, 0) = 0 and coalesce(parsed_sections, 0) = 0)     as drift_24h
from public.paciolan_pull_queue;

comment on view public.v_paciolan_pull_health is
  'D0 PACIOLAN tab health screen: single-row rollup of the autonomous pull loop — active targets, total captures, live queue depth, 24h outcome mix (ok/empty/error/expired), freshness, plus raw-capture total + format-drift count (raw present but 0 parsed in 24h). Service-role read.';

-- ---- 6) URL layer: add raw-captured + format-drift flags --------------------
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
),
raw as (
  select snapshot_id, count(*) as raw_captures,
         max(html_bytes) as raw_bytes, bool_or(html_truncated) as raw_truncated
  from public.paciolan_raw_captures
  group by snapshot_id
)
select
  l.snapshot_id, l.tenant, l.event_code, l.source_url,
  l.event_name, l.venue_name, l.occurs_at, l.home_team, l.away_team,
  l.section_count, l.seat_count, l.captured_at,
  coalesce(x.tevo_event_id, l.tevo_event_id)         as map_tevo_event_id,
  coalesce(x.aq_short_event_id, l.aq_short_event_id) as map_aq_short_event_id,
  x.confidence                                       as map_confidence,
  x.method                                           as map_method,
  (coalesce(x.tevo_event_id, l.tevo_event_id) is not null) as mapped,
  f.getin, f.price_max, f.seats_available, f.blocks,
  p.last_status, p.last_pulled_at, p.last_available, p.last_error,
  coalesce(o.pending, 0)  as pending,
  coalesce(o.inflight, 0) as inflight,
  t.active            as target_active,
  t.pull_interval_min as pull_interval_min,
  t.last_enqueued_at  as last_enqueued_at,
  (coalesce(r.raw_captures, 0) > 0)          as raw_captured,
  r.raw_bytes,
  -- format drift: raw kept for this event's latest capture, but 0 parsed rows.
  (coalesce(r.raw_captures, 0) > 0
     and coalesce(l.seat_count, 0) = 0
     and coalesce(l.section_count, 0) = 0)   as format_drift
from latest l
left join public.paciolan_event_xref  x on x.tenant = l.tenant and x.event_code = l.event_code
left join face                         f on f.snapshot_id = l.snapshot_id
left join last_pull                    p on p.tenant = l.tenant and p.event_code = l.event_code
left join openq                        o on o.tenant = l.tenant and o.event_code = l.event_code
left join public.paciolan_pull_targets t on t.tenant = l.tenant and t.event_code = l.event_code
left join raw                          r on r.snapshot_id = l.snapshot_id;

comment on view public.v_paciolan_events is
  'D0 PACIOLAN tab URL layer: one row per captured (tenant,event_code) — latest snapshot, face get-in/band + live availability, AQ mapping, pull-loop health, and raw-capture/format-drift flags (raw_captured, format_drift = raw kept but 0 parsed). Service-role read.';
