-- Migration 20260908172533 · level:data-collection · lane:D0 · writes:s4kcs_orders · reads:aq_event_map · pre:20260901181056
-- Already applied to prod · via MCP 2026-09-08 (recorded there as version
-- 20260908172734), then s4kcs_map_events() run once: rules 1-4 returned 0
-- (already at steady state) and rule 5 mapped 3,061 order rows / 710 events,
-- matching the dry run exactly. Re-apply is a no-op; re-running the mapper
-- is idempotent (every rule is gated on tevo_event_id IS NULL).
--
-- Add a 5th rule to s4kcs_map_events(): venue + date, with a name guard.
--
-- WHY. The mapper is unbounded and unordered — four blanket
-- `UPDATE ... WHERE tevo_event_id IS NULL` statements, re-attempted every 10
-- minutes — so it is already at steady state: of 1,205 unmapped events in the
-- next 30 days, ZERO are matchable by the existing rules. The gap is not
-- throughput, it is that rules 3 and 4 compare the event NAME by exact
-- normalized equality, and the CRM names the same event differently from our
-- hub:
--     CRM  "New York Yankees vs. Colorado Rockies"
--     hub  "Colorado Rockies at New York Yankees"          (home/away flipped)
--     CRM  "Texas Rangers at Seattle Mariners"
--     hub  "Texas Rangers at Seattle Mariners (Muñoz POP Giveaway)"  (promo suffix)
-- Both are the same event, and both fail `nk = nk`.
--
-- SO: pin venue + date instead, and let the EXISTING name guard decide.
-- `aq_name_consistent()` (mig 20260601173000) is the token-overlap + away-side
-- check already used by resolve_aq_tevo_from_sources()/backfill_aq_maps() —
-- reused here rather than re-implemented.
--
-- THREE REJECTS, each a real false match this rule would otherwise make
-- (§3 warns that venue+date matching with no name guard is exactly what bound
-- a Forrest Frank concert to a Knicks game):
--   1. n_tevo > 1 — venue+date is NOT unique. Measured: 16 events, all US Open
--      sessions at Arthur Ashe. Without this, "Session 19" and "Session 20"
--      both bind to whichever session sorts first. Session number is identity.
--   2. Parking products — "Parking Pass: Rockies at Yankees" is not the game.
--      §3 lists parking as expected-NULL; don't "fix" it. Measured: 9.
--   3. Name-guard failures — 5, left unmapped rather than guessed.
--
-- MEASURED IMPACT (dry run, 2026-09-08): 710 of 2,814 unmapped events become
-- mappable (598 future, 112 past) — future-event coverage 51.3% → ~63%. The
-- remaining 2,104 have no aq_event_map row at that venue+date at all: a hub
-- coverage gap, not a matching one, and no matcher change reaches them.
--
-- CONFIDENCE 0.95: below name_date_venue (0.98, exact name) because the names
-- differ, above name_date (0.92) because the venue is pinned AND the guard ran.
--
-- REVERSIBLE: `UPDATE s4kcs_orders SET tevo_event_id=NULL, aq_short_event_id=NULL,
-- map_method=NULL, map_confidence=NULL, mapped_at=NULL WHERE map_method='venue_date_nameguard';`
-- Rules 1-4 are unchanged, byte-identical to the deployed definition.

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
     AND public.aq_name_consistent(c.hub_name, s.event_name);
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN QUERY SELECT 'venue_date_nameguard'::text, v_n;
END;
$function$;

REVOKE ALL ON FUNCTION public.s4kcs_map_events() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.s4kcs_map_events() TO service_role;
