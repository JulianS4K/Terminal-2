-- Capture derive_zone_fallback() — this function exists in prod but was
-- created out-of-band during the v2.6/v2.7 parallel work and never tracked
-- in any migration. Mirror it here so a fresh `supabase db push` reproduces
-- the live system.
--
-- Behaviour:
--   1. Match against zone_rules (keyword/regex/etc) per active rule, highest priority wins
--   2. Fall back to digit-prefix tier (100s lower / 200s club / 300s / 400s / 500s upper)
--   3. Return null if no match
--
-- Used by the bot/edge functions when performer_zones doesn't have a curated
-- zone for the (performer, venue) combo.

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

  -- 2a. Keyword / regex match
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

  -- 2b. Digit-prefix tier
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
