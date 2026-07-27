-- Cowork migration. Captured into git by code (auditor) on 2026-05-08.
-- Originally applied to prod 2026-05-06 19:03 UTC.
--
-- Layered zone derivation:
--   1. performer_zone_rules (curated, manually maintained)
--   2. zone_rules (global keyword/regex fallback for sections in performers we haven't curated yet)
--   3. digit-prefix tier ('100s (lower)' .. '500s (upper)')
--   4. 'unmapped' if all else fails

-- ---- Tier 2: keyword/regex fallback ------------------------------------------
create table if not exists zone_rules (
  id              bigserial primary key,
  match_type      text    not null check (match_type in ('exact','prefix','suffix','substring','regex')),
  section_pattern text    not null,
  zone            text    not null,
  priority        integer not null default 0,
  notes           text,
  active          boolean not null default true,
  created_at      timestamptz not null default now()
);
alter table zone_rules enable row level security;
create index if not exists idx_zone_rules_active_priority on zone_rules (active, priority desc);

insert into zone_rules (match_type, section_pattern, zone, priority, notes) values
  ('regex',     '^CRT(\d|\s|$)',  'courtside',     100, 'NBA / arena courtside (CRT, CRT2, CRT 5)'),
  ('substring', 'courtside',      'courtside',      90, 'any courtside wording'),
  ('exact',     'Pinstripe Pass', 'standing',      100, 'Yankees standing access'),
  ('substring', 'SRO',            'standing',       80, 'standing room only'),
  ('substring', 'Pass',           'standing',       30, 'pass-style standing access'),
  ('prefix',    'UPPER BLEACHER', 'bleacher',       60, 'more specific than BLEACHER'),
  ('prefix',    'BLEACHER',       'bleacher',       50, ''),
  ('prefix',    'GRANDSTAND',     'grandstand',     50, ''),
  ('prefix',    'LOGE',           'loge',           50, 'arena loge tier'),
  ('prefix',    'BAL',            'balcony',        50, ''),
  ('prefix',    'BOX',            'box',            50, ''),
  ('regex',     '^PR\d+$',        'premium row',    50, 'Yankees premium rows'),
  ('substring', 'Suite',          'suite',          30, ''),
  ('substring', 'Lounge',         'club',           30, ''),
  ('substring', 'Club',           'club',           30, '')
on conflict do nothing;

create or replace function derive_zone_fallback(p_section text, p_row text default null)
returns text
language plpgsql
stable
as $func$
declare
  v_zone   text;
  v_digits text;
begin
  if p_section is null then return null; end if;

  select zone into v_zone
  from zone_rules
  where active = true
    and case match_type
      when 'exact'     then p_section = section_pattern
      when 'prefix'    then p_section ilike (section_pattern || '%')
      when 'suffix'    then p_section ilike ('%' || section_pattern)
      when 'substring' then p_section ilike ('%' || section_pattern || '%')
      when 'regex'     then p_section ~* section_pattern
      else false
    end
  order by priority desc, id desc
  limit 1;
  if v_zone is not null then return v_zone; end if;

  v_digits := (regexp_match(p_section, '^(\d+)'))[1];
  if v_digits is null then
    v_digits := (regexp_match(p_section, '(\d+)'))[1];
  end if;
  if v_digits is null then return null; end if;

  return case
    when v_digits::int between 1   and 199 then '100s (lower)'
    when v_digits::int between 200 and 299 then '200s (club)'
    when v_digits::int between 300 and 399 then '300s (upper)'
    when v_digits::int between 400 and 499 then '400s (upper)'
    when v_digits::int >= 500              then '500s (upper)'
    else null
  end;
end
$func$;

revoke all on function derive_zone_fallback(text, text) from public;
grant execute on function derive_zone_fallback(text, text) to service_role;
grant execute on function derive_zone_fallback(text, text) to authenticated;

-- ---- Rollup: curated → fallback → unmapped, with source tagging --------------
drop function if exists get_event_zones_rollup(bigint, boolean);

create or replace function get_event_zones_rollup(
  p_event_id   bigint,
  p_owned_only boolean default true
) returns table (
  zone        text,
  source      text,        -- 'curated' | 'fallback' | 'unmapped'
  tickets     bigint,
  min_retail  numeric,
  max_retail  numeric
)
language sql
stable
as $func$
  with latest as (
    select max(captured_at) as captured_at
    from listings_snapshots where event_id = p_event_id
  ),
  ev as (
    select id as event_id, primary_performer_id as performer_id, venue_id
    from events where id = p_event_id
  ),
  zoned as (
    select
      coalesce(curated.name, fb.zone, 'unmapped') as zone,
      case
        when curated.name is not null then 'curated'
        when fb.zone is not null      then 'fallback'
        else                               'unmapped'
      end                                         as source,
      coalesce(curated.display_order, 99998 + case when fb.zone is null then 1 else 0 end) as ord,
      l.quantity, l.retail_price
    from listings_snapshots l
    join latest using (captured_at)
    cross join ev
    left join lateral (
      select pz.name, pz.display_order
      from performer_zone_rules r
      join performer_zones pz on pz.id = r.zone_id
      where pz.performer_id = ev.performer_id
        and pz.venue_id     = ev.venue_id
        and r.section_from <= l.section
        and r.section_to   >= l.section
        and (
          r.row_from is null
          or (l.row is not null and l.row between r.row_from and r.row_to)
        )
      order by pz.display_order asc, pz.id asc
      limit 1
    ) curated on true
    left join lateral (
      select derive_zone_fallback(l.section, l.row) as zone
    ) fb on curated.name is null
    where l.event_id = p_event_id
      and l.is_ancillary = false
      and (p_owned_only = false or l.is_owned = true)
  )
  select
    zone,
    source,
    sum(quantity)::bigint                          as tickets,
    round(min(retail_price)::numeric, 2)           as min_retail,
    round(max(retail_price)::numeric, 2)           as max_retail
  from zoned
  group by zone, source, ord
  order by ord, zone;
$func$;

revoke all on function get_event_zones_rollup(bigint, boolean) from public;
grant execute on function get_event_zones_rollup(bigint, boolean) to service_role;
