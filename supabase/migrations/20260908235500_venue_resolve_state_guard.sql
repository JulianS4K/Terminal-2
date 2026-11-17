-- Migration 20260908235500 · level:data-collection · lane:A1 · writes:s4kcs_orders · reads:cross_source_venue_map,aq_event_map · pre:20260908234500
--
-- Already applied to prod · via MCP 2026-09-08 under operator direction (two
-- applies: the resolver, then the mapper). Verified: 0 of 115 state-hinted venue
-- strings still contradict their resolution (was 9); the mapper re-runs clean
-- with no regressions; future CRM order coverage 83.5% -> 83.8%.
--
-- The venue resolver was answering with the WRONG STATE. Reject — or better,
-- re-pick — on a state contradiction.
--
-- WHY THE EXISTING AMBIGUITY GUARD WAS NOT ENOUGH. Mig 20260908224500 made the
-- prefix branch return NULL when several venues share a prefix. That only
-- catches ambiguity VISIBLE IN THE MAP. When the map holds exactly ONE of
-- several same-named venues in the world, the prefix is unique in the TABLE and
-- the guard passes an answer that is simply wrong:
--     "XFINITY Center - MD"   -> 1618 Xfinity Center - MA (Mansfield, MASS.)
--                                while the events are Maryland Terrapins
--                                volleyball at College Park. 30 orders.
--     "Memorial Stadium - NE" -> 31717 Memorial Stadium OKLAHOMA. 4 orders.
--     "Pantages Theatre - CA" -> 1187 Pantages Theatre - TACOMA, WA.
--
-- THE SIGNAL WAS IN THE STRING ALL ALONG. These names carry their own
-- qualifier — "- MD", "- NE", "- CA", ", LA" — and cross_source_venue_resolve()
-- already accepts p_city/p_state, but every caller passes NULL. So the resolver
-- now derives a state hint from the venue string itself when the caller gives
-- none, validated against a list of US state / CA province codes so a venue
-- whose name merely ends in two letters cannot poison the filter.
--
-- IT FILTERS, IT DOES NOT JUST REJECT. The state predicate is applied to all
-- three branches AND inside the prefix branch's ambiguity count, so a
-- same-state candidate wins outright rather than losing to whichever name is
-- longest. That turns a wrong answer into a RIGHT one where the map has the
-- right venue: "Pantages Theatre - CA" now resolves to 1188 Hollywood Pantages
-- (CA) instead of 1187 Tacoma (WA).
--
-- MALFORMED STATE VALUES ARE SKIPPED, NOT TRUSTED. cross_source_venue_map.state
-- is a clean 2-letter code on 1,229 of 1,267 rows; the rest hold things like
-- "New York" or, in one case, "shown". The guard only applies where the stored
-- state matches '^[A-Z]{2}$', so those rows keep resolving as before rather
-- than being filtered out by a comparison that was never going to match.
--
-- THE MAPPER HAD TO CHANGE TOO. Rule 6 resolved
-- `split_part(venue_name, ' - ', 1)` — which strips the very tail that carries
-- the state. The hint never reached the resolver, so "XFINITY Center - MD"
-- still resolved to Massachusetts inside the mapper. _vr now keys on the RAW
-- venue string and passes the derived hint explicitly.
--
-- NOT FIXED, deliberately: bare "Memorial Stadium" (no qualifier) still resolves
-- to Oklahoma. There is no signal in that string to work with, and the CRM uses
-- it for Indiana, Oklahoma AND Nebraska. Its 105 mapped orders are all bound
-- CORRECTLY, by rules 3-4 on exact event-name equality, which never consult the
-- resolver — checked before shipping. PROJECT_BIBLE §4 records it.
--
-- REVERSIBLE: re-apply migs 20260908224500 (resolver) and 20260908230000 (mapper).

CREATE OR REPLACE FUNCTION public.cross_source_venue_resolve(p_venue_name text, p_city text DEFAULT NULL::text, p_state text DEFAULT NULL::text)
RETURNS bigint
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_canonical text;
  v_id bigint;
  v_n  integer;
  v_st text;
BEGIN
  IF p_venue_name IS NULL OR p_venue_name = '' THEN RETURN NULL; END IF;
  v_canonical := lower(regexp_replace(p_venue_name, '[^a-z0-9]+', '', 'gi'));

  -- State hint: the caller's p_state, else a trailing "- XX" / ", XX" on the
  -- venue string itself. Only accepted as a real US state / CA province code,
  -- so a venue whose name merely ends in two letters cannot poison the filter.
  v_st := upper(nullif(trim(coalesce(p_state,
            (regexp_match(p_venue_name, '[,-]\s*([A-Za-z]{2})\s*$'))[1])), ''));
  IF v_st IS NOT NULL AND v_st NOT IN (
    'AL','AK','AZ','AR','CA','CO','CT','DE','FL','GA','HI','ID','IL','IN','IA',
    'KS','KY','LA','ME','MD','MA','MI','MN','MS','MO','MT','NE','NV','NH','NJ',
    'NM','NY','NC','ND','OH','OK','OR','PA','RI','SC','SD','TN','TX','UT','VT',
    'VA','WA','WV','WI','WY','DC','ON','QC','BC','AB','MB','SK','NS','NB'
  ) THEN
    v_st := NULL;
  END IF;

  SELECT tevo_venue_id INTO v_id
  FROM public.cross_source_venue_map
  WHERE canonical_name = v_canonical
    AND (p_city IS NULL OR city IS NULL OR lower(city) = lower(p_city))
    AND (v_st IS NULL OR state IS NULL OR state !~ '^[A-Z]{2}$' OR upper(state) = v_st)
  LIMIT 1;
  IF v_id IS NOT NULL THEN RETURN v_id; END IF;

  SELECT tevo_venue_id INTO v_id
  FROM public.cross_source_venue_map
  WHERE (sg_aliases        ? p_venue_name
      OR tickpick_aliases  ? p_venue_name
      OR vivid_aliases     ? p_venue_name
      OR gotickets_aliases ? p_venue_name
      OR crm_aliases       ? p_venue_name)
    AND (v_st IS NULL OR state IS NULL OR state !~ '^[A-Z]{2}$' OR upper(state) = v_st)
  LIMIT 1;
  IF v_id IS NOT NULL THEN RETURN v_id; END IF;

  -- Prefix branch. The state filter is applied BEFORE the ambiguity count and
  -- before the pick, so a same-state candidate wins outright instead of losing
  -- to whichever name happens to be longest.
  SELECT count(DISTINCT tevo_venue_id) INTO v_n
  FROM public.cross_source_venue_map
  WHERE (canonical_name LIKE v_canonical || '%' OR v_canonical LIKE canonical_name || '%')
    AND (v_st IS NULL OR state IS NULL OR state !~ '^[A-Z]{2}$' OR upper(state) = v_st);
  IF coalesce(v_n, 0) <> 1 THEN RETURN NULL; END IF;

  SELECT tevo_venue_id INTO v_id
  FROM public.cross_source_venue_map
  WHERE (canonical_name LIKE v_canonical || '%' OR v_canonical LIKE canonical_name || '%')
    AND (v_st IS NULL OR state IS NULL OR state !~ '^[A-Z]{2}$' OR upper(state) = v_st)
  ORDER BY length(canonical_name) DESC
  LIMIT 1;
  RETURN v_id;
END $function$;

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
    -- Pass a STATE HINT derived from the raw string. Without it the tail that
    -- carries the state ("XFINITY Center - MD") is stripped before the resolver
    -- ever sees it, and the guard cannot fire. See header.
    SELECT v_raw,
           public.cross_source_venue_resolve(
             split_part(v_raw, ' - ', 1), NULL,
             (regexp_match(v_raw, '[,-]\s*([A-Za-z]{2})\s*$'))[1]) AS vid
      FROM (
        SELECT DISTINCT a.venue_name AS v_raw
          FROM public.aq_event_map a
         WHERE a.tevo_event_id IS NOT NULL AND a.venue_name IS NOT NULL
           AND a.event_date >= current_date - interval '7 days'
        UNION
        SELECT DISTINCT s.venue_name
          FROM public.s4kcs_orders s
         WHERE s.tevo_event_id IS NULL AND s.venue_name IS NOT NULL
           AND s.event_date >= current_date - interval '7 days'
      ) u;
  DELETE FROM _vr WHERE vid IS NULL;
  CREATE INDEX ON _vr (v_raw);
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
      JOIN _vr r ON r.v_raw = a.venue_name
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
     AND r.v_raw = s.venue_name
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

