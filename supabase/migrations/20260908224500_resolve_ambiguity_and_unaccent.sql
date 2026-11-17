-- Migration 20260908224500 · level:data-collection · lane:A1 · writes:s4kcs_orders · reads:aq_event_map,cross_source_venue_map · pre:20260908222000
--
-- Already applied to prod · via MCP 2026-09-08 under operator direction (as two
-- applies: the resolver, then the mapper). Verified: "Greek Theatre",
-- "Nederlander Theatre" and "Indian Wells Tennis Garden" now return NULL, while
-- "Toyota Center"/"Orpheum Theatre" (alias branch) and every seeded venue still
-- resolve. The unaccent half mapped exactly 17 orders, matching the dry-run
-- measurement: CF Montréal->CF Montreal (12) and Rosalía->Rosalia (5).
-- ⚠ It ALSO exposed a pre-existing parking-guard hole — see mig 20260908230000.
--
-- Two narrow correctness fixes, both found by auditing what the matcher
-- DECLINED rather than what it accepted.
--
-- 1. AMBIGUOUS PREFIX NOW RETURNS NULL. cross_source_venue_resolve()'s third
-- branch matched a venue prefix and, on several candidates, returned the
-- LONGEST — an arbitrary pick dressed up as an answer. Measured over the 1,084
-- venue strings in play: 836 resolve by exact canonical name or alias, 223 by a
-- UNIQUE prefix (kept), and only 5 by an ambiguous one. Two of those five
-- (`Toyota Center`, `Orpheum Theatre`) now resolve correctly through the alias
-- branch, which runs first, so this changes exactly three:
--     "Greek Theatre"              -> was 1785 U.C. Berkeley (also: Los Angeles)
--     "Nederlander Theatre"        -> was 519 Chicago        (also: NY)
--     "Indian Wells Tennis Garden" -> was 33069 Stadium 2    (also: Stadium 1, Grounds)
-- All three were wrong at least as often as right. A NULL is strictly better:
-- the bridge falls back to a name+date search and the mapper skips the row,
-- instead of both being pointed confidently at the wrong building.
--
-- This does NOT fix bare "Memorial Stadium" -> 31717 OKLAHOMA, and it is worth
-- recording why: only ONE row in the map has a canonical name starting with
-- "memorialstadium", so the prefix is UNIQUE in the table even though the name
-- is ambiguous in the world. That ambiguity is semantic, not structural, and no
-- alias can fix it either — the CRM itself uses the bare string for Indiana
-- (105 mapped orders), Oklahoma (24) and Nebraska. The name guard is what
-- protects that case, and it does: it rejected "North Texas Mean Green at
-- Indiana Hoosiers Football" against the hub's "UTEP Miners at Oklahoma Sooners
-- Football" at the same date, declining 32 orders rather than mis-binding them.
--
-- 2. ACCENT-INSENSITIVE NAME GUARD IN RULES 6 AND 7. `CF Montréal at
-- Philadelphia Union` was rejected against the hub's `CF Montreal at
-- Philadelphia Union` — same event, one acute accent apart. Rules 6 and 7 now
-- pass both names through unaccent() before aq_name_consistent() and before the
-- two-token floor. MEASURED: 17 orders across 3 events.
--
-- Scope is deliberately limited to rules 6 and 7. aq_name_consistent() itself is
-- shared with resolve_aq_tevo_from_sources(), backfill_aq_maps() and the SG
-- path; folding accents inside it would widen every caller at once, which is a
-- bigger change than this evidence supports. Rules 1-5 are untouched.
--
-- REVERSIBLE: re-apply migs 20260908222000 (mapper) and 20260908210000
-- (resolver). Neither fix writes data that cannot be re-derived.

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
BEGIN
  IF p_venue_name IS NULL OR p_venue_name = '' THEN RETURN NULL; END IF;
  v_canonical := lower(regexp_replace(p_venue_name, '[^a-z0-9]+', '', 'gi'));

  SELECT tevo_venue_id INTO v_id
  FROM public.cross_source_venue_map
  WHERE canonical_name = v_canonical
    AND (p_city IS NULL OR city IS NULL OR lower(city) = lower(p_city))
    AND (p_state IS NULL OR state IS NULL OR upper(state) = upper(p_state))
  LIMIT 1;
  IF v_id IS NOT NULL THEN RETURN v_id; END IF;

  SELECT tevo_venue_id INTO v_id
  FROM public.cross_source_venue_map
  WHERE sg_aliases        ? p_venue_name
     OR tickpick_aliases  ? p_venue_name
     OR vivid_aliases     ? p_venue_name
     OR gotickets_aliases ? p_venue_name
     OR crm_aliases       ? p_venue_name
  LIMIT 1;
  IF v_id IS NOT NULL THEN RETURN v_id; END IF;

  -- Prefix branch. AMBIGUITY NOW RETURNS NULL rather than the longest match:
  -- if several venues share the prefix, this string does not identify one of
  -- them and a guess is worse than no answer (see header).
  SELECT count(DISTINCT tevo_venue_id) INTO v_n
  FROM public.cross_source_venue_map
  WHERE canonical_name LIKE v_canonical || '%'
     OR v_canonical LIKE canonical_name || '%';
  IF coalesce(v_n, 0) <> 1 THEN RETURN NULL; END IF;

  SELECT tevo_venue_id INTO v_id
  FROM public.cross_source_venue_map
  WHERE canonical_name LIKE v_canonical || '%'
     OR v_canonical LIKE canonical_name || '%'
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
