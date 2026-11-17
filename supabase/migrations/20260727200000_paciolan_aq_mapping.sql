-- Migration 20260727200000 · level:data-collection · lane:D6 (author) → A1 (apply) · writes:paciolan_event_snapshots(+6 cols),paciolan_section/seat_snapshots(+tevo_event_id),paciolan_ingest(jsonb)[replace],paciolan_event_xref,paciolan_aq_match(),paciolan_apply_aq(),paciolan_unmapped_events(),paciolan_tevo_search_attempts,v_paciolan_vs_secondary · reads:events,aq_event_map,latest_event_metrics,cross_source_venue_resolve · pre:20260727190000 (paciolan base), 20260610020000 (axs_aq_match pattern mirrored), aq_event_map, cross_source_venue_resolve · auth:OPERATOR-APPROVAL REQUIRED before apply
--
-- Map Paciolan/eVenue events to the canonical cross-source hub the SAME way AXS
-- does: resolve each capture to aq_event_map.aq_short_event_id (+ tevo_event_id)
-- via venue+name+date scoring against public.events. Once mapped, EVO / SeatGeek
-- / StubHub listings for the same event join automatically (they all carry
-- aq_short_event_id; StubHub = aq_event_map.sh_event_id). paciolan_aq_match is a
-- 1:1 mirror of public.axs_aq_match. NEVER join raw Paciolan ids (PROJECT_BIBLE
-- §0) — always via the AQ mapper.

-- ---- 1) event metadata the matcher needs (name/date/venue/teams) ----------
alter table public.paciolan_event_snapshots
  add column if not exists occurs_at         timestamptz,
  add column if not exists home_team         text,
  add column if not exists away_team         text,
  add column if not exists tevo_venue_id     bigint,
  add column if not exists tevo_event_id     bigint,
  add column if not exists aq_short_event_id text;
alter table public.paciolan_section_snapshots add column if not exists tevo_event_id bigint;
alter table public.paciolan_seat_snapshots    add column if not exists tevo_event_id bigint;

-- ---- 2) ingest: also persist the scraped event metadata --------------------
-- CREATE OR REPLACE of the base paciolan_ingest (mig 20260727190000) that now
-- also stores occurs_at / home_team / away_team so the matcher has name+date.
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
    p_payload - 'sections' - 'seats'
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
  return v_snap_id;
end;
$$;

-- ---- 3) the cross-source xref (one row per Paciolan event) ------------------
create table if not exists public.paciolan_event_xref (
  tenant            text not null,
  event_code        text not null,
  tevo_event_id     bigint,
  aq_short_event_id text,
  confidence        numeric,
  method            text,
  matched_at        timestamptz not null default now(),
  primary key (tenant, event_code)
);
alter table public.paciolan_event_xref enable row level security;  -- service-role only
comment on table public.paciolan_event_xref is
  'Paciolan/eVenue event → canonical AQ hub. (tenant,event_code) → tevo_event_id + aq_short_event_id (the cross-source key EVO/SG/StubHub share). Populated by paciolan_apply_aq. Mirrors axs_events.aq_short_event_id.';

-- ---- 4) matcher — 1:1 mirror of public.axs_aq_match ------------------------
create or replace function public.paciolan_aq_match(
  p_tenant text, p_event_code text,
  p_date_window_hours integer default 48, p_min_score numeric default 0.45)
returns table(tevo_event_id bigint, aq_short_event_id text, confidence numeric, method text)
language plpgsql stable set search_path to 'public', 'extensions', 'pg_temp' as $$
declare
  v_name text; v_venue text; v_date timestamptz; v_tevo_venue bigint;
begin
  select coalesce(event_name, nullif(btrim(coalesce(away_team,'')||' '||coalesce(home_team,'')),'')),
         venue_name, occurs_at, tevo_venue_id
    into v_name, v_venue, v_date, v_tevo_venue
  from public.paciolan_event_snapshots
  where tenant = p_tenant and event_code = p_event_code
    and venue_name is not null and occurs_at is not null
  order by captured_at desc limit 1;
  if v_venue is null or v_date is null then return; end if;
  return query
  with cand as (
    select ev.id as tid,
           case when v_tevo_venue is not null and ev.venue_id = v_tevo_venue then 1.0
                when lower(btrim(ev.venue_name)) = lower(btrim(v_venue)) then 0.95
                else similarity(lower(coalesce(ev.venue_name,'')), lower(v_venue)) end as vscore,
           greatest(similarity(lower(coalesce(ev.name,'')), lower(coalesce(v_name,''))), 0) as nscore,
           abs(extract(epoch from (ev.occurs_at_local::timestamptz - v_date)))/3600.0 as dh
    from public.events ev
    where ev.occurs_at_local ~ '^\d{4}-\d{2}-\d{2}T'
      and ev.occurs_at_local::timestamptz between v_date - make_interval(hours=>p_date_window_hours)
                                              and v_date + make_interval(hours=>p_date_window_hours)
      and ( (v_tevo_venue is not null and ev.venue_id = v_tevo_venue)
            or lower(btrim(ev.venue_name)) = lower(btrim(v_venue))
            or similarity(lower(coalesce(ev.venue_name,'')), lower(v_venue)) >= 0.6 )
  ),
  scored as (
    select *, (0.45*vscore + 0.40*nscore + 0.15*greatest(0, 1 - dh/p_date_window_hours)) as score
    from cand
  )
  select s.tid,
         (select a.aq_short_event_id from public.aq_event_map a where a.tevo_event_id = s.tid limit 1),
         round(s.score::numeric,3),
         (case when s.vscore=1 and s.nscore>=0.5 then 'venue_id_name_date'
               when s.vscore=1 then 'venue_id_date'
               when s.nscore>=0.5 then 'venue_name_date'
               else 'venue_date_proximity' end)::text
  from scored s
  where s.score >= p_min_score
    and (s.nscore >= 0.20 or (s.vscore >= 0.999 and s.dh <= 2))  -- name-overlap guard
    and s.dh <= 12                                               -- date-precision guard
  order by s.score desc, s.dh asc limit 1;
end $$;

-- ---- 5) apply — resolve venue, match, upsert xref, propagate ---------------
create or replace function public.paciolan_apply_aq(p_tenant text, p_event_code text)
returns table(tevo_event_id bigint, aq_short_event_id text, confidence numeric, method text)
language plpgsql security definer set search_path = public as $$
declare
  v_venue text; v_tevo bigint; v_aq text; v_conf numeric; v_method text;
begin
  select venue_name into v_venue from public.paciolan_event_snapshots
   where tenant = p_tenant and event_code = p_event_code
   order by captured_at desc limit 1;
  -- best-effort venue → tevo_venue_id (the resolver may be absent in a test DB;
  -- swallow and let the matcher fall back to venue-name similarity).
  if v_venue is not null then
    begin
      update public.paciolan_event_snapshots
         set tevo_venue_id = coalesce(tevo_venue_id,
                                      public.cross_source_venue_resolve(v_venue, null, null))
       where tenant = p_tenant and event_code = p_event_code;
    exception when others then null;
    end;
  end if;

  select m.tevo_event_id, m.aq_short_event_id, m.confidence, m.method
    into v_tevo, v_aq, v_conf, v_method
  from public.paciolan_aq_match(p_tenant, p_event_code) m limit 1;
  if v_tevo is null and v_aq is null then return; end if;

  insert into public.paciolan_event_xref(tenant, event_code, tevo_event_id,
                                         aq_short_event_id, confidence, method, matched_at)
  values (p_tenant, p_event_code, v_tevo, v_aq, v_conf, v_method, now())
  on conflict (tenant, event_code) do update
    set tevo_event_id=excluded.tevo_event_id, aq_short_event_id=excluded.aq_short_event_id,
        confidence=excluded.confidence, method=excluded.method, matched_at=now();

  -- propagate onto the snapshot rows (join convenience, like axs_apply_aq)
  update public.paciolan_event_snapshots
     set tevo_event_id=v_tevo, aq_short_event_id=v_aq
   where tenant=p_tenant and event_code=p_event_code;
  update public.paciolan_seat_snapshots se set tevo_event_id=v_tevo
    from public.paciolan_event_snapshots ev
   where se.snapshot_id=ev.id and ev.tenant=p_tenant and ev.event_code=p_event_code;
  update public.paciolan_section_snapshots se set tevo_event_id=v_tevo
    from public.paciolan_event_snapshots ev
   where se.snapshot_id=ev.id and ev.tenant=p_tenant and ev.event_code=p_event_code;

  return query select v_tevo, v_aq, v_conf, v_method;
end $$;

-- ---- 6) cold-search scaffold (events not yet in public.events) -------------
-- SQL half only: the attempts ledger + the unmapped-events feed. The TEvo
-- search itself is an edge fn (TEVO creds, deploy) — an A1 follow-up, exactly
-- like axs_to_tevo_search_bridge (edge fn deployed separately).
create table if not exists public.paciolan_tevo_search_attempts (
  tenant       text not null,
  event_code   text not null,
  attempted_at timestamptz not null default now(),
  found_tevo   bigint,
  note         text,
  primary key (tenant, event_code, attempted_at)
);
alter table public.paciolan_tevo_search_attempts enable row level security;

create or replace view public.paciolan_unmapped_events as
select distinct on (e.tenant, e.event_code)
       e.tenant, e.event_code, e.event_name, e.venue_name, e.occurs_at
from public.paciolan_event_snapshots e
left join public.paciolan_event_xref x
  on x.tenant=e.tenant and x.event_code=e.event_code and x.tevo_event_id is not null
where x.tenant is null and e.venue_name is not null and e.occurs_at is not null
order by e.tenant, e.event_code, e.captured_at desc;
comment on view public.paciolan_unmapped_events is
  'Paciolan events with no tevo_event_id yet — the feed for the TEvo cold-search bridge (edge fn, A1 follow-up). Mirrors the axs_to_tevo_search flow.';

-- ---- 7) primary(face) vs secondary spread ---------------------------------
create or replace view public.v_paciolan_vs_secondary as
with latest as (
  select distinct on (tenant, event_code)
         id as snapshot_id, tenant, event_code, tevo_event_id, aq_short_event_id,
         event_name, venue_name, occurs_at
  from public.paciolan_event_snapshots
  where tevo_event_id is not null
  order by tenant, event_code, captured_at desc
),
face as (
  select l.snapshot_id, min(vl.retail_price) as face_getin, sum(vl.quantity) as face_qty
  from latest l
  join public.v_paciolan_listings vl on vl.snapshot_id = l.snapshot_id
  group by l.snapshot_id
)
select l.tenant, l.event_code, l.tevo_event_id, l.aq_short_event_id,
       l.event_name, l.venue_name, l.occurs_at,
       f.face_getin, f.face_qty,
       m.getin_price                       as secondary_getin,
       (m.getin_price - f.face_getin)      as secondary_premium,
       a.sg_event_id, a.sh_event_id, a.vivid_event_id, a.tm_event_id
from latest l
left join face f                       on f.snapshot_id = l.snapshot_id
left join public.latest_event_metrics m on m.event_id = l.tevo_event_id
left join public.aq_event_map a         on a.aq_short_event_id = l.aq_short_event_id;
comment on view public.v_paciolan_vs_secondary is
  'Paciolan/eVenue PRIMARY (box-office face get-in) vs SECONDARY get-in (latest_event_metrics) for the mapped event, plus the cross-source ids (sg/sh=StubHub/vivid/tm) from aq_event_map. secondary_premium = resale over face. Mirrors the AXS primary-vs-secondary spread.';

-- ---- grants: matching + xref are service-role only (called by A1/cron) -----
revoke all on function public.paciolan_aq_match(text, text, integer, numeric) from public;
revoke all on function public.paciolan_apply_aq(text, text) from public;
grant execute on function public.paciolan_aq_match(text, text, integer, numeric) to service_role;
grant execute on function public.paciolan_apply_aq(text, text) to service_role;
