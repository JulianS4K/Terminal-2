-- ============================================================================
-- Migration 20260910110000 — map the remaining N2S events; force a
--                            TicketsData pull for every future N2S event
--
-- Lane:     D0 (orders surface)
-- Touches:  n2s_map_events() (rules 2-4 added), n2s_td_enqueue() (scope widened)
-- Pre-reqs: 20260910100000
--
-- READ-ONLY upstream: no API call here. Queues rows the budget-checked
-- n2s_td_drain() fires. RULE 2 holds.
--
-- Operator direction 2026-09-09: "fix unmapped and force ping tickets data for
-- all future listings."
--
-- ── Why 61 items were unmapped, measured rather than guessed ───────────────
-- Rule 1 (exact event name + exact local date) left 61 open future items
-- unmapped. The cause was NOT the venue and NOT the date:
--   * 60 of the 61 HAVE a venue+date match in `events`
--   * every one of their venues resolves through cross_source_venue_resolve()
--   * only 2 had their name existing on any other date
-- The failure is purely that `events` spells the event differently from N2S.
-- So the fix is to key on venue + date — which we can resolve reliably — and
-- use the NAME only as a guard, exactly the shape of s4kcs_map_events rule 5.
--
-- ⚠ VENUE + DATE IS NOT UNIQUE ON ITS OWN AND MUST NEVER BE USED BARE.
-- Of the 60, only 31 resolve to a single event; 29 sit at a venue hosting
-- SEVERAL events that day. Binding those on venue+date alone would hand an
-- order seats for the wrong game at the right building — the same class of
-- error as the Monster Jam tour-leg case (mig 20260908195605). Hence the
-- laddered rules below, each requiring a unique survivor.
--
-- Rule 2  venue + date, exactly ONE event there that day, and
--         aq_name_consistent() agrees.                       -> 31 items
--         (Measured: all 31 pass the name guard; 0 rejected.)
-- Rule 3  venue + date, several events, and the SESSION NUMBER parsed from
--         both names matches exactly one.                    -> 27 items
-- Rule 4  venue + date, several events, and exactly ONE is name-consistent.
--                                                            ->  3 items
--
-- ⚠ RULE 3 EXISTS BECAUSE aq_name_consistent() CANNOT SEPARATE TENNIS
-- SESSIONS. All 26 stubbornly-ambiguous items were US Open Tennis at Arthur
-- Ashe Stadium: "US Open Tennis - Session 21", "…Session 22",
-- "2026 US Open Tennis Championships - Session 21" — same venue, same day,
-- and every candidate passes the shared-token name guard because they ARE the
-- same tournament. The session NUMBER is the only discriminator. Measured on
-- the live set: 27 items carry a session number, all 27 of their candidate
-- events carry one too, and matching on it resolved 27 uniquely with 0 left
-- ambiguous and 0 unmatched. Note this is deliberately NOT a general fuzzy
-- fallback: it fires only when both sides expose a session number and exactly
-- one candidate matches it.
--
-- ⚠ ALL RULES ARE FILL-ONLY (tevo_event_id IS NULL) and each demands a UNIQUE
-- survivor. A rule that cannot narrow to one event declines rather than
-- guessing — a wrong event id silently offers seats for the wrong game, which
-- is worse than an unmapped order.
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
    GET DIAGNOSTICS v_mapped = ROW_COUNT;
  ELSE
    SELECT count(*)::int INTO v_mapped FROM _m
     WHERE n_events = 1
       AND (n2s_venue_id IS NULL OR ev_venue_id IS NULL OR n2s_venue_id = ev_venue_id);
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

  SELECT count(*)::int INTO v_amb
    FROM public.n2s_items
   WHERE tevo_event_id IS NULL AND NOT is_terminal AND event_dt::date >= current_date;

  RETURN QUERY SELECT v_considered, v_mapped, v_amb, v_vrej;
END $function$;

REVOKE ALL ON FUNCTION public.n2s_map_events(boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.n2s_map_events(boolean) TO service_role;

-- ── TicketsData: every future N2S event, not just new arrivals ─────────────
-- ⚠ THE notified_at FILTER IS GONE ON PURPOSE. It scoped enqueues to orders
-- never yet announced, which is right for "poll newest as they come in" but
-- wrong for "force ping for ALL future listings": an order announced an hour
-- ago still needs fresh inventory to be re-priced against. p_max rises from 20
-- to 200 for the same reason.
-- The spend guards are untouched and still bound this: n2s_td_drain() fires at
-- most p_max per run under the 500/day cap, and backs off entirely while the
-- vendor reports quota exhausted. Enqueueing more work does not enqueue more
-- SPEND — it only means the cap is spent on the most useful events.
CREATE OR REPLACE FUNCTION public.n2s_td_enqueue(
  p_max          integer  DEFAULT 200,
  p_recent_fired interval DEFAULT interval '20 minutes'
)
RETURNS TABLE(events_enqueued integer, budget_ok boolean)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $function$
DECLARE
  v_n integer := 0; v_ok boolean;
BEGIN
  SELECT public.td_budget_ok() INTO v_ok;

  WITH want AS (
    SELECT DISTINCT n.tevo_event_id AS eid
      FROM public.n2s_items n
     WHERE NOT n.is_terminal
       AND n.tevo_event_id IS NOT NULL
       AND n.event_dt::date >= current_date
     ORDER BY 1
     LIMIT p_max
  ),
  cand AS (
    SELECT x.event_id, x.platform, x.event_url
      FROM public.ticketsdata_event_xref x
      JOIN want w ON w.eid = x.event_id
     WHERE x.event_url IS NOT NULL
       AND COALESCE(x.active, true)
       AND NOT EXISTS (
         SELECT 1 FROM public.td_pull_queue q
          WHERE q.event_id = x.event_id AND q.platform = x.platform
            AND (q.resolved_at IS NULL OR q.fired_at > now() - p_recent_fired))
  ),
  ins AS (
    INSERT INTO public.td_pull_queue (event_id, platform, event_url, interval_tag)
    SELECT event_id, platform, event_url, 'n2s_ondemand' FROM cand
    RETURNING 1
  )
  SELECT count(*)::int INTO v_n FROM ins;

  RETURN QUERY SELECT v_n, v_ok;
END $function$;

REVOKE ALL ON FUNCTION public.n2s_td_enqueue(integer, interval) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.n2s_td_enqueue(integer, interval) TO service_role;
