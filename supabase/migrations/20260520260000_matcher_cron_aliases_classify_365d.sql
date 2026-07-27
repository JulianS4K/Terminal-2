-- Migration 20260520260000 · lane:A1 · writes:cross_source_venue_map,sg_classify_events,cron · pre:20260520220000
--
-- Three-in-one: matcher cron + 4 venue aliases + classify window 60d → 365d.
--
-- WHY (analysis 2026-05-18):
--   1. 1,294 future US SG events are unmapped to TEvo. Investigation showed:
--      - Most are real upstream-TEvo coverage gaps (TEvo doesn't carry the
--        far-future MLB/MLS games SG knows about). The search bridge
--        (sg_to_tevo_search_bridge_30min, 48 fires/24h, 444 matches in 7d)
--        is already filling these in as TEvo's API surfaces them.
--      - 4 venues exist in cross_source_venue_map with empty sg_aliases,
--        blocking the local matcher from bridging events at those venues
--        even when TEvo HAS the game.
--      - The local matcher (auto_match_sg_canonical_v3) has NO cron schedule.
--        It works perfectly when called manually but only runs implicitly
--        via match_listings_to_sg_30min (listings-side, different path).
--      - sg_classify_events has a hard "+ 60 days" upper bound on the date
--        window. Result: 1,052 of the 1,294 unmapped US future events are
--        NOT in priority_state at all → invisible to the polling pipeline
--        → no time-series capture → can't power a movers tracker.
--
-- WHAT:
--   A. UPDATE cross_source_venue_map.sg_aliases for 4 venues that have a
--      TEvo entry but no SG alias populated. Unlocks the local matcher for
--      events at these venues:
--        414   Dodger Stadium                        → ["Uniqlo Field at Dodger Stadium"]
--        1343  Moda Center at the Rose Quarter       → ["Moda Center"]
--        5194  Nationals Park                        → ["Nationals Park"]
--        34957 Gateway Center Arena at College Park  → ["Gateway Center Arena at College Park"]
--
--   B. CREATE OR REPLACE sg_classify_events with date window upper bound
--      expanded from `+60 days` to `+365 days`. All other gates and the
--      tier-policy ELSE lookup are byte-identical. Unmatched future US
--      events automatically land in OBSERVE tier (requires_owned=false,
--      0-720h via policy) for events ≤ 30d out, or fall to SKIP for further
--      future (sort_order 8). The 30d–365d range covers the bulk of MLB
--      late-season + NCAA football season tracking the operator wants.
--
--      Cost: classify reads 4,191 future events (vs ~1,500 before) plus
--      24h listings_snapshots aggregates. Function should stay well under
--      cron statement_timeout.
--
--   C. cron.schedule 'auto_match_sg_canonical_v3_hourly' at :07. Wraps the
--      matcher with the standard cron_should_fire policy gate. Picks up
--      new SG canonical events as they're ingested and auto-bridges them
--      to TEvo when both sides have the event.
--      Cost: matcher iterates events with tevo_event_id IS NULL AND
--      sg_event_date >= current_date - 30. ~2,200 events today, scans
--      drops as bridging catches up.
--
--   D. INSERT cron_policy row for the new cron with sane limits.
--
-- INVARIANTS PRESERVED:
--   - sg_classify_events signature, return type, and policy-lookup ELSE
--     clause byte-identical to mig 20260520210000 except the date window.
--   - Existing crons (sg_to_tevo_search_bridge_30min, match_listings_to_sg_30min,
--     sg_classify_events_5min) untouched.
--   - cross_source_venue_map: append-only to sg_aliases via jsonb_build_array.
--     Other venue rows untouched.
--
-- POST-APPLY WORK (operator may want to run these once, NOT in this migration):
--   SELECT public.sg_classify_events();          -- bring 365d-window events into priority_state
--   SELECT public.auto_match_sg_canonical_v3();  -- bridge any newly-alias-resolvable events

-- ============================================================
-- A. Venue alias fills (4 rows)
-- ============================================================
UPDATE public.cross_source_venue_map
   SET sg_aliases = jsonb_build_array('Uniqlo Field at Dodger Stadium'),
       updated_at = now()
 WHERE tevo_venue_id = 414
   AND jsonb_array_length(coalesce(sg_aliases, '[]'::jsonb)) = 0;

UPDATE public.cross_source_venue_map
   SET sg_aliases = jsonb_build_array('Moda Center'),
       updated_at = now()
 WHERE tevo_venue_id = 1343
   AND jsonb_array_length(coalesce(sg_aliases, '[]'::jsonb)) = 0;

UPDATE public.cross_source_venue_map
   SET sg_aliases = jsonb_build_array('Nationals Park'),
       updated_at = now()
 WHERE tevo_venue_id = 5194
   AND jsonb_array_length(coalesce(sg_aliases, '[]'::jsonb)) = 0;

UPDATE public.cross_source_venue_map
   SET sg_aliases = jsonb_build_array('Gateway Center Arena at College Park'),
       updated_at = now()
 WHERE tevo_venue_id = 34957
   AND jsonb_array_length(coalesce(sg_aliases, '[]'::jsonb)) = 0;


-- ============================================================
-- B. sg_classify_events: expand date window 60d → 365d
-- ============================================================
-- All gates + ELSE clause byte-identical to mig 20260520210000. Only the
-- date-window upper bound changes (line marked "WINDOW EXPANSION").

CREATE OR REPLACE FUNCTION public.sg_classify_events()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_now timestamptz := clock_timestamp();
  v_updated int := 0;
BEGIN
  WITH listings_by_tevo AS (
    SELECT event_id AS tevo_event_id,
           count(*) FILTER (WHERE is_owned = true) AS owned_cnt,
           count(*) AS listings_cnt
    FROM public.listings_snapshots
    WHERE captured_at > v_now - interval '24 hours'
      AND event_id IS NOT NULL
    GROUP BY event_id
  ),
  listings_by_aq AS (
    SELECT aq_short_event_id,
           count(*) FILTER (WHERE is_owned = true) AS owned_cnt,
           count(*) AS listings_cnt
    FROM public.listings_snapshots
    WHERE captured_at > v_now - interval '24 hours'
      AND aq_short_event_id IS NOT NULL
    GROUP BY aq_short_event_id
  ),
  event_metrics AS (
    SELECT c.sg_event_id, c.sg_event_name, c.sg_venue_name, c.sg_datetime_utc,
           a.aq_short_event_id,
           coalesce(c.tevo_event_id,
                    (SELECT x.tevo_event_id FROM public.seatgeek_event_xref x
                     WHERE x.sg_event_id = c.sg_event_id LIMIT 1)) AS tevo_event_id,
           EXTRACT(epoch FROM (c.sg_datetime_utc - v_now)) / 3600 AS hours_to_event,
           coalesce(lt.owned_cnt,    la.owned_cnt,    0) AS owned_cnt,
           coalesce(lt.listings_cnt, la.listings_cnt, 0) AS listings_cnt
    FROM public.sg_events_canonical c
    -- LATERAL with deterministic preference for non-SYS aq ids: aq_event_map has
    -- rows with multiple aq_short_event_ids per sg_event_id (SYS-* synthetic +
    -- real aq id pairs for some NFL events). Plain LEFT JOIN duped rows into
    -- the INSERT, hitting "ON CONFLICT cannot affect row a second time" — was
    -- failing 12 of 72 sg_classify_events_5min fires pre-fix.
    LEFT JOIN LATERAL (
      SELECT aq_short_event_id
      FROM public.aq_event_map
      WHERE sg_event_id = c.sg_event_id
      ORDER BY (aq_short_event_id LIKE 'SYS-%') ASC, aq_short_event_id
      LIMIT 1
    ) a ON true
    LEFT JOIN listings_by_tevo lt ON lt.tevo_event_id = c.tevo_event_id
    LEFT JOIN listings_by_aq   la ON la.aq_short_event_id = a.aq_short_event_id
    WHERE c.sg_datetime_utc IS NOT NULL
      -- WINDOW EXPANSION (mig 20260520260000): was '+ 60 days', now '+ 365 days'
      -- to bring far-future US events into priority_state so polling pipeline
      -- captures their time-series for the movers tracker.
      AND c.sg_datetime_utc BETWEEN v_now - interval '6 hours' AND v_now + interval '365 days'
  ),
  classified AS (
    SELECT em.*,
      CASE
        WHEN em.sg_event_name ~* '(cancelled|if necessary)' THEN 'SKIP'
        WHEN em.sg_event_name ~* '(\(date tbd\)|^TBD at )'
             AND em.tevo_event_id IS NULL THEN 'SKIP'
        -- WATCH threshold scaled to 24h window: was >500/7d, now >150/24h
        WHEN em.hours_to_event >= 0
             AND em.hours_to_event < 168
             AND em.owned_cnt = 0
             AND em.listings_cnt > 150 THEN 'WATCH'
        ELSE
          (SELECT p.tier FROM public.sg_priority_policy p
           WHERE p.enabled = true
             AND em.hours_to_event >= coalesce(p.min_hours_to_event, -999999)
             AND em.hours_to_event <  coalesce(p.max_hours_to_event, 999999)
             AND (p.requires_owned = false OR em.owned_cnt > 0)
           ORDER BY p.sort_order LIMIT 1)
      END AS tier
    FROM event_metrics em
  )
  INSERT INTO public.sg_event_priority_state AS s
    (sg_event_id, sg_event_name, sg_venue_name, sg_datetime_utc, aq_short_event_id,
     tevo_event_id, owned_count_last_7d, active_listings_last_7d, tier, hours_to_event, computed_at)
  SELECT sg_event_id, sg_event_name, sg_venue_name, sg_datetime_utc, aq_short_event_id,
         tevo_event_id, owned_cnt, listings_cnt, coalesce(tier, 'SKIP'), hours_to_event, v_now
  FROM classified WHERE sg_event_id IS NOT NULL
  ON CONFLICT (sg_event_id) DO UPDATE SET
    sg_event_name           = EXCLUDED.sg_event_name,
    sg_venue_name           = EXCLUDED.sg_venue_name,
    sg_datetime_utc         = EXCLUDED.sg_datetime_utc,
    aq_short_event_id       = EXCLUDED.aq_short_event_id,
    tevo_event_id           = EXCLUDED.tevo_event_id,
    owned_count_last_7d     = EXCLUDED.owned_count_last_7d,
    active_listings_last_7d = EXCLUDED.active_listings_last_7d,
    tier                    = EXCLUDED.tier,
    hours_to_event          = EXCLUDED.hours_to_event,
    computed_at             = EXCLUDED.computed_at,
    sales_polls_today       = CASE WHEN s.budget_day < current_date THEN 0 ELSE s.sales_polls_today END,
    listings_polls_today    = CASE WHEN s.budget_day < current_date THEN 0 ELSE s.listings_polls_today END,
    budget_day              = current_date;

  GET DIAGNOSTICS v_updated = ROW_COUNT;
  RETURN v_updated;
END
$function$;


-- ============================================================
-- C. cron schedule for auto_match_sg_canonical_v3 (hourly)
-- ============================================================
-- Pattern: standard cron_should_fire wrapper per PROJECT_BIBLE §7.
-- Cadence: hourly at :07. Matcher is read-heavy + does small batch INSERTs;
-- one fire per hour is sufficient and stays well under statement_timeout.
SELECT cron.schedule(
  'auto_match_sg_canonical_v3_hourly',
  '7 * * * *',
  $cron$
  DO $body$
  BEGIN
    IF NOT public.cron_should_fire('auto_match_sg_canonical_v3_hourly') THEN
      RETURN;
    END IF;
    PERFORM public.auto_match_sg_canonical_v3();
  END $body$;
  $cron$
);


-- ============================================================
-- D. cron_policy row for the new cron
-- ============================================================
INSERT INTO public.cron_policy
  (jobname, peak_hours_et, peak_min_interval_min, offpeak_min_interval_min,
   work_check_sql, daily_max_fires, enabled, notes, updated_at)
VALUES
  ('auto_match_sg_canonical_v3_hourly',
   ARRAY[]::int[],
   60, 60,
   $$ SELECT EXISTS (
        SELECT 1 FROM public.sg_events_canonical
        WHERE tevo_event_id IS NULL
          AND sg_event_date >= current_date - 30
        LIMIT 1
      ) $$,
   24,
   true,
   'Hourly local-matcher sweep. Companion to sg_to_tevo_search_bridge_30min (which fires TEvo /v9/events searches for events TEvo doesn''t carry locally). Skip when no candidates remain.',
   now())
ON CONFLICT (jobname) DO NOTHING;


-- ============================================================
-- Post-apply verification (operator may run these once)
-- ============================================================
-- 1) Venue aliases populated:
--    SELECT tevo_venue_id, tevo_venue_name, sg_aliases FROM public.cross_source_venue_map
--    WHERE tevo_venue_id IN (414, 1343, 5194, 34957);
--    -- expect: 4 rows, each with non-empty sg_aliases.
--
-- 2) Cron registered:
--    SELECT jobname, schedule, active FROM cron.job
--    WHERE jobname = 'auto_match_sg_canonical_v3_hourly';
--
-- 3) Classify expansion test (run BEFORE and AFTER classify to compare):
--    SELECT count(*) AS before_classify FROM public.sg_event_priority_state;
--    SELECT public.sg_classify_events();
--    SELECT count(*) AS after_classify FROM public.sg_event_priority_state;
--    -- Expect after > before by hundreds (1,052 newly-eligible US events).
--
-- 4) Drain backlog with newly-aliased venues:
--    SELECT * FROM public.auto_match_sg_canonical_v3();
--    -- expect newly_matched to include events at the 4 newly-aliased venues
--    -- (Dodger / Moda / Nationals / Gateway).
