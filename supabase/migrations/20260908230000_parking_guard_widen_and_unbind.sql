-- Migration 20260908230000 · level:data-collection · lane:D0 · writes:s4kcs_orders · reads:aq_event_map,cross_source_venue_map · pre:20260908224500
--
-- Already applied to prod · via MCP 2026-09-08 under operator direction. The
-- unbind removed 188 wrong rows; re-running the mapper afterwards re-mapped
-- ZERO of them, and 0 parking orders now carry a venue-rule map_method.
--
-- A PARKING PASS IS NOT THE EVENT. Fix a guard hole that bound 188 parking
-- orders to the games and concerts they park for, and unbind them.
--
-- WHAT WAS WRONG. Every venue-keyed rule guarded parking as:
--     AND s.event_name !~* '^(parking|parking pass)'
-- which anchors at the START of the name. The CRM puts it at the END:
--     "Cincinnati Reds at Los Angeles Dodgers Parking"
--     "Howard University Bison at Indiana Hoosiers Football Parking"
--     "Chicago and Styx Parking"
-- and the venue side was no help either, because rules 5-7 key on
-- `split_part(venue_name, ' - ', 1)`, which turns "Kia Forum - Los Angeles
-- Parking" into "Kia Forum" — stripping the very marker that identifies it.
-- So a parking product matched the real event on venue + date, passed
-- aq_name_consistent() (the names ARE nearly identical — that is the whole
-- problem), and bound.
--
-- `PROJECT_BIBLE §3` lists parking as EXPECTED-NULL and warns against "fixing"
-- it. This is the opposite failure: not leaving parking unmapped, but mapping
-- it to something it is not.
--
-- SCALE AND BLAME. 188 orders / 110 events. 20 of them came from rule 5
-- (mig 20260908172533) and so predate today's venue-identity work; 168 came
-- from rule 6, which found many more because resolving venues to ids made the
-- parking venue and the real venue resolve to the SAME id. The accent fix in
-- 20260908224500 surfaced it: "Mana Parking" at "Intuit Dome Parking" bound to
-- the concert "Maná" once accents stopped blocking the token overlap.
--
-- THE FIX. Match "parking" ANYWHERE, on BOTH sides, in rules 5, 6 and 7:
--     AND s.event_name NOT ILIKE '%parking%'
--     AND COALESCE(s.venue_name, '') NOT ILIKE '%parking%'
-- plus the same exclusion on the hub-side candidate sets, so a parking hub row
-- cannot be the thing a real order matches to either.
--
-- CHECKED FOR FALSE POSITIVES FIRST: every distinct CRM event name containing
-- "parking" is a parking product. There is no band, show or team whose name
-- contains the word, so a blanket ILIKE cannot cost a real event. Rules 1-4 are
-- untouched — they need no parking guard, matching on the full event name where
-- "... Parking" simply will not equal the hub's name.
--
-- COVERAGE GOES DOWN, CORRECTLY: future CRM order coverage 83.3% -> 82.9% and
-- event coverage 74.1% -> 72.6%. The higher numbers counted 188 wrong rows.
--
-- REVERSIBLE: re-apply mig 20260908224500's definition. The unbind is not
-- reversible as such, but is re-derivable — those rows simply map again if the
-- guard is removed, which is the bug.

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
     AND s.event_name NOT ILIKE '%parking%'
     AND COALESCE(s.venue_name, '') NOT ILIKE '%parking%'
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
       AND a.venue_name NOT ILIKE '%parking%'
       AND a.event_name NOT ILIKE '%parking%'
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
     AND s.event_name NOT ILIKE '%parking%'
     AND COALESCE(s.venue_name, '') NOT ILIKE '%parking%'
     AND public.aq_name_consistent(public.unaccent(c.hub_name), public.unaccent(s.event_name))
     AND (
       NOT ( (s.event_name ILIKE '% vs%' OR s.event_name ILIKE '% at %')
             AND (c.hub_name  ILIKE '% vs%' OR c.hub_name  ILIKE '% at %') )
       OR (SELECT count(*) FROM (
             SELECT unnest(string_to_array(trim(regexp_replace(lower(
                      regexp_replace(public.unaccent(s.event_name),'[^a-zA-Z0-9 ]',' ','g')),'\s+',' ','g')),' '))
             INTERSECT
             SELECT unnest(string_to_array(trim(regexp_replace(lower(
                      regexp_replace(public.unaccent(c.hub_name),'[^a-zA-Z0-9 ]',' ','g')),'\s+',' ','g')),' '))
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
       AND a.venue_name NOT ILIKE '%parking%'
       AND a.event_name NOT ILIKE '%parking%'
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
     AND s.event_name NOT ILIKE '%parking%'
     AND COALESCE(s.venue_name, '') NOT ILIKE '%parking%'
     AND public.aq_name_consistent(public.unaccent(c.hub_name), public.unaccent(s.event_name))
     AND (
       NOT ( (s.event_name ILIKE '% vs%' OR s.event_name ILIKE '% at %')
             AND (c.hub_name  ILIKE '% vs%' OR c.hub_name  ILIKE '% at %') )
       OR (SELECT count(*) FROM (
             SELECT unnest(string_to_array(trim(regexp_replace(lower(
                      regexp_replace(public.unaccent(s.event_name),'[^a-zA-Z0-9 ]',' ','g')),'\s+',' ','g')),' '))
             INTERSECT
             SELECT unnest(string_to_array(trim(regexp_replace(lower(
                      regexp_replace(public.unaccent(c.hub_name),'[^a-zA-Z0-9 ]',' ','g')),'\s+',' ','g')),' '))
           ) q(tok) WHERE length(tok) >= 4) >= 2
     );
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN QUERY SELECT 'venue_canon_date_nameguard'::text, v_n;
END;
$function$;

REVOKE ALL ON FUNCTION public.s4kcs_map_events() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.s4kcs_map_events() TO service_role;

-- Unbind the 188 parking orders the hole let through.
UPDATE public.s4kcs_orders
   SET tevo_event_id = NULL, aq_short_event_id = NULL,
       map_method = NULL, map_confidence = NULL, mapped_at = NULL
 WHERE map_method IN ('venue_id_date_nameguard','venue_date_nameguard','venue_canon_date_nameguard')
   AND (event_name ILIKE '%parking%' OR COALESCE(venue_name,'') ILIKE '%parking%');
