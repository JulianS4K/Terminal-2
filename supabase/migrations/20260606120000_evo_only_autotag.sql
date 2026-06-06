-- Migration 20260606120000 · lane:D0 · writes: evo_only_patterns (new table) +
--   tag_evo_only_events() + cron_policy row + cron evo_only_autotag_daily
--   · reads: events, aq_event_map · seeds: aq_event_map (aq_source='evo_only')
--
-- ## Already applied to prod · Applied via MCP 2026-06-06 (operator-authorized)
--
-- EVO-only auto-tagging.
-- Some TEvo events are intentionally NOT carried on any cross-source feed
-- (SG / SeatHero / Vivid / Ticketmaster) -- e.g. Las Vegas Sphere residencies
-- ("The Wizard of Oz at Sphere") and the MSG "Tour Experience" (a building tour,
-- not resale inventory). These inflate the "unmapped" gap count and look like
-- bridge failures when they are not. This tags them as aq_source='evo_only' so
-- the unmapped/discovery surfaces can exclude intentional EVO-only inventory:
--   ... AND aq_source IS DISTINCT FROM 'evo_only'
--
-- An extensible allowlist (evo_only_patterns) drives the tagger so new runs can
-- be classified by adding a row -- no code change. A daily cron (08:45 UTC, right
-- after evo_discover_new_events @ 08:00) seeds hub rows for new matches.
--
-- Backfill of the two seed runs (669 rows: 568 Wizard of Oz at Sphere + 101 MSG
-- Tour Experience) was applied live the same day via the same INSERT shape.

-- 1) Extensible allowlist of EVO-only patterns
create table if not exists public.evo_only_patterns (
  id                bigint generated always as identity primary key,
  performer_pattern text,
  venue_pattern     text,
  note              text,
  enabled           boolean not null default true,
  created_at        timestamptz not null default now(),
  constraint evo_only_patterns_at_least_one_pattern
    check (performer_pattern is not null or venue_pattern is not null)
);

comment on table public.evo_only_patterns is
  'Allowlist driving tag_evo_only_events(): performer/venue ILIKE patterns whose '
  'matching TEvo events are intentionally EVO-only (no cross-source twin exists).';

-- 2) Seed the two confirmed runs
insert into public.evo_only_patterns (performer_pattern, venue_pattern, note)
select v.pp, v.vp, v.note from (values
  ('%wizard of oz%', '%sphere%',                'Wizard of Oz at Sphere residency (Las Vegas) - not on SG/SH/VD/TM'),
  ('%tour experience%', '%madison square garden%', 'MSG Tour Experience (building tour, not resale inventory)')
) as v(pp, vp, note)
where not exists (
  select 1 from public.evo_only_patterns p
  where coalesce(p.performer_pattern,'') = coalesce(v.pp,'')
    and coalesce(p.venue_pattern,'')     = coalesce(v.vp,''));

-- 3) Tagger: seed hub rows for new matches lacking any aq_event_map row
create or replace function public.tag_evo_only_events()
returns integer
language plpgsql
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_inserted integer := 0;
begin
  if not public.cron_should_fire('evo_only_autotag_daily') then
    return 0;
  end if;

  with ins as (
    insert into public.aq_event_map
      (aq_short_event_id, event_name, venue_name, event_date, city, state,
       performer, category, tevo_event_id, aq_source)
    select
      'EVO-'||e.id, e.name, e.venue_name,
      left(e.occurs_at_local,19)::timestamp,
      nullif(trim(split_part(e.venue_location, ',', 1)),''),
      upper(trim(split_part(e.venue_location, ',',
            array_length(string_to_array(e.venue_location,','),1)))),
      e.primary_performer_name, e.event_type, e.id, 'evo_only'
    from public.events e
    where e.occurs_at_local is not null
      and not exists (select 1 from public.aq_event_map a where a.tevo_event_id = e.id)
      and exists (
        select 1 from public.evo_only_patterns p
        where p.enabled
          and (p.performer_pattern is null or e.primary_performer_name ilike p.performer_pattern)
          and (p.venue_pattern     is null or e.venue_name            ilike p.venue_pattern)
      )
    returning 1
  )
  select count(*) into v_inserted from ins;

  return v_inserted;
end;
$fn$;

-- 4) Cron policy (gate): once-daily, small safety budget
insert into public.cron_policy
  (jobname, peak_hours_et, peak_min_interval_min, offpeak_min_interval_min,
   work_check_sql, daily_max_fires, enabled, notes)
values
  ('evo_only_autotag_daily', '{}'::int[], 600, 600, null, 2, true,
   'Daily after evo_discover_new_events: tag new residency/attraction runs as aq_source=evo_only')
on conflict (jobname) do nothing;

-- 5) Schedule (08:45 UTC, right after evo_discover_new_events @ 08:00)
-- select cron.schedule('evo_only_autotag_daily', '45 8 * * *',
--   $cron$ select public.tag_evo_only_events(); $cron$);
