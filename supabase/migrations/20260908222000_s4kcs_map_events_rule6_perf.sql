-- Migration 20260908222000 · level:data-collection · lane:D0 · writes:s4kcs_orders · reads:aq_event_map,cross_source_venue_map · pre:20260908220500
--
-- Already applied to prod · via MCP 2026-09-08 under operator direction.
-- Verified: s4kcs_map_events() now completes inside a 55s statement_timeout and
-- returns all seven rules; the 917 rows rule 6 had already written are
-- untouched (every rule is gated on tevo_event_id IS NULL).
--
-- PERFORMANCE CORRECTIVE to 20260908220500. Rule 6 is unchanged in MEANING —
-- same keys, same guards, same confidence, same window. Only the join shape
-- changes.
--
-- WHAT WAS WRONG. Rule 6 was written as:
--     UPDATE ... FROM cand c, _vr r WHERE ... r.vid = c.vid ...
-- A comma join gives the planner no join condition between `cand` and `_vr`
-- until the WHERE clause, so it materialises their CARTESIAN PRODUCT first:
-- ~1,200 venue rows x the candidate set, with aq_name_consistent() — a plpgsql
-- call, so opaque to the planner and expensive per row — evaluated across it.
--
-- HOW IT SURFACED, and the trap worth recording. The parent version DID run to
-- completion under the 10-minute cron and mapped its 917 orders correctly; it
-- failed only in an ad-hoc session that had set `statement_timeout='55s'`. So
-- the symptom was a query that "works in prod, times out when I run it" — the
-- opposite of the usual direction, and easy to misread as prod being broken.
-- It was not: cron and session simply had different statement budgets.
--
-- THE FIX, three parts:
--   1. `FROM _vr r JOIN _hub6 c ON c.vid = r.vid` — an explicit equi-join, so
--      the vid join happens before anything else.
--   2. `_hub6` materialised as a temp table rather than a CTE, and ANALYZEd, so
--      the planner has real statistics for it instead of a CTE's default guess.
--   3. `DELETE FROM _vr WHERE vid IS NULL` plus an index on `_vr(vid)` — the
--      unresolvable venue names (194 of 1,173) can never match and are dropped
--      before the join rather than filtered inside it.
--
-- Rules 1-5 and rule 7 are byte-identical to the parent.
--
-- REVERSIBLE: re-apply the parent migration's function definition. The two are
-- behaviourally equivalent; only the plan differs.

CREATE OR REPLACE FUNCTION public.s4kcs_map_events()
RETURNS TABLE(method text, orders_mapped integer)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE v_n integer;
BEGIN
  UPDATE public.s4kcs_orders s
     SET tevo_event_id = v.tevo_event_id,
         aq_short_event_id = COALESCE(s.aq_short_event_id, v.aq_short_event_id),
         map_method = 'order_id_vivid', map_confidence = 1.00, mapped_at = now()
    FROM public.vivid_orders v
   WHERE s.source = 'Vivid Seats'
     AND v.vivid_order_id = s.s4k_order_id
     AND v.tevo_event_id IS NOT NULL
     AND s.tevo_event_id IS NULL;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN QUERY SELECT 'order_id_vivid'::text, v_n;

  UPDATE public.s4kcs_orders s
     SET tevo_event_id = t.tevo_event_id,
         aq_short_event_id = COALESCE(s.aq_short_event_id, t.aq_short_event_id),
         map_method = 'order_id_tickpick', map_confidence = 1.00, mapped_at = now()
    FROM public.tickpick_orders t
   WHERE s.source = 'TickPick'
     AND t.tp_order_id = s.s4k_order_id
     AND t.tevo_event_id IS NOT NULL
     AND s.tevo_event_id IS NULL;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN QUERY SELECT 'order_id_tickpick'::text, v_n;

  WITH cand AS (
    SELECT regexp_replace(lower(a.event_name), '[^a-z0-9]+', '', 'g') AS nk,
           a.event_date::date AS d,
           lower(trim(a.venue_name)) AS vk,
           min(a.tevo_event_id) AS tevo_event_id,
           min(a.aq_short_event_id) AS aq_short_event_id
      FROM public.aq_event_map a
     WHERE a.tevo_event_id IS NOT NULL AND a.event_name IS NOT NULL
       AND a.event_date IS NOT NULL AND a.venue_name IS NOT NULL
     GROUP BY 1,2,3
    HAVING count(DISTINCT a.tevo_event_id) = 1
  )
  UPDATE public.s4kcs_orders s
     SET tevo_event_id = c.tevo_event_id,
         aq_short_event_id = COALESCE(s.aq_short_event_id, c.aq_short_event_id),
         map_method = 'name_date_venue', map_confidence = 0.98, mapped_at = now()
    FROM cand c
   WHERE s.tevo_event_id IS NULL
     AND regexp_replace(lower(s.event_name), '[^a-z0-9]+', '', 'g') = c.nk
     AND s.event_date = c.d
     AND lower(trim(s.venue_name)) = c.vk;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN QUERY SELECT 'name_date_venue'::text, v_n;

  WITH cand AS (
    SELECT regexp_replace(lower(a.event_name), '[^a-z0-9]+', '', 'g') AS nk,
           a.event_date::date AS d,
           min(a.tevo_event_id) AS tevo_event_id,
           min(a.aq_short_event_id) AS aq_short_event_id
      FROM public.aq_event_map a
     WHERE a.tevo_event_id IS NOT NULL AND a.event_name IS NOT NULL AND a.event_date IS NOT NULL
     GROUP BY 1,2
    HAVING count(DISTINCT a.tevo_event_id) = 1
  )
  UPDATE public.s4kcs_orders s
     SET tevo_event_id = c.tevo_event_id,
         aq_short_event_id = COALESCE(s.aq_short_event_id, c.aq_short_event_id),
         map_method = 'name_date', map_confidence = 0.92, mapped_at = now()
    FROM cand c
   WHERE s.tevo_event_id IS NULL
     AND regexp_replace(lower(s.event_name), '[^a-z0-9]+', '', 'g') = c.nk
     AND s.event_date = c.d;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN QUERY SELECT 'name_date'::text, v_n;

  -- 5. venue + date, name decided by aq_name_consistent(), PLUS a two-token
  --    floor when both sides are matchups (see header).
  WITH cand AS (
    SELECT lower(trim(a.venue_name)) AS vk,
           a.event_date::date AS d,
           min(a.tevo_event_id)     AS tevo_event_id,
           min(a.aq_short_event_id) AS aq_short_event_id,
           min(a.event_name)        AS hub_name
      FROM public.aq_event_map a
     WHERE a.tevo_event_id IS NOT NULL AND a.venue_name IS NOT NULL
       AND a.event_date IS NOT NULL
     GROUP BY 1,2
    HAVING count(DISTINCT a.tevo_event_id) = 1
  )
  UPDATE public.s4kcs_orders s
     SET tevo_event_id = c.tevo_event_id,
         aq_short_event_id = COALESCE(s.aq_short_event_id, c.aq_short_event_id),
         map_method = 'venue_date_nameguard', map_confidence = 0.95, mapped_at = now()
    FROM cand c
   WHERE s.tevo_event_id IS NULL
     AND lower(trim(split_part(s.venue_name, ' - ', 1))) = c.vk
     AND s.event_date = c.d
     AND s.event_name !~* '^(parking|parking pass)'
     AND public.aq_name_consistent(c.hub_name, s.event_name)
     AND (
       NOT ( (s.event_name ILIKE '% vs%' OR s.event_name ILIKE '% at %')
             AND (c.hub_name  ILIKE '% vs%' OR c.hub_name  ILIKE '% at %') )
       OR (SELECT count(*) FROM (
             SELECT unnest(string_to_array(trim(regexp_replace(lower(
                      regexp_replace(s.event_name,'[^a-zA-Z0-9 ]',' ','g')),'\s+',' ','g')),' '))
             INTERSECT
             SELECT unnest(string_to_array(trim(regexp_replace(lower(
                      regexp_replace(c.hub_name,'[^a-zA-Z0-9 ]',' ','g')),'\s+',' ','g')),' '))
           ) q(tok) WHERE length(tok) >= 4) >= 2
     );
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN QUERY SELECT 'venue_date_nameguard'::text, v_n;

  -- 6. NEW — venue IDENTITY + date. Rules 3-5 all compare the venue STRING;
  --    this resolves both sides to a tevo_venue_id first, so every alias the
  --    map knows ("LSU Tiger Stadium", "The Kia Forum", "Reliant Stadium" ->
  --    NRG) is matched for free. Same name guards as rule 5.
  -- DROP first: ON COMMIT DROP only fires at commit, so a second call inside
  -- one transaction would otherwise fail with "relation _vr already exists".
  DROP TABLE IF EXISTS _vr;
  CREATE TEMP TABLE _vr ON COMMIT DROP AS
    SELECT v, public.cross_source_venue_resolve(v, NULL, NULL) AS vid
      FROM (
        SELECT DISTINCT a.venue_name AS v
          FROM public.aq_event_map a
         WHERE a.tevo_event_id IS NOT NULL AND a.venue_name IS NOT NULL
           AND a.event_date >= current_date - interval '7 days'
        UNION
        SELECT DISTINCT split_part(s.venue_name, ' - ', 1)
          FROM public.s4kcs_orders s
         WHERE s.tevo_event_id IS NULL AND s.venue_name IS NOT NULL
           AND s.event_date >= current_date - interval '7 days'
      ) u;
  DELETE FROM _vr WHERE vid IS NULL;
  CREATE INDEX ON _vr (v);
  CREATE INDEX ON _vr (vid);
  ANALYZE _vr;

  -- Materialised, not a CTE: the candidate set is joined to _vr on vid, so the
  -- planner never has to consider cand x _vr as a cartesian product.
  DROP TABLE IF EXISTS _hub6;
  CREATE TEMP TABLE _hub6 ON COMMIT DROP AS
    SELECT r.vid,
           a.event_date::date AS d,
           min(a.tevo_event_id)     AS tevo_event_id,
           min(a.aq_short_event_id) AS aq_short_event_id,
           min(a.event_name)        AS hub_name
      FROM public.aq_event_map a
      JOIN _vr r ON r.v = a.venue_name
     WHERE a.tevo_event_id IS NOT NULL
       AND a.event_date >= current_date - interval '7 days'
     GROUP BY 1,2
    HAVING count(DISTINCT a.tevo_event_id) = 1;
  CREATE INDEX ON _hub6 (vid, d);
  ANALYZE _hub6;

  UPDATE public.s4kcs_orders s
     SET tevo_event_id = c.tevo_event_id,
         aq_short_event_id = COALESCE(s.aq_short_event_id, c.aq_short_event_id),
         map_method = 'venue_id_date_nameguard', map_confidence = 0.94, mapped_at = now()
    FROM _vr r
    JOIN _hub6 c ON c.vid = r.vid
   WHERE s.tevo_event_id IS NULL
     AND s.event_date >= current_date - interval '7 days'
     AND r.v = split_part(s.venue_name, ' - ', 1)
     AND s.event_date = c.d
     AND s.event_name !~* '^(parking|parking pass)'
     AND public.aq_name_consistent(c.hub_name, s.event_name)
     AND (
       NOT ( (s.event_name ILIKE '% vs%' OR s.event_name ILIKE '% at %')
             AND (c.hub_name  ILIKE '% vs%' OR c.hub_name  ILIKE '% at %') )
       OR (SELECT count(*) FROM (
             SELECT unnest(string_to_array(trim(regexp_replace(lower(
                      regexp_replace(s.event_name,'[^a-zA-Z0-9 ]',' ','g')),'\s+',' ','g')),' '))
             INTERSECT
             SELECT unnest(string_to_array(trim(regexp_replace(lower(
                      regexp_replace(c.hub_name,'[^a-zA-Z0-9 ]',' ','g')),'\s+',' ','g')),' '))
           ) q(tok) WHERE length(tok) >= 4) >= 2
     );
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN QUERY SELECT 'venue_id_date_nameguard'::text, v_n;

  -- 7. NEW — canonical venue NAME + date, for venues that have no TEvo venue id
  --    at all (so rule 6 cannot see them). Strips punctuation and spacing only:
  --    "Vaught Hemingway Stadium" == "Vaught-Hemingway Stadium". Equality ONLY,
  --    never a prefix — prefix on a venue name is what makes bare "Memorial
  --    Stadium" resolve to Oklahoma (PROJECT_BIBLE §4), and inside a mapper the
  --    name guard alone would not stop two CFB games sharing the token
  --    "football".
  WITH cand AS (
    SELECT lower(regexp_replace(a.venue_name, '[^a-z0-9]+', '', 'gi')) AS vc,
           a.event_date::date AS d,
           min(a.tevo_event_id)     AS tevo_event_id,
           min(a.aq_short_event_id) AS aq_short_event_id,
           min(a.event_name)        AS hub_name
      FROM public.aq_event_map a
     WHERE a.tevo_event_id IS NOT NULL AND a.venue_name IS NOT NULL
       AND a.event_date IS NOT NULL
     GROUP BY 1,2
    HAVING count(DISTINCT a.tevo_event_id) = 1
  )
  UPDATE public.s4kcs_orders s
     SET tevo_event_id = c.tevo_event_id,
         aq_short_event_id = COALESCE(s.aq_short_event_id, c.aq_short_event_id),
         map_method = 'venue_canon_date_nameguard', map_confidence = 0.93, mapped_at = now()
    FROM cand c
   WHERE s.tevo_event_id IS NULL
     AND lower(regexp_replace(split_part(s.venue_name, ' - ', 1), '[^a-z0-9]+', '', 'gi')) = c.vc
     AND s.event_date = c.d
     AND s.event_name !~* '^(parking|parking pass)'
     AND public.aq_name_consistent(c.hub_name, s.event_name)
     AND (
       NOT ( (s.event_name ILIKE '% vs%' OR s.event_name ILIKE '% at %')
             AND (c.hub_name  ILIKE '% vs%' OR c.hub_name  ILIKE '% at %') )
       OR (SELECT count(*) FROM (
             SELECT unnest(string_to_array(trim(regexp_replace(lower(
                      regexp_replace(s.event_name,'[^a-zA-Z0-9 ]',' ','g')),'\s+',' ','g')),' '))
             INTERSECT
             SELECT unnest(string_to_array(trim(regexp_replace(lower(
                      regexp_replace(c.hub_name,'[^a-zA-Z0-9 ]',' ','g')),'\s+',' ','g')),' '))
           ) q(tok) WHERE length(tok) >= 4) >= 2
     );
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN QUERY SELECT 'venue_canon_date_nameguard'::text, v_n;
END;
$function$;

REVOKE ALL ON FUNCTION public.s4kcs_map_events() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.s4kcs_map_events() TO service_role;
