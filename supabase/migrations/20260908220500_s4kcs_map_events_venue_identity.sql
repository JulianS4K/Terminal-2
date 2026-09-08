-- Migration 20260908220500 · level:data-collection · lane:D0 · writes:s4kcs_orders · reads:aq_event_map,cross_source_venue_map · pre:20260908215500
--
-- Already applied to prod · via MCP 2026-09-08 under operator direction. The
-- 10-minute cron ran it at 20:46 and rule 6 mapped 917 CRM orders; rule 7 mapped
-- 0 (rule 6 had already absorbed its candidates). All 917 audited afterwards:
-- 0 date mismatches, 0 venue mismatches against a re-resolve, and the 15
-- highest-volume bindings read by hand were all correct.
-- SUPERSEDED FOR PERFORMANCE by mig 20260908222000 — rule 6 as written here
-- uses `FROM cand c, _vr r`, which builds a cartesian product of the candidate
-- set and the venue lookup before filtering. It completes under the cron's
-- statement budget but not under a 55s one. See that file.
--
-- Add rules 6 + 7 to s4kcs_map_events(): match on venue IDENTITY, not on the
-- venue STRING.
--
-- WHY. Rules 3, 4 and 5 all compare venues with `lower(trim(...))` exact
-- equality, so the CRM and the hub have to spell a building identically or the
-- order does not map. They frequently do not, and the gap is the single largest
-- remaining one. Measured on future unmapped CRM orders (excluding parking):
--     564 events / 2,219 orders where a hub row EXISTS at that venue+date but
--     the hub row itself carries no tevo_event_id, plus a large slice of the
--     "no hub row" bucket that is really just a spelling difference.
-- Worked example: the CRM writes "Gies Memorial Stadium Illinois" for
-- 2026-11-06; the hub writes "Gies Memorial Stadium". Two mapped hub rows sit
-- at venue 975 on that date. 67 orders could not reach them over one word.
--
-- RULE 6 — venue id + date. Resolves BOTH sides through
-- cross_source_venue_resolve() and joins on the resulting tevo_venue_id, so
-- every alias the map knows is matched for free, including renames the CRM has
-- not caught up with:
--     "LSU Tiger Stadium" / "Tiger Stadium Baton Rouge" -> 873
--     "The Kia Forum" / "The Forum"                     -> 602
--     "Reliant Stadium"                                 -> 2223 NRG Stadium
--     "Memorial Stadium Indiana"                        -> 2044
--     "Northwest Stadium (Formerly Commanders Field)"   -> 486
-- MEASURED: 775 orders / 116 events. All 20 highest-volume proposed matches
-- were read by hand before shipping; every one was correct, with the name guard
-- absorbing home/away flips and "(Rescheduled from …)" / "(Sunday Night
-- Football)" suffixes.
--
-- RULE 7 — canonical venue name + date, for venues with NO TEvo venue id at all,
-- which rule 6 cannot see. Strips punctuation and spacing only:
-- "Vaught Hemingway Stadium" == "Vaught-Hemingway Stadium". MEASURED: 159
-- orders / 10 events.
--
-- EQUALITY ONLY IN RULE 7, NEVER A PREFIX. A prefix match on a venue name is
-- exactly what makes bare "Memorial Stadium" resolve to Memorial Stadium
-- OKLAHOMA (PROJECT_BIBLE §4), and there are ten same-named stadiums in this
-- data. Inside a mapper the name guard would not save us: two college football
-- games both contain the token "football", and `aq_name_consistent` plus a
-- two-token floor can pass on "football" + a shared school word. Prefix
-- matching belongs in the resolver, where a venue id is the answer, not here.
--
-- BOTH RULES CARRY RULE 5'S FULL GUARD SET, unchanged: aq_name_consistent(),
-- the two-shared-token floor when both names are matchups (mig 20260908173624,
-- which exists because rule 5 bound an NHL game to an NBA game on the single
-- token "philadelphia"), the parking exclusion, and
-- `HAVING count(DISTINCT tevo_event_id) = 1` so a venue+date resolving to more
-- than one TEvo event is skipped rather than guessed.
--
-- RULE 6 IS WINDOWED to event_date >= current_date - 7 days on both sides. It
-- materialises venue resolutions into a temp table first — calling
-- cross_source_venue_resolve() per row is what made an unwindowed version of
-- this query time out at 60s, and this function runs on a 10-minute cron, so
-- the window is a hard requirement, not a preference. Rule 7 needs no resolver
-- and is left unwindowed. The historical archive stays the business of rules
-- 3 and 4.
--
-- CONFIDENCE. Rule 6 = 0.94, rule 7 = 0.93 — both below rule 5's 0.95 because
-- the venue is matched through a resolver/normaliser rather than an exact
-- string, and above rule 4's 0.92 because a venue is pinned at all.
--
-- RULES 1-5 ARE BYTE-IDENTICAL to the deployed definition (captured with
-- pg_get_functiondef immediately before authoring).
--
-- REVERSIBLE:
--   UPDATE public.s4kcs_orders
--      SET tevo_event_id=NULL, aq_short_event_id=NULL, map_method=NULL,
--          map_confidence=NULL, mapped_at=NULL
--    WHERE map_method IN ('venue_id_date_nameguard','venue_canon_date_nameguard');
--   -- then re-apply mig 20260908173624's definition.

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
  CREATE INDEX ON _vr (v);

  WITH cand AS (
    SELECT r.vid,
           a.event_date::date AS d,
           min(a.tevo_event_id)     AS tevo_event_id,
           min(a.aq_short_event_id) AS aq_short_event_id,
           min(a.event_name)        AS hub_name
      FROM public.aq_event_map a
      JOIN _vr r ON r.v = a.venue_name
     WHERE a.tevo_event_id IS NOT NULL AND r.vid IS NOT NULL
       AND a.event_date >= current_date - interval '7 days'
     GROUP BY 1,2
    HAVING count(DISTINCT a.tevo_event_id) = 1
  )
  UPDATE public.s4kcs_orders s
     SET tevo_event_id = c.tevo_event_id,
         aq_short_event_id = COALESCE(s.aq_short_event_id, c.aq_short_event_id),
         map_method = 'venue_id_date_nameguard', map_confidence = 0.94, mapped_at = now()
    FROM cand c, _vr r
   WHERE s.tevo_event_id IS NULL
     AND r.v = split_part(s.venue_name, ' - ', 1)
     AND r.vid = c.vid
     AND s.event_date = c.d
     AND s.event_date >= current_date - interval '7 days'
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
