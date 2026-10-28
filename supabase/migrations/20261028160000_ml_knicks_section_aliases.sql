-- Migration 20261028160000 · level:feature · lane:A1 (data plane — ML training data) · writes:_ml_section_clean()(replace),ml_knicks_catalog_tick()(patch) · reads:ml_knicks_sales · pre:20261027010830,20261027163000
--
-- ML zone gaps found in the first model run (2026-10-28): 31 regular-season training sales had no
-- curated MSG zone, among them the courtside sales (median ~$2,300), so the model had nothing to
-- learn Courtside from.
--   * SeatGeek writes the MSG floor sections as bare "10" / "11" / "12"; the curated Courtside
--     rules say "10 D" / "10D". MSG has no other section 10–12 (lower bowl is 101+, baseline 1–9),
--     so a bare 10–12 is the floor. (4–6 are left alone: a bare 4–6 can be the baseline club.)
--   * Wheelchair sections carry a suffix ("211 uwc", "101WC", "204LWC", "313 wc"): the seat is in
--     the numbered section, so the suffix is dropped.
-- Only the ML catalogue's _ml_section_clean changes; the curated performer_zone_rules (shared with
-- the N2S lane) are untouched.
-- ml_knicks_catalog_tick re-zones every non-curated sale each run; it now also refreshes `level`
-- (derived from the cleaned section), which it previously set only at insert.
SET LOCAL lock_timeout = '10s';

CREATE OR REPLACE FUNCTION public._ml_section_clean(p_section text)
RETURNS text LANGUAGE sql IMMUTABLE PARALLEL SAFE SET search_path = public, pg_temp AS $$
  SELECT CASE
           WHEN s ~* '^\d{3}\s*[ul]?wc$' THEN substring(s FROM '^\d{3}')   -- wheelchair: same section
           WHEN s ~ '^1[0-2]$'           THEN s || ' d'                    -- MSG floor 10–12 without the "D"
           ELSE s END
    FROM (SELECT nullif(btrim(regexp_replace(coalesce(p_section, ''), '^\s*(section|sec)\.?\s+', '', 'i')), '') AS s) c
$$;

DO $patch$
DECLARE
  v_def text := pg_get_functiondef('public.ml_knicks_catalog_tick(integer)'::regprocedure);
  r     record;
BEGIN
  IF position('level = public._ml_level_of(s.section)' in v_def) > 0 THEN
    RAISE NOTICE 'ml_knicks_catalog_tick already refreshes level';
    RETURN;
  END IF;
  FOR r IN SELECT * FROM (VALUES
    ('SET zone = z.zone, zone_source = z.src
',
     'SET zone = z.zone, zone_source = z.src, level = public._ml_level_of(s.section)
'),
    ('AND (s.zone, s.zone_source) IS DISTINCT FROM (z.zone, z.src);',
     'AND (s.zone, s.zone_source, s.level) IS DISTINCT FROM (z.zone, z.src, public._ml_level_of(s.section));')
  ) f(old, new) LOOP
    IF position(r.old in v_def) = 0 THEN
      RAISE EXCEPTION 'ml_knicks_catalog_tick patch: fragment not found: %', left(r.old, 60);
    END IF;
    v_def := replace(v_def, r.old, r.new);
  END LOOP;
  EXECUTE v_def;
END $patch$;

-- VERIFY: SELECT _ml_section_clean('211 uwc'), _ml_section_clean('11'), _ml_section_clean('4'), _ml_level_of('11');
--   -- '211', '11 d', '4', 'courtside'
-- after the next ml_knicks_catalog_offpeak run (06:00–13:59 UTC):
--   SELECT zone, count(*) FROM v_ml_knicks_sales_train WHERE section IN ('10','11','12') GROUP BY 1;
