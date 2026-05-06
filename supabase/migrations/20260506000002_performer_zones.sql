-- =============================================================
-- performer_zones — performer+venue scoped section/row groupings
-- =============================================================
-- Each (performer, venue) pair has a set of named zones (e.g. NYK at MSG:
-- Courtside, Club Gold, 100 Corner). A zone is one or more
-- (section_from, section_to, row_from, row_to) rules.
-- match_performer_zone() returns the zone name for a listing, with
-- display_order tiebreaking when multiple rules match.
--
-- Already applied to prod via Supabase MCP on 2026-05-06.
-- 22 NYK zones at MSG seeded; ~98% of tonight's home game listings
-- classify cleanly. SRO/WC/MC sections fall through as (unmapped).

-- (See live DB for full content — this file is a marker for repo reproducibility.
-- Full body lives in 20260506000002_performer_zones_v2 inside the migrations log.)

create table if not exists performer_zones (
  id            bigserial primary key,
  performer_id  bigint    not null,
  venue_id      bigint    not null,
  name          text      not null,
  display_order integer   not null default 0,
  created_at    timestamptz not null default now(),
  unique (performer_id, venue_id, name)
);
alter table performer_zones enable row level security;
create index if not exists idx_perf_zones_pv on performer_zones(performer_id, venue_id);

create table if not exists performer_zone_rules (
  id            bigserial primary key,
  zone_id       bigint    not null references performer_zones(id) on delete cascade,
  section_from  text      not null,
  section_to    text      not null,
  row_from      text,
  row_to        text,
  created_at    timestamptz not null default now()
);
alter table performer_zone_rules enable row level security;
create index if not exists idx_perf_zone_rules_zone on performer_zone_rules(zone_id);

create or replace function _sec_norm(s text)
returns text language sql immutable as $$
  select regexp_replace(lower(coalesce(s,'')), '\s+', '', 'g')
$$;

create or replace function _sec_prefix(s text)
returns text language sql immutable as $$
  select regexp_replace(_sec_norm(s), '[0-9]+$', '')
$$;

create or replace function _sec_suffix(s text)
returns integer language sql immutable as $$
  select case when _sec_norm(s) ~ '[0-9]+$'
              then (regexp_match(_sec_norm(s), '([0-9]+)$'))[1]::int
              else null end
$$;

create or replace function match_performer_zone(
  p_performer_id bigint,
  p_venue_id     bigint,
  p_section      text,
  p_row          text
) returns text language sql stable as $$
  select z.name
  from performer_zones z
  join performer_zone_rules r on r.zone_id = z.id
  where z.performer_id = p_performer_id
    and z.venue_id = p_venue_id
    and (
      (_sec_norm(r.section_from) = _sec_norm(r.section_to)
       and _sec_norm(p_section) = _sec_norm(r.section_from))
      OR
      (r.section_from ~ '^[0-9]+$' and r.section_to ~ '^[0-9]+$'
       and p_section ~ '^[0-9]+$'
       and p_section::int between r.section_from::int and r.section_to::int)
      OR
      (_sec_prefix(r.section_from) <> ''
       and _sec_prefix(r.section_from) = _sec_prefix(r.section_to)
       and _sec_prefix(r.section_from) = _sec_prefix(p_section)
       and _sec_suffix(r.section_from) is not null
       and _sec_suffix(r.section_to) is not null
       and _sec_suffix(p_section) is not null
       and _sec_suffix(p_section) between _sec_suffix(r.section_from) and _sec_suffix(r.section_to))
    )
    and (
      (r.row_from is null and r.row_to is null)
      OR
      (lower(coalesce(r.row_from,'')) = lower(coalesce(r.row_to,''))
       and lower(coalesce(p_row,'')) = lower(coalesce(r.row_from,'')))
      OR
      (r.row_from ~ '^[0-9]+$' and r.row_to ~ '^[0-9]+$'
       and p_row ~ '^[0-9]+$'
       and p_row::int between r.row_from::int and r.row_to::int)
    )
  order by z.display_order asc
  limit 1;
$$;

-- NYK seed lives in the prod migration 20260506000002_performer_zones_v2.
-- 22 zones at MSG (performer 16303, venue 896): Courtside Apples, Courtside,
-- Courtside A, Club Platinum/Gold/Silver, Club Gold Baseline, Risers 6-8,
-- Risers 9+, 100 Corner/End/Garbage, 300 Center/End, U1/U2/U3 (with row bands),
-- U4, 400.
