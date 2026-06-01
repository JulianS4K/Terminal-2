-- aq_event_map false-match guard + cleanup
--
-- Problem (found in a cross-source listing audit of the Knicks NBA Finals):
--   aq_event_map can carry the WRONG event for a tevo_event_id because two matchers
--   bind on venue+datetime / venue+-4h with NO name/performer validation:
--     * resolve_aq_tevo_from_sources()  -- TickPick/Vivid orders -> events (venue + exact datetime)
--     * backfill_aq_maps() step 2       -- aq -> sg_events_canonical (venue + -4h), tevo derived after
--   Result: e.g. "Forrest Frank" concert bound to Knicks G4 (3346012); 6 MLB wrong-opponent
--   rows; Salsa Spectacular -> LA Philharmonic; an NFL placeholder -> BTS; 2 WNBA wrong-opponent.
--   link_aq_tevo_from_events() is SAFE (requires e.name = a.event_name exactly) and is left as-is.
--
-- Fix:
--   1. aq_name_consistent(tevo_name, aq_name) -- token-overlap guard; for "X at Y" sports also
--      requires the away side to overlap; fast-path for identical/substring names (BTS, Jay-Z, AC/DC).
--   2. Add the guard to resolve_aq_tevo_from_sources() and backfill_aq_maps() step 2.
--   3. One-time cleanup: unbind upcoming rows whose bound tevo event name is inconsistent.
--
-- Residual (NOT fixed here, tracked in KANBAN): same-city placeholder collisions where the away
-- side is "TBD" and the home city token matches (e.g. "TBD at Minnesota Timberwolves" -> a
-- Minnesota Lynx game). Needs league/team-level validation. The guard intentionally lets
-- "TBD at <team>" playoff placeholders resolve to the real opponent (desired behavior).
--
-- ## Already applied to prod  Applied via MCP 2026-06-01

-- 1) Name-consistency guard -------------------------------------------------
CREATE OR REPLACE FUNCTION public.aq_name_consistent(p_tevo text, p_aq text)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
AS $function$
  WITH s AS (
    SELECT trim(regexp_replace(lower(regexp_replace(coalesce(p_tevo,''),'[^a-zA-Z0-9 ]',' ','g')),'\s+',' ','g')) AS t,
           trim(regexp_replace(lower(regexp_replace(coalesce(p_aq,''),  '[^a-zA-Z0-9 ]',' ','g')),'\s+',' ','g')) AS a
  ),
  sw AS (SELECT ARRAY['home','game','date','necessary','finals','final','round','preseason',
                      'national','football','basketball','hockey','baseball','soccer','series',
                      'commissioners','presented','tour','night'] AS w),
  tok AS (
    SELECT s.t, s.a,
      (SELECT array_agg(x) FROM unnest(string_to_array(s.t,' ')) x, sw WHERE length(x)>=4 AND x <> ALL(sw.w)) AS tfull,
      (SELECT array_agg(x) FROM unnest(string_to_array(s.a,' ')) x, sw WHERE length(x)>=4 AND x <> ALL(sw.w)) AS afull,
      (SELECT array_agg(x) FROM unnest(string_to_array(split_part(s.t,' at ',1),' ')) x, sw WHERE length(x)>=4 AND x <> ALL(sw.w)) AS taway,
      (SELECT array_agg(x) FROM unnest(string_to_array(split_part(s.a,' at ',1),' ')) x, sw WHERE length(x)>=4 AND x <> ALL(sw.w)) AS aaway,
      (position(' at ' in s.t)>0 AND position(' at ' in s.a)>0) AS both_at
    FROM s
  )
  SELECT
    -- fast path: identical or one normalized name contains the other (short names: BTS, Jay-Z, AC/DC)
    (a <> '' AND t <> '' AND (position(a in t) > 0 OR position(t in a) > 0))
    OR (
      coalesce(tfull && afull, false)
      AND (NOT both_at OR taway IS NULL OR aaway IS NULL OR coalesce(taway && aaway, false))
    )
  FROM tok;
$function$;

-- 2a) resolve_aq_tevo_from_sources: add name guard to the venue+datetime match ----
CREATE OR REPLACE FUNCTION public.resolve_aq_tevo_from_sources()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE n integer;
BEGIN
  WITH sig AS (
    SELECT o.aq_short_event_id AS aq,
           split_part((o.raw->'venue'->>'name'),' - ',1) AS venue,
           left(o.raw->'event'->>'event_date',19) AS dt
    FROM public.tickpick_orders o
    JOIN public.aq_event_map a ON a.aq_short_event_id = o.aq_short_event_id
    WHERE a.tevo_event_id IS NULL
      AND (o.raw->'event'->>'event_date') IS NOT NULL AND (o.raw->'venue'->>'name') IS NOT NULL
    UNION ALL
    SELECT o.aq_short_event_id,
           split_part(substring(o.raw_xml from '<venue>([^<]+)</venue>'),' - ',1),
           replace(substring(o.raw_xml from '<eventDate>([^<]+)</eventDate>'),' ','T')
    FROM public.vivid_orders o
    JOIN public.aq_event_map a ON a.aq_short_event_id = o.aq_short_event_id
    WHERE a.tevo_event_id IS NULL AND o.raw_xml IS NOT NULL
  ),
  matched AS (
    SELECT s.aq, max(e.id) AS tevo
    FROM sig s
    JOIN public.aq_event_map a2 ON a2.aq_short_event_id = s.aq
    JOIN public.events e ON e.venue_name = s.venue AND left(e.occurs_at_local,19) = s.dt
    WHERE s.venue IS NOT NULL AND s.venue <> '' AND s.dt IS NOT NULL
      AND public.aq_name_consistent(e.name, a2.event_name)   -- guard
    GROUP BY s.aq HAVING count(DISTINCT e.id) = 1
  )
  UPDATE public.aq_event_map a SET tevo_event_id = m.tevo
  FROM matched m WHERE a.aq_short_event_id = m.aq AND a.tevo_event_id IS NULL;
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $function$;

-- 2b) backfill_aq_maps: add name guard to step 2 (aq -> sg via venue + -4h) -------
CREATE OR REPLACE FUNCTION public.backfill_aq_maps()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
DECLARE
  v_ev_tevo  int := 0;
  v_ev_sg    int := 0;
  v_ev_vsid  int := 0;
  v_venue    int := 0;
  v_perf     int := 0;
BEGIN
  UPDATE public.aq_event_map aem
  SET tevo_event_id = e.tevo_event_id
  FROM public.sg_events_canonical e
  WHERE e.sg_event_id = aem.sg_event_id
    AND e.tevo_event_id IS NOT NULL AND aem.tevo_event_id IS NULL;
  GET DIAGNOSTICS v_ev_tevo = ROW_COUNT;

  UPDATE public.aq_event_map aem
  SET sg_event_id = sub.sg_event_id
  FROM (
    SELECT DISTINCT ON (aem2.aq_short_event_id)
      aem2.aq_short_event_id, e.sg_event_id
    FROM public.aq_event_map aem2
    JOIN public.sg_events_canonical e
      ON lower(trim(e.sg_venue_name)) = lower(trim(aem2.venue_name))
      AND aem2.event_date::timestamptz
          BETWEEN e.sg_datetime_utc - interval '4 hours' AND e.sg_datetime_utc + interval '4 hours'
      AND public.aq_name_consistent(e.sg_event_name, aem2.event_name)   -- guard
    WHERE aem2.sg_event_id IS NULL AND e.sg_event_id IS NOT NULL
    ORDER BY aem2.aq_short_event_id,
      abs(extract(epoch FROM (aem2.event_date::timestamptz - e.sg_datetime_utc)))
  ) sub
  WHERE aem.aq_short_event_id = sub.aq_short_event_id;
  GET DIAGNOSTICS v_ev_sg = ROW_COUNT;

  UPDATE public.aq_event_map aem
  SET tevo_event_id = e.tevo_event_id
  FROM public.sg_events_canonical e
  WHERE e.sg_event_id = aem.sg_event_id
    AND e.tevo_event_id IS NOT NULL AND aem.tevo_event_id IS NULL;

  UPDATE public.aq_event_map aem
  SET venue_short_id = sub.venue_short_id
  FROM (
    SELECT DISTINCT ON (aem2.aq_short_event_id)
      aem2.aq_short_event_id, avm.venue_short_id
    FROM public.aq_event_map aem2
    JOIN public.aq_venue_map avm ON lower(trim(avm.venue_name)) = lower(trim(aem2.venue_name))
    WHERE aem2.venue_short_id IS NULL AND aem2.venue_name IS NOT NULL
    ORDER BY aem2.aq_short_event_id
  ) sub
  WHERE aem.aq_short_event_id = sub.aq_short_event_id;
  GET DIAGNOSTICS v_ev_vsid = ROW_COUNT;

  WITH bpn AS (
    SELECT DISTINCT ON (lower(trim(venue_name)))
      lower(trim(venue_name)) AS vname_lower, venue_id
    FROM (SELECT venue_name, venue_id, COUNT(*) AS n FROM public.events
          WHERE venue_id IS NOT NULL AND venue_name IS NOT NULL
          GROUP BY venue_name, venue_id) cnt
    ORDER BY lower(trim(venue_name)), n DESC, venue_id
  ),
  avail AS (
    SELECT vname_lower, venue_id FROM bpn
    WHERE NOT EXISTS (SELECT 1 FROM public.aq_venue_map ex WHERE ex.tevo_venue_id = bpn.venue_id)
  ),
  bm AS (
    SELECT DISTINCT ON (a.venue_id) avm.venue_short_id, a.venue_id AS tevo_venue_id
    FROM public.aq_venue_map avm
    JOIN avail a ON lower(trim(avm.venue_name)) = a.vname_lower
    WHERE avm.tevo_venue_id IS NULL
    ORDER BY a.venue_id, avm.venue_short_id
  )
  UPDATE public.aq_venue_map avm SET tevo_venue_id = bm.tevo_venue_id
  FROM bm WHERE avm.venue_short_id = bm.venue_short_id;
  GET DIAGNOSTICS v_venue = ROW_COUNT;

  WITH bpn AS (
    SELECT DISTINCT ON (lower(trim(primary_performer_name)))
      lower(trim(primary_performer_name)) AS pname_lower, primary_performer_id AS performer_id
    FROM (SELECT primary_performer_name, primary_performer_id, COUNT(*) AS n FROM public.events
          WHERE primary_performer_id IS NOT NULL AND primary_performer_name IS NOT NULL
          GROUP BY primary_performer_name, primary_performer_id) cnt
    ORDER BY lower(trim(primary_performer_name)), n DESC, primary_performer_id
  ),
  avail AS (
    SELECT pname_lower, performer_id FROM bpn
    WHERE NOT EXISTS (SELECT 1 FROM public.aq_performer_map ex WHERE ex.tevo_performer_id = bpn.performer_id)
  ),
  bm AS (
    SELECT DISTINCT ON (a.performer_id) apm.performer_short_id, a.performer_id AS tevo_performer_id
    FROM public.aq_performer_map apm
    JOIN avail a ON lower(trim(apm.performer_name)) = a.pname_lower
    WHERE apm.tevo_performer_id IS NULL
    ORDER BY a.performer_id, apm.performer_short_id
  )
  UPDATE public.aq_performer_map apm SET tevo_performer_id = bm.tevo_performer_id
  FROM bm WHERE apm.performer_short_id = bm.performer_short_id;
  GET DIAGNOSTICS v_perf = ROW_COUNT;

  RETURN jsonb_build_object(
    'ev_tevo_id',    v_ev_tevo,
    'ev_sg_id',      v_ev_sg,
    'ev_venue_sid',  v_ev_vsid,
    'venue_tevo_id', v_venue,
    'perf_tevo_id',  v_perf
  );
END;
$function$;

-- 3) One-time cleanup: unbind upcoming false matches the guard rejects ------------
UPDATE public.aq_event_map a
SET tevo_event_id = NULL
FROM public.events e
WHERE e.id = a.tevo_event_id
  AND e.occurs_at_local IS NOT NULL
  AND e.occurs_at_local::timestamptz >= now()
  AND NOT public.aq_name_consistent(e.name, a.event_name);
