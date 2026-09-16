-- ============================================================================
-- Migration 20260916140000 — unstick cross_source_match_tick: index the day
--                            predicate, and bound the two matcher loops
-- Migration 20260916140000 · level:data-collection · lane:A1 · writes:none · reads:events,sg_events_canonical · pre:none
--
-- Lane:     A1 (cross-source xref)
-- Touches:  sg_attempt_event_xref (R), auto_match_sg_canonical (R),
--           auto_match_sg_canonical_v3 (R) — function bodies only.
--           No table, column, index or cron schedule is changed.
--
-- ── THE SYMPTOM ────────────────────────────────────────────────────────────
-- cross_source_match_tick_30min ran clean at a 8.2s mean until 2026-09-15
-- 23:09 UTC. Every run from 23:39 onward has failed, 25 in a row, each at
-- ~307s against its 5-minute statement_timeout:
--
--     ERROR: canceling statement due to statement timeout
--     CONTEXT: SQL statement "SELECT e.id FROM events e LEFT JOIN ..."
--              PL/pgSQL function sg_attempt_event_xref(...) line 28
--              PL/pgSQL function auto_match_sg_canonical() line 20
--              ...  PL/pgSQL function cross_source_match_tick() line 4
--
-- That is ~12.5 hours with the SeatGeek↔TEvo canonical matcher fully dark:
-- no new cross-source links at all, and the evo/sd legs of the same tick
-- never reached either, because they run after the leg that dies.
--
-- ── THE MECHANISM: A RATCHET, NOT A SLOWDOWN ──────────────────────────────
-- auto_match_sg_canonical() loops over EVERY unmatched canonical SG event
-- (1,989 of them today) and calls sg_attempt_event_xref() once per row. The
-- loop has no LIMIT and no wall clock. When the total crosses the statement
-- timeout the whole transaction rolls back — so the matches it DID make are
-- discarded, the unmatched set does not shrink, and the next tick re-attempts
-- the identical 1,989 rows and dies at the identical point. Once it tips, it
-- can never recover on its own. It did not degrade gradually; it latched.
--
-- What tipped it is the per-row cost, measured on prod against the exact
-- predicate in the trace:
--
--   WHERE e.occurs_at_local::date = $1        Seq Scan, 118,122 rows removed
--                                             11,885 buffers    124.7 ms
--   WHERE left(e.occurs_at_local,10) = ...    Index Scan on
--                                             events_local_day_idx
--                                                908 rows removed
--                                                463 buffers      8.5 ms
--
-- 124.7ms x 1,989 rows = 248s, which is the ~307s failure. `events` holds
-- only 118k rows in 104 MB, so this scan was cheap while the table stayed
-- resident; on a 414 GB instance with 2 GB of shared_buffers and a listings
-- firehose evicting everything, it stopped being resident and the per-row
-- cost went up ~15x. The seq scan was always the bug — cache was hiding it.
--
-- ── FIX 1: USE THE INDEX THAT ALREADY EXISTS ──────────────────────────────
-- `events.occurs_at_local` is TEXT, not a timestamp, and the index on it is
--
--     events_local_day_idx ON events (left(occurs_at_local, 10))
--
-- `occurs_at_local::date` is a different expression, so it never matched that
-- index and always seq-scanned. Rewriting the predicate to left(...) makes it
-- sargable. No new index is created: the right one was already there, unused.
--
-- Equivalence was verified across the whole table before rewriting, not
-- assumed from the format:
--
--   total rows                                              118,122
--   occurs_at_local IS NULL                                       0
--   matching '^\d{4}-\d{2}-\d{2}'                           118,122
--   left(occurs_at_local,10) <> to_char(occurs_at_local::date,
--                                       'YYYY-MM-DD')              0
--
-- Zero rows disagree, so the rewrite selects exactly the same set. NULL input
-- behaves the same too: `= NULL` and `= to_char(NULL,...)` both match nothing.
--
-- ── FIX 2: BOUND BOTH LOOPS SO A ROLLBACK CANNOT ERASE A PASS ────────────
-- Fix 1 takes the pass to roughly 1,989 x 8.5ms ~ 17s, comfortably inside the
-- 5-minute limit. That is not enough on its own: the ratchet is structural.
-- Any future per-row regression — a plan flip, a colder cache, a larger
-- unmatched set — re-creates exactly this permanent stall. So both matcher
-- loops now stop on their own wall clock, well before the statement timeout,
-- and RETURN normally. Returning normally is the whole point: the transaction
-- commits, the matches made in that pass persist, the unmatched set shrinks,
-- and the next tick picks up from a smaller set instead of repeating a doomed
-- one. Partial progress beats a clean rollback.
--
-- 90s each, inside the job's 300s: two matcher passes plus the sync, backsync,
-- evo and sd legs that share the same tick.
--
-- Rows are visited in a per-tick shuffled order (md5 of the id salted by the
-- half-hour). A stable ORDER BY plus a budget cut would re-process the same
-- head every tick and starve the tail forever; reshuffling each tick gives
-- every row an even chance of being reached. It costs nothing at 1,989 rows.
--
-- The budget is a constant in the body rather than a new parameter: adding a
-- parameter, even with a DEFAULT, creates an overload rather than replacing
-- the function (PROJECT_BIBLE §7), and no caller needs to vary it.
--
-- ── DELIBERATELY NOT IN THIS MIGRATION ────────────────────────────────────
-- sg_attempt_event_xref_v3 carries the same `occurs_at_local::date` /
-- `::timestamptz` pattern and is the leg that runs immediately after this one.
-- It is NOT rewritten here. Its predicate is a +/-24h range against a text
-- column whose local offsets vary, so making it sargable means adding a
-- widened whole-day pre-filter and reasoning about timezone edges — and it
-- has never actually been observed running, because v1 has been timing out
-- before it is reached. It gets fixed against measurements once v1 is
-- unstuck, not blind. Its loop is bounded here in the meantime, so it cannot
-- reproduce the ratchet while it waits.
--
-- Twelve other functions share the `occurs_at_local::date` seq-scan pattern
-- (broker_recent_intel, find_similar_events, refresh_concierge_events, ...).
-- Most are request-scoped RPCs where one 124ms scan per call is tolerable,
-- unlike a 1,989-iteration loop. They are noted for a separate sweep rather
-- than rewritten inside a fix for a failing cron.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. sg_attempt_event_xref — same logic, sargable day predicate.
--    Signature unchanged; only the WHERE clause differs from the prior body.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.sg_attempt_event_xref(
  p_sg_event_id bigint, p_sg_event_name text, p_sg_event_date date, p_sg_venue text)
 RETURNS bigint
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_tevo_event_id bigint;
  v_existing      bigint;
  v_sg_team_a     text;
  v_sg_team_b     text;
BEGIN
  -- A1 parking guard 2026-05-17: never bridge parking pseudo-events.
  IF coalesce(p_sg_event_name, '') ILIKE '%parking%'
     OR coalesce(p_sg_venue, '')      ILIKE '%parking%' THEN
    RETURN NULL;
  END IF;

  SELECT tevo_event_id INTO v_existing
  FROM seatgeek_event_xref WHERE sg_event_id = p_sg_event_id LIMIT 1;
  IF v_existing IS NOT NULL THEN
    UPDATE seatgeek_event_xref
       SET sg_event_name = COALESCE(p_sg_event_name, sg_event_name),
           sg_event_location = COALESCE(p_sg_venue, sg_event_location)
     WHERE sg_event_id = p_sg_event_id;
    RETURN v_existing;
  END IF;

  v_sg_team_a := trim(split_part(COALESCE(p_sg_event_name, ''), ' at ', 1));
  v_sg_team_b := trim(split_part(COALESCE(p_sg_event_name, ''), ' at ', 2));
  IF v_sg_team_b = '' THEN v_sg_team_b := v_sg_team_a; END IF;

  SELECT e.id INTO v_tevo_event_id
  FROM events e
  LEFT JOIN event_lifecycle lc ON lc.event_id = e.id
  -- was: e.occurs_at_local::date = p_sg_event_date  (seq scan, 124.7ms)
  -- now: matches events_local_day_idx exactly       (index scan,  8.5ms)
  WHERE left(e.occurs_at_local, 10) = to_char(p_sg_event_date, 'YYYY-MM-DD')
    AND (
      lower(trim(e.venue_name)) = lower(trim(COALESCE(p_sg_venue, '')))
      OR lower(trim(e.venue_name)) LIKE lower(trim(COALESCE(p_sg_venue, ''))) || '%'
      OR lower(trim(COALESCE(p_sg_venue, ''))) LIKE lower(trim(e.venue_name)) || '%'
    )
    AND (
      v_sg_team_b <> '' AND (
        lower(e.primary_performer_name) LIKE '%' || lower(v_sg_team_b) || '%'
        OR lower(e.name) LIKE '%' || lower(v_sg_team_b) || '%'
      )
      OR
      v_sg_team_a <> '' AND (
        lower(e.primary_performer_name) LIKE '%' || lower(v_sg_team_a) || '%'
        OR lower(e.name) LIKE '%' || lower(v_sg_team_a) || '%'
      )
    )
  ORDER BY
    CASE WHEN COALESCE(lc.is_active, true) THEN 0 ELSE 1 END,
    CASE WHEN lower(trim(e.venue_name)) = lower(trim(COALESCE(p_sg_venue, ''))) THEN 0 ELSE 1 END,
    CASE WHEN v_sg_team_b <> '' AND lower(e.primary_performer_name) LIKE '%' || lower(v_sg_team_b) || '%' THEN 0 ELSE 1 END
  LIMIT 1;

  IF v_tevo_event_id IS NOT NULL THEN
    INSERT INTO seatgeek_event_xref (
      tevo_event_id, sg_event_id, sg_event_name, sg_event_type,
      sg_event_location, sg_start_data, match_method, match_confidence
    ) VALUES (
      v_tevo_event_id, p_sg_event_id, p_sg_event_name, NULL,
      p_sg_venue,
      make_timestamptz(
        EXTRACT(YEAR FROM p_sg_event_date)::int,
        EXTRACT(MONTH FROM p_sg_event_date)::int,
        EXTRACT(DAY FROM p_sg_event_date)::int, 0, 0, 0, 'UTC'),
      'auto_seller_inline_v2', 0.9
    )
    ON CONFLICT (tevo_event_id) DO UPDATE
      SET sg_event_id = EXCLUDED.sg_event_id,
          sg_event_name = EXCLUDED.sg_event_name,
          sg_event_location = EXCLUDED.sg_event_location,
          match_method = 'auto_seller_inline_v2',
          matched_at = NOW();
  END IF;
  RETURN v_tevo_event_id;
END $function$;

-- ---------------------------------------------------------------------------
-- 2. auto_match_sg_canonical — 90s wall clock, shuffled order.
--    Returned columns and their meaning are unchanged: attempted/newly_matched
--    /still_unmatched describe THIS pass (which may now be partial), and
--    needs_tevo_search remains the live total.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.auto_match_sg_canonical()
 RETURNS TABLE(attempted integer, newly_matched integer, still_unmatched integer, needs_tevo_search integer)
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  r RECORD;
  v_match bigint;
  v_attempted int := 0;
  v_matched int := 0;
  v_unmatched int := 0;
  v_start timestamptz := clock_timestamp();
  v_budget constant interval := interval '90 seconds';
BEGIN
  FOR r IN
    SELECT sg_event_id, sg_event_name, sg_event_date, sg_venue_name
    FROM sg_events_canonical
    WHERE tevo_event_id IS NULL
      AND (sg_event_date IS NULL OR sg_event_date >= current_date - 30)
      -- A1 parking guard 2026-05-17: never auto-match parking pseudo-events.
      -- TEvo merges parking into the main listing; SG splits them out.
      AND coalesce(sg_event_name, '') NOT ILIKE '%parking%'
      AND coalesce(sg_venue_name, '') NOT ILIKE '%parking%'
    -- Reshuffled every half hour so a budget-truncated pass does not
    -- re-process the same head forever and starve the tail.
    ORDER BY md5(sg_event_id::text
                 || floor(extract(epoch FROM clock_timestamp()) / 1800)::text)
  LOOP
    EXIT WHEN clock_timestamp() - v_start > v_budget;

    v_attempted := v_attempted + 1;
    v_match := sg_attempt_event_xref(
      r.sg_event_id, r.sg_event_name, r.sg_event_date, r.sg_venue_name
    );
    IF v_match IS NOT NULL THEN
      UPDATE sg_events_canonical SET
        tevo_event_id = v_match,
        match_method = 'auto_canonical_loop',
        match_confidence = 0.9,
        matched_at = now(),
        updated_at = now()
      WHERE sg_event_id = r.sg_event_id;
      v_matched := v_matched + 1;
    ELSE
      v_unmatched := v_unmatched + 1;
    END IF;
  END LOOP;

  RETURN QUERY SELECT v_attempted, v_matched, v_unmatched,
    (SELECT count(*)::int FROM sg_events_canonical WHERE tevo_event_id IS NULL);
END;
$function$;

-- ---------------------------------------------------------------------------
-- 3. auto_match_sg_canonical_v3 — same 90s bound and shuffle.
--    Its inner matcher is untouched (see header); this only stops it from
--    latching the same way while it waits for its own fix.
--    SECURITY DEFINER is carried over deliberately: this function is defined
--    that way in prod, and CREATE OR REPLACE without it would silently demote
--    it to SECURITY INVOKER. The v1 pair above is INVOKER and stays INVOKER
--    (checked against pg_proc.prosecdef, not assumed).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.auto_match_sg_canonical_v3()
 RETURNS TABLE(attempted integer, newly_matched integer, parking_skipped integer, still_unmatched integer, needs_tevo_search integer)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  r RECORD;
  v_match bigint;
  v_attempted int := 0;
  v_matched int := 0;
  v_parking int := 0;
  v_unmatched int := 0;
  v_start timestamptz := clock_timestamp();
  v_budget constant interval := interval '90 seconds';
BEGIN
  FOR r IN
    SELECT sg_event_id, sg_event_name, sg_event_date, sg_datetime_utc,
           sg_venue_name, sg_venue_city, sg_venue_state, sg_category
    FROM public.sg_events_canonical
    WHERE tevo_event_id IS NULL
      AND (sg_event_date IS NULL OR sg_event_date >= current_date - 30)
    ORDER BY md5(sg_event_id::text
                 || floor(extract(epoch FROM clock_timestamp()) / 1800)::text)
  LOOP
    EXIT WHEN clock_timestamp() - v_start > v_budget;

    v_attempted := v_attempted + 1;

    IF r.sg_category IN ('Parking','parking')
       OR coalesce(r.sg_venue_name,'') ILIKE '%parking%'
       OR coalesce(r.sg_event_name,'') ILIKE '%parking%' THEN
      v_parking := v_parking + 1;
      CONTINUE;
    END IF;

    v_match := public.sg_attempt_event_xref_v3(
      r.sg_event_id, r.sg_event_name, r.sg_event_date, r.sg_datetime_utc,
      r.sg_venue_name, r.sg_venue_city, r.sg_venue_state, r.sg_category
    );

    IF v_match IS NOT NULL THEN
      UPDATE public.sg_events_canonical SET
        tevo_event_id = v_match,
        match_method = 'matcher_v3_pm24h',
        match_confidence = 0.9,
        matched_at = now(),
        updated_at = now()
      WHERE sg_event_id = r.sg_event_id;
      v_matched := v_matched + 1;
    ELSE
      v_unmatched := v_unmatched + 1;
    END IF;
  END LOOP;

  RETURN QUERY SELECT v_attempted, v_matched, v_parking, v_unmatched,
    (SELECT count(*)::int FROM public.sg_events_canonical
      WHERE tevo_event_id IS NULL AND sg_datetime_utc > now());
END;
$function$;
