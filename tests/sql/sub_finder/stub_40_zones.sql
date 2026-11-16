CREATE TABLE IF NOT EXISTS performer_zones (id bigserial primary key, performer_id bigint, venue_id bigint, source text, name text);
CREATE TABLE IF NOT EXISTS performer_zone_rules (id bigserial primary key, zone_id bigint, section_from text, section_to text, row_from text, row_to text);
create or replace function _sec_norm(s text) returns text language sql immutable as $$ select regexp_replace(lower(coalesce(s,'')), '\s+', '', 'g') $$;
create or replace function _sec_prefix(s text) returns text language sql immutable as $$ select regexp_replace(_sec_norm(s), '[0-9]+$', '') $$;
create or replace function _sec_suffix(s text) returns integer language sql immutable as $$ select case when _sec_norm(s) ~ '[0-9]+$' then (regexp_match(_sec_norm(s), '([0-9]+)$'))[1]::int else null end $$;
CREATE OR REPLACE FUNCTION public.n2s_zone_of(p_performer_id bigint, p_venue_id bigint, p_section text, p_row text) RETURNS text LANGUAGE sql STABLE AS $function$
  SELECT CASE WHEN count(DISTINCT z.name) = 1 THEN min(z.name) END
    FROM public.performer_zones z JOIN public.performer_zone_rules r ON r.zone_id = z.id
   WHERE z.performer_id = p_performer_id AND z.venue_id = p_venue_id AND z.source = 'curated' AND z.name NOT ILIKE '%fifa%'
     AND ( (public._sec_norm(r.section_from) = public._sec_norm(r.section_to) AND public._sec_norm(p_section) = public._sec_norm(r.section_from))
        OR (r.section_from ~ '^[0-9]+$' AND r.section_to ~ '^[0-9]+$' AND p_section ~ '^[0-9]+$' AND p_section::int BETWEEN r.section_from::int AND r.section_to::int)
        OR (public._sec_prefix(r.section_from) <> '' AND public._sec_prefix(r.section_from) = public._sec_prefix(r.section_to)
            AND public._sec_prefix(r.section_from) = public._sec_prefix(p_section) AND public._sec_suffix(r.section_from) IS NOT NULL
            AND public._sec_suffix(r.section_to) IS NOT NULL AND public._sec_suffix(p_section) IS NOT NULL
            AND public._sec_suffix(p_section) BETWEEN public._sec_suffix(r.section_from) AND public._sec_suffix(r.section_to)) )
     AND ( (r.row_from IS NULL AND r.row_to IS NULL)
        OR (lower(coalesce(r.row_from,'')) = lower(coalesce(r.row_to,'')) AND lower(coalesce(p_row,'')) = lower(coalesce(r.row_from,'')))
        OR (r.row_from ~ '^[0-9]+$' AND r.row_to ~ '^[0-9]+$' AND p_row ~ '^[0-9]+$' AND p_row::int BETWEEN r.row_from::int AND r.row_to::int) )
$function$;
CREATE OR REPLACE FUNCTION zone_stub_sync() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE v bigint; BEGIN
  INSERT INTO performer_zones(performer_id, venue_id, source, name) VALUES (NEW.performer_id, NEW.venue_id, 'curated', NEW.zone) RETURNING id INTO v;
  INSERT INTO performer_zone_rules(zone_id, section_from, section_to) VALUES (v, NEW.section, NEW.section); RETURN NEW; END $$;
DROP TRIGGER IF EXISTS zone_stub_sync ON zone_stub;
CREATE TRIGGER zone_stub_sync AFTER INSERT ON zone_stub FOR EACH ROW EXECUTE FUNCTION zone_stub_sync();
