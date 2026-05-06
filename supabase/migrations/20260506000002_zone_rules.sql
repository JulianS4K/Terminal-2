-- Zone derivation: replace the inline regex zone bucketing with a rule-driven
-- table + function. Lets us add venue- or event-specific zones without code
-- changes — just INSERT a row into zone_rules.
--
-- Match priority (highest wins, ties broken by id desc):
--   scope='event'  → priority + 30000
--   scope='venue'  → priority + 20000
--   scope='global' → priority + 10000
-- If no rule matches, derive_zone falls back to any digit run inside the section
-- (so '160' → '100s (lower)', 'BAL301' → '300s (upper)', 'BOX534' → '500s (upper)').
-- If even that fails, returns 'special'.

create table if not exists zone_rules (
  id              bigserial primary key,
  scope           text    not null check (scope in ('global','venue','event')),
  venue_id        bigint,
  event_id        bigint,
  match_type      text    not null check (match_type in ('exact','prefix','suffix','substring','regex')),
  section_pattern text    not null,
  row_pattern     text,                                          -- optional row regex
  zone            text    not null,
  priority        integer not null default 0,
  notes           text,
  active          boolean not null default true,
  created_at      timestamptz not null default now(),
  -- scope/scope_id sanity
  check (
    (scope = 'global' and venue_id is null and event_id is null)
    or (scope = 'venue' and venue_id is not null and event_id is null)
    or (scope = 'event' and event_id is not null)
  )
);
alter table zone_rules enable row level security;
create index if not exists idx_zone_rules_scope_active   on zone_rules (scope, active);
create index if not exists idx_zone_rules_venue          on zone_rules (venue_id) where venue_id is not null;
create index if not exists idx_zone_rules_event          on zone_rules (event_id) where event_id is not null;

-- derive_zone: section + row + scope context → zone string
create or replace function derive_zone(
  p_section text,
  p_row     text default null,
  p_venue_id bigint default null,
  p_event_id bigint default null
) returns text
language plpgsql
stable
as $func$
declare
  v_zone        text;
  v_digits      text;
begin
  if p_section is null then return null; end if;

  select zone into v_zone
  from (
    select
      zone,
      case scope
        when 'event'  then priority + 30000
        when 'venue'  then priority + 20000
        else               priority + 10000
      end as eff_priority,
      id
    from zone_rules
    where active = true
      and (
        scope = 'global'
        or (scope = 'venue' and venue_id = p_venue_id)
        or (scope = 'event' and event_id = p_event_id)
      )
      and (
        case match_type
          when 'exact'     then p_section = section_pattern
          when 'prefix'    then p_section ilike (section_pattern || '%')
          when 'suffix'    then p_section ilike ('%' || section_pattern)
          when 'substring' then p_section ilike ('%' || section_pattern || '%')
          when 'regex'     then p_section ~* section_pattern
          else false
        end
      )
      and (row_pattern is null or (p_row is not null and p_row ~* row_pattern))
    order by eff_priority desc, id desc
    limit 1
  ) m;

  if v_zone is not null then return v_zone; end if;

  -- Fallback: leading digits, then any digit run anywhere in the section
  v_digits := (regexp_match(p_section, '^(\d+)'))[1];
  if v_digits is null then
    v_digits := (regexp_match(p_section, '(\d+)'))[1];
  end if;
  if v_digits is null then
    return 'special';
  end if;

  return case
    when v_digits::int between 1   and 199 then '100s (lower)'
    when v_digits::int between 200 and 299 then '200s (club)'
    when v_digits::int between 300 and 399 then '300s (upper)'
    when v_digits::int between 400 and 499 then '400s (upper)'
    when v_digits::int >= 500 then '500s (upper)'
    else 'other'
  end;
end
$func$;

-- Seed: global keyword rules derived from the actual section names in the DB.
-- These run BEFORE the digit fallback, so sections like 'BAL316' resolve to
-- 'balcony' (descriptive zone) instead of '300s (upper)' (numeric tier).
insert into zone_rules (scope, match_type, section_pattern, zone, priority, notes) values
  -- Highest specificity first (within the priority space)
  ('global', 'regex',     '^CRT(\d|\s|$)',      'courtside',     100, 'NBA / arena courtside (CRT, CRT2, CRT 5)'),
  ('global', 'substring', 'courtside',          'courtside',      90, 'any "courtside" wording'),
  ('global', 'exact',     'Pinstripe Pass',     'standing',      100, 'Yankees standing access'),
  ('global', 'substring', 'SRO',                'standing',       80, 'standing room only'),
  ('global', 'substring', 'Pass',               'standing',       30, 'pass-style standing access'),

  ('global', 'prefix',    'UPPER BLEACHER',     'bleacher',       60, 'more specific than BLEACHER'),
  ('global', 'prefix',    'BLEACHER',           'bleacher',       50, ''),
  ('global', 'prefix',    'GRANDSTAND',         'grandstand',     50, ''),

  ('global', 'prefix',    'LOGE',               'loge',           50, 'MSG loge tier'),
  ('global', 'prefix',    'BAL',                'balcony',        50, 'MSG balcony'),
  ('global', 'prefix',    'BOX',                'box',            50, 'box seats'),

  ('global', 'regex',     '^PR\d+$',            'premium row',    50, 'Yankees premium rows'),

  ('global', 'substring', 'Suite',              'suite',          30, ''),
  ('global', 'substring', 'Lounge',             'club',           30, ''),
  ('global', 'substring', 'Club',               'club',           30, '');

revoke all on function derive_zone(text, text, bigint, bigint) from public;
grant execute on function derive_zone(text, text, bigint, bigint) to service_role;
grant execute on function derive_zone(text, text, bigint, bigint) to authenticated;
