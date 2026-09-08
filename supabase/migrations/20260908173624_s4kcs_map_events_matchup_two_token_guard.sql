-- Migration 20260908173624 · level:data-collection · lane:D0 · writes:s4kcs_orders · reads:aq_event_map · pre:20260908172533
-- Already applied to prod · via MCP 2026-09-08, immediately after the defect below
-- was found. Post-apply s4kcs_map_events() returned 0 for every rule, confirming
-- the bad row was NOT re-bound.
--
-- CORRECTIVE, STRICTLY NARROWING. Rule 5 (mig 20260908172533) made exactly ONE
-- false match in 710 events, and it is the §3 failure mode verbatim:
--
--   CRM  "Philadelphia Flyers vs. Montreal Canadiens"    (NHL)
--   hub  "Minnesota Timberwolves at Philadelphia 76ers"  (NBA)  tevo 3465714
--
-- Wells Fargo Center hosts both franchises and hosted both games on 2027-01-16.
-- Our hub held only the 76ers game, so HAVING count(DISTINCT tevo_event_id) = 1
-- saw an unambiguous venue+date. aq_name_consistent() then passed it on the lone
-- shared token "philadelphia": its away-side check engages only when BOTH names
-- use the " at " form, and the CRM writes "X vs. Y", so that check never ran.
-- The offending row was unbound by hand before this migration was applied.
--
-- FIX. When both names are team-vs-team matchups, require at least TWO shared
-- significant tokens (>=4 chars). One shared token is usually just the city, and
-- two franchises can share an arena on one night. A genuine matchup pair shares
-- ~4 tokens (both team names), so this costs almost nothing:
--   "New York Yankees vs. Colorado Rockies" / "Colorado Rockies at New York
--    Yankees" -> york, yankees, colorado, rockies = 4. Still maps.
--
-- KNOWN COST (accepted): abbreviation pairs sharing only one long token stop
-- matching -- "Austin FC at LAFC" / "Austin FC at Los Angeles FC" (shares only
-- "austin"; LAFC is an acronym, not a token match). Two such rows are already
-- mapped and correct and are left alone; new ones will not map until an alias
-- map exists. A missed map is recoverable; a false map silently corrupts every
-- downstream read, and §3 is explicit that the false bind is the dangerous one.
--
-- Non-matchup names are untouched: the condition applies only when BOTH sides
-- look like matchups, so "Weezer" / "Weezer with The Shins" and "Mana" / "Maná"
-- keep mapping. Rules 1-4 unchanged.

CREATE OR REPLACE FUNCTION public.s4kcs_map_events()
RETURNS TABLE(method text, orders_mapped integer)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE v_n integer;
BEGIN
  -- 1. id-join against our own Vivid book (strongest: same order id).
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

  -- 2. id-join against our own TickPick book.
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

  -- 3. exact name + date + venue.
  WITH cand AS (
    SELECT regexp_replace(lower(a.event_name), '[^a-z0-9]+', '', 'g') AS nk,
           a.event_date::date AS d,
           lower(trim(a.venue_name)) AS vk,
           count(DISTINCT a.tevo_event_id) AS n_tevo,
           min(a.tevo_event_id) AS tevo_event_id,
           min(a.aq_short_event_id) AS aq_short_event_id
      FROM public.aq_event_map a
     WHERE a.tevo_event_id IS NOT NULL AND a.event_name IS NOT NULL
       AND a.event_date IS NOT NULL AND a.venue_name IS NOT NULL
     GROUP BY 1,2,3
    HAVING count(DISTINCT a.tevo_event_id) = 1   -- agreement required
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

  -- 4. exact name + date, venue string not comparable.
  WITH cand AS (
    SELECT regexp_replace(lower(a.event_name), '[^a-z0-9]+', '', 'g') AS nk,
           a.event_date::date AS d,
           count(DISTINCT a.tevo_event_id) AS n_tevo,
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

  -- 5. NEW — venue + date, name decided by the existing aq_name_consistent()
  --    guard. Catches the home/away flip and the promo-suffix cases that
  --    exact name equality misses. The HAVING clause is load-bearing: it drops
  --    every venue+date that resolves to more than one TEvo event (US Open
  --    sessions), where a bind would be to the WRONG event, not a near miss.
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
     -- CRM venues carry a " - City, ST" tail the hub doesn't.
     AND lower(trim(split_part(s.venue_name, ' - ', 1))) = c.vk
     AND s.event_date = c.d
     -- A parking pass is a different product from the event it parks for.
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
END;
$function$;

REVOKE ALL ON FUNCTION public.s4kcs_map_events() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.s4kcs_map_events() TO service_role;
