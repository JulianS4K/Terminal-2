-- ============================================================================
-- Migration 20260910180000 — n2s_map_events reuses the mappers we already have
--
-- Lane:     D0 (orders surface)
-- Touches:  n2s_map_events() — adds rule 0 (CRM order identity) and
--           rule 5 (GoTickets name alias). Rules 1-4 unchanged.
-- Pre-reqs: 20260910110000
--
-- READ-ONLY upstream: no API call here. Pure joins over tables we already
-- hold. RULE 2 untouched.
--
-- Operator direction 2026-09-10: "for map also incorporate a mapping and other
-- event mappers."
--
-- ── THE GAP THIS CLOSES ───────────────────────────────────────────────────
-- Rules 1-4 all INFER an event from a name and a date. But two surfaces in
-- this database have ALREADY solved the same problem for the same events, and
-- n2s_map_events was ignoring both:
--
--   * s4kcs_orders — the CRM marketplace book, 95.2% mapped. An N2S row and a
--     marketplace row can be THE SAME ORDER, joined on the order key. That is
--     identity, not inference: no name is compared at all.
--   * gotickets_event — GT's catalogue, already mapped to tevo ids by
--     gt_map_events()/hub backfill. Its value here is that GT spells event
--     names the way the MARKETPLACES do, which is how N2S spells them, where
--     `events` often does not. It is a name ALIAS table we already maintain.
--
-- Measured on the live unmapped set (302 rows) before writing this:
--   rule 0 (CRM identity)   -> 87 recoverable, 0 disagreements in 75 overlaps
--   rule 5 (GT name alias)  -> 136 recoverable, 0 disagreements in 70 overlaps
-- "Overlap" = rows BOTH this rule and rules 1-4 can map, used as a correctness
-- check: the new rule must agree with the established one everywhere it can be
-- compared, or it does not go in.
--
-- ⚠ RULE 5 MUST COMPARE **LOCAL** DATES, NEVER UTC. n2s_items.event_dt is a
-- local wall clock (`timestamp`, no zone) while gotickets_event.event_time_utc
-- is UTC. A 19:10 Pacific game is 02:10 UTC the FOLLOWING day, so joining on
-- the UTC date silently matches the PREVIOUS NIGHT'S game. That is not
-- hypothetical: the first cut of this rule did exactly that and bound
-- "Cincinnati Reds at Los Angeles Dodgers" 2026-09-09 to event 3100242
-- (2026-09-08), a real wrong-game bind that the overlap check caught. So the
-- rule reaches GT -> events and compares events.occurs_at_local, which is the
-- same local-date basis rule 1 uses. Fixing this took the rule from
-- 66 recoverable / 1 wrong to 136 recoverable / 0 wrong.
--
-- ⚠ ORDER IS DELIBERATE. Rule 0 runs FIRST because identity beats inference —
-- if we already know this exact order's event, no name guard should get a
-- chance to disagree with it. Rule 5 runs LAST because it trusts a THIRD
-- party's mapping; anything our own rules can settle, they should settle.
--
-- ⚠ EVERY RULE STAYS FILL-ONLY AND UNIQUE-OR-DECLINE. `HAVING count(DISTINCT
-- ...) = 1` on rule 5 is load-bearing: two GT rows sharing a name and a local
-- date but pointing at different events means we cannot tell, and an unmapped
-- order is strictly better than one holding seats for the wrong game.
--
-- ── WHAT WAS MEASURED AND REJECTED ────────────────────────────────────────
-- * aq_event_map (the AQ hub) on name + date recovers **0** N2S rows. The hub
--   spells events differently from the marketplaces — that difference is the
--   whole reason aq-to-tevo-search-bridge exists. N2S items carry no
--   marketplace event id (only listing_id / po_number), so there is no id path
--   into the hub either. Not wired: it would be dead code.
-- * Splitting city/state out of n2s_items.venue (" - Los Angeles, CA") to feed
--   the 3-arg cross_source_venue_resolve() resolves 110 of 115 venues against
--   111 bare — a NET LOSS of one, on only 102 of 474 rows that carry the
--   suffix at all. The name-family blindness noted in PROJECT_BIBLE §4 is real
--   but this is not the fix for it. Left alone.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.n2s_map_events(p_apply boolean DEFAULT true)
RETURNS TABLE(considered integer, mapped integer, ambiguous integer, venue_rejected integer)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $function$
DECLARE
  v_considered int := 0; v_mapped int := 0; v_amb int := 0; v_vrej int := 0; v_n int;
BEGIN
  -- ── Rule 0: the SAME ORDER is already mapped in the CRM marketplace book ──
  -- Identity, not inference. n2s_order_key is the generated column that has
  -- already split EVO's compound number, so it lines up with s4k_order_id
  -- without any per-source special casing here.
  IF p_apply THEN
    UPDATE public.n2s_items n
       SET tevo_event_id = o.tevo_event_id, mapped_via = 'n2s_crm_order_identity'
      FROM public.s4kcs_orders o
     WHERE o.s4k_order_id = n.n2s_order_key
       AND o.tevo_event_id IS NOT NULL
       AND n.tevo_event_id IS NULL
       AND NOT n.is_terminal;
    GET DIAGNOSTICS v_n = ROW_COUNT; v_mapped := v_mapped + v_n;
  END IF;

  -- ── Rule 1: exact name + exact date, unique, venue id agrees ─────────────
  DROP TABLE IF EXISTS _m;
  CREATE TEMP TABLE _m ON COMMIT DROP AS
    SELECT n.n2s_id,
           count(DISTINCT e.id)                      AS n_events,
           min(e.id)                                 AS eid,
           min(e.venue_id)                           AS ev_venue_id,
           public.cross_source_venue_resolve(n.venue) AS n2s_venue_id
      FROM public.n2s_items n
      JOIN public.events e
        ON lower(e.name) = lower(n.event_name)
       AND left(e.occurs_at_local, 10)::date = n.event_dt::date
     WHERE n.tevo_event_id IS NULL AND NOT n.is_terminal
       AND n.event_dt::date >= current_date AND n.event_name IS NOT NULL
     GROUP BY n.n2s_id, n.venue;

  SELECT count(*)::int INTO v_considered FROM _m;
  SELECT count(*)::int INTO v_amb        FROM _m WHERE n_events > 1;
  SELECT count(*)::int INTO v_vrej       FROM _m
   WHERE n_events = 1 AND n2s_venue_id IS NOT NULL AND ev_venue_id IS NOT NULL
     AND n2s_venue_id <> ev_venue_id;

  IF p_apply THEN
    UPDATE public.n2s_items n
       SET tevo_event_id = m.eid, mapped_via = 'n2s_name_date_venue'
      FROM _m m
     WHERE n.n2s_id = m.n2s_id AND m.n_events = 1
       AND (m.n2s_venue_id IS NULL OR m.ev_venue_id IS NULL
            OR m.n2s_venue_id = m.ev_venue_id)
       AND n.tevo_event_id IS NULL;
    GET DIAGNOSTICS v_n = ROW_COUNT; v_mapped := v_mapped + v_n;
  ELSE
    SELECT count(*)::int INTO v_n FROM _m
     WHERE n_events = 1
       AND (n2s_venue_id IS NULL OR ev_venue_id IS NULL OR n2s_venue_id = ev_venue_id);
    v_mapped := v_mapped + v_n;
  END IF;

  IF NOT p_apply THEN
    RETURN QUERY SELECT v_considered, v_mapped, v_amb, v_vrej; RETURN;
  END IF;

  -- ── Candidate pairs for rules 2-4: venue + date, name as a GUARD only ────
  DROP TABLE IF EXISTS _p;
  CREATE TEMP TABLE _p ON COMMIT DROP AS
    SELECT n.n2s_id, e.id AS eid,
           public.aq_name_consistent(e.name, n.event_name) AS name_ok,
           (regexp_match(n.event_name, 'session[^0-9]{0,3}([0-9]{1,3})', 'i'))[1] AS n2s_sess,
           (regexp_match(e.name,       'session[^0-9]{0,3}([0-9]{1,3})', 'i'))[1] AS ev_sess
      FROM public.n2s_items n
      JOIN public.events e
        ON e.venue_id = public.cross_source_venue_resolve(n.venue)
       AND left(e.occurs_at_local, 10)::date = n.event_dt::date
     WHERE n.tevo_event_id IS NULL AND NOT n.is_terminal
       AND n.event_dt::date >= current_date
       AND public.cross_source_venue_resolve(n.venue) IS NOT NULL;

  -- Rule 2: exactly one event at that venue that day, and the name agrees.
  UPDATE public.n2s_items n
     SET tevo_event_id = s.eid, mapped_via = 'n2s_venue_date_unique'
    FROM (SELECT n2s_id, min(eid) AS eid
            FROM _p GROUP BY n2s_id
           HAVING count(*) = 1 AND bool_and(name_ok)) s
   WHERE n.n2s_id = s.n2s_id AND n.tevo_event_id IS NULL;
  GET DIAGNOSTICS v_n = ROW_COUNT; v_mapped := v_mapped + v_n;

  -- Rule 3: several events, but the session number picks exactly one.
  -- aq_name_consistent cannot separate tennis sessions — they ARE the same
  -- tournament, so every candidate passes it. The number is the discriminator.
  UPDATE public.n2s_items n
     SET tevo_event_id = s.eid, mapped_via = 'n2s_venue_date_session'
    FROM (SELECT n2s_id, min(eid) FILTER (WHERE ev_sess = n2s_sess) AS eid
            FROM _p
           WHERE n2s_sess IS NOT NULL AND ev_sess IS NOT NULL
           GROUP BY n2s_id
          HAVING count(*) FILTER (WHERE ev_sess = n2s_sess) = 1) s
   WHERE n.n2s_id = s.n2s_id AND n.tevo_event_id IS NULL;
  GET DIAGNOSTICS v_n = ROW_COUNT; v_mapped := v_mapped + v_n;

  -- Rule 4: several events, exactly one of which is name-consistent.
  UPDATE public.n2s_items n
     SET tevo_event_id = s.eid, mapped_via = 'n2s_venue_date_nameguard'
    FROM (SELECT n2s_id, min(eid) FILTER (WHERE name_ok) AS eid
            FROM _p GROUP BY n2s_id
          HAVING count(*) FILTER (WHERE name_ok) = 1) s
   WHERE n.n2s_id = s.n2s_id AND n.tevo_event_id IS NULL;
  GET DIAGNOSTICS v_n = ROW_COUNT; v_mapped := v_mapped + v_n;

  -- ── Rule 5: GoTickets' catalogue as a NAME ALIAS into the event table ────
  -- GT spells events the way the marketplaces do, which is how N2S spells
  -- them. We reach GT -> events and compare events.occurs_at_local, so the
  -- date basis is LOCAL on both sides (see the UTC landmine in the header).
  -- Runs last: it trusts a third party's mapping, so our own rules go first.
  UPDATE public.n2s_items n
     SET tevo_event_id = s.eid, mapped_via = 'n2s_gt_name_alias'
    FROM (
      SELECT n2.n2s_id, min(g.tevo_event_id) AS eid
        FROM public.n2s_items n2
        JOIN public.gotickets_event g
          ON lower(g.name) = lower(n2.event_name)
         AND g.tevo_event_id IS NOT NULL
        JOIN public.events e
          ON e.id = g.tevo_event_id
         AND left(e.occurs_at_local, 10)::date = n2.event_dt::date
       WHERE n2.tevo_event_id IS NULL AND NOT n2.is_terminal
       GROUP BY n2.n2s_id
      HAVING count(DISTINCT g.tevo_event_id) = 1) s
   WHERE n.n2s_id = s.n2s_id AND n.tevo_event_id IS NULL;
  GET DIAGNOSTICS v_n = ROW_COUNT; v_mapped := v_mapped + v_n;

  SELECT count(*)::int INTO v_amb
    FROM public.n2s_items
   WHERE tevo_event_id IS NULL AND NOT is_terminal AND event_dt::date >= current_date;

  RETURN QUERY SELECT v_considered, v_mapped, v_amb, v_vrej;
END $function$;

REVOKE ALL ON FUNCTION public.n2s_map_events(boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.n2s_map_events(boolean) TO service_role;
