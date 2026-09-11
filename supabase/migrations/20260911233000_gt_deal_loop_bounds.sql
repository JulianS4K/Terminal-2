-- ============================================================================
-- Migration 20260911233000 — bind the GoTickets/deal loops, point GT at its own cadence
-- Migration 20260911233000 · level:data-collection · lane:A1 · writes:cron.job,cron_policy,collector_cadence,gt_listings_poll_state,gt_listings_inflight · reads:gotickets_event,events,gotickets_listings_snapshots · pre:20260804230000
--
-- Lane:     A1 (crons + ingest)
-- Touches:  gt_listings_poll_tick (replaced), collector_cadence (W),
--           cron.job (W), cron_policy (W)
-- Pre-reqs: 20260804230000 (GT listings firehose + retention), collector_cadence
--
-- Three separate problems, all landing on the same scheduler:
--
-- 1. GT WAS POLLING ON EVO'S CADENCE. gt_listings_poll_tick called
--    collector_band('EVO','listings', hte) — hardcoded. collector_cadence has
--    had seven 'GT' rows all along, and they were dead config: editing them
--    changed nothing, which defeats the whole point of a data-driven cadence
--    ("data -> instant revert", RESOURCES_BIBLE §5). Now it reads 'GT'.
--
--    EVO's bands were set for a source documented as "≈unlimited". On GT's
--    4,221-event pollable set they work out to ~53k polls/day -> ~5.4M
--    snapshot rows/day, and gotickets_listings_snapshots is now the largest
--    table in the database at 130 GB / 135.6M live rows / 18.2M dead. The GT
--    rows below land at ~25k polls/day, keeping the ≤3d band tight (10 min)
--    and paying for it in the 61d+ tail, where 2,870 of those events sit.
--
-- 2. THE TICK COULD OUTRUN ITS OWN PERIOD. gt_listings_poll_tick(300) fires up
--    to 300 async requests with no wall-clock bound and has been averaging
--    60.9s on a */2 schedule. A cron job that outlives its period holds a
--    connection slot continuously (use_background_workers=off), which is how
--    the scheduler starts shedding jobs with "job startup timeout" — 91 such
--    failures in 90 minutes on 2026-09-11. Bounded here.
--
-- 3. DEADLOCK between gt_ingest_drain_1min and gt_deals_scan_odd_min. Both
--    write gt_listings_poll_state; on even/odd minutes they interleave every
--    other minute. Four 'deadlock detected' aborts in the last 24h. The scan
--    now takes the same advisory lock the drain holds, so they serialise
--    instead of colliding.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. GT reads its OWN cadence rows, and the loop is wall-clock bounded
--
-- p_budget_seconds is a NEW parameter, so the prior 1-arg signature must be
-- dropped explicitly — adding a parameter (even with a DEFAULT) creates an
-- overload rather than replacing, and callers passing one arg would then hit
-- "function gt_listings_poll_tick(integer) is not unique" (PROJECT_BIBLE §7).
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.gt_listings_poll_tick(integer);

CREATE OR REPLACE FUNCTION public.gt_listings_poll_tick(
  p_max            integer DEFAULT 300,
  p_budget_seconds integer DEFAULT 75)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  r RECORD; v_n int := 0; v_req bigint; v_token text;
  v_daily_cap int := 1000000;
  v_near int := GREATEST(1, (p_max * 2) / 3);  -- ~2/3 budget on overdue-ratio (mirrors evo_listings_poll_tick)
  v_start timestamptz := clock_timestamp();
BEGIN
  IF p_max <= 0 THEN RETURN 0; END IF;
  IF (SELECT coalesce(sum(listings_polls_today),0) FROM public.gt_listings_poll_state
        WHERE budget_day = current_date) >= v_daily_cap THEN
    RETURN 0;
  END IF;
  v_token := public._gotickets_pro_token();
  FOR r IN
    WITH ev AS (
      -- Scope == the EVO polling set, reached through the GT->TEvo mapping.
      -- Band hours come from the EVO event's clock so both sources agree on band.
      SELECT g.gt_event_id, g.tevo_event_id,
             EXTRACT(epoch FROM (e.occurs_at_local::timestamptz - now()))/3600.0 AS hte,
             ps.last_polled_listings_at
        FROM public.gotickets_event g
        JOIN public.events e ON e.id = g.tevo_event_id
        LEFT JOIN public.gt_listings_poll_state ps ON ps.gt_event_id = g.gt_event_id
       WHERE g.status = 'AS_SCHEDULED'
         AND e.occurs_at_local IS NOT NULL
         AND e.occurs_at_local::timestamptz > now() - interval '3 hours'
         AND coalesce(e.state, 'shown') <> 'ignored'
         AND coalesce(g.name,'')       !~* 'parking'
         AND coalesce(g.venue_name,'')  !~* 'parking'
         AND coalesce(g.performer,'')   !~* 'parking'
         AND (ps.quarantined_until IS NULL OR ps.quarantined_until < now())
         AND (ps.cold_until       IS NULL OR ps.cold_until       < now())
    ),
    due AS (
      SELECT ev.gt_event_id, ev.tevo_event_id, ev.last_polled_listings_at,
             CASE WHEN ev.last_polled_listings_at IS NULL THEN 1e9
                  ELSE (EXTRACT(epoch FROM (now() - ev.last_polled_listings_at))/60.0)
                       / NULLIF(c.required_min, 0) END AS overdue_ratio
        FROM ev
        -- 'GT', not 'EVO': the GT collector_cadence rows are live config now.
        JOIN LATERAL public.collector_band('GT','listings', ev.hte) c ON true
       WHERE ev.last_polled_listings_at IS NULL
          OR ev.last_polled_listings_at < now() - make_interval(mins => c.required_min)
    ),
    near AS (
      SELECT gt_event_id, tevo_event_id FROM due ORDER BY overdue_ratio DESC LIMIT v_near
    ),
    tail AS (
      SELECT gt_event_id, tevo_event_id FROM due
       WHERE gt_event_id NOT IN (SELECT gt_event_id FROM near)
       ORDER BY last_polled_listings_at ASC NULLS FIRST
       LIMIT GREATEST(0, p_max - (SELECT count(*) FROM near))
    )
    SELECT gt_event_id, tevo_event_id FROM near
    UNION ALL
    SELECT gt_event_id, tevo_event_id FROM tail
  LOOP
    -- Loop-level wall clock. A per-iteration SET LOCAL statement_timeout is a
    -- no-op on the running statement (PROJECT_BIBLE §3), so the budget has to
    -- be checked here. Unfired events stay due and are picked up next tick.
    EXIT WHEN clock_timestamp() - v_start > make_interval(secs => p_budget_seconds);

    SELECT net.http_get(
      url := 'https://gotickets.com/rest/pro/api/events/' || r.gt_event_id::text || '/listings',
      headers := jsonb_build_object('X-Broker-Api-Token', v_token, 'Accept','application/json'),
      timeout_milliseconds := 30000
    ) INTO v_req;
    INSERT INTO public.gt_listings_inflight(request_id, gt_event_id, tevo_event_id, fired_at)
      VALUES (v_req, r.gt_event_id, r.tevo_event_id, now());
    INSERT INTO public.gt_listings_poll_state(gt_event_id, last_polled_listings_at, listings_polls_today, budget_day)
      VALUES (r.gt_event_id, now(), 1, current_date)
      ON CONFLICT (gt_event_id) DO UPDATE SET
        last_polled_listings_at = now(),
        listings_polls_today = CASE WHEN gt_listings_poll_state.budget_day < current_date
                                    THEN 1 ELSE gt_listings_poll_state.listings_polls_today + 1 END,
        budget_day = current_date;
    v_n := v_n + 1;
  END LOOP;
  RETURN v_n;
END
$fn$;

COMMENT ON FUNCTION public.gt_listings_poll_tick(integer, integer)
  IS 'Per-event GoTickets listings poll. Reads the GT collector_cadence rows '
     '(was hardcoded to EVO''s, making the GT rows dead config) and carries a '
     'loop-level wall-clock budget so it cannot outrun its own schedule.';

-- ---------------------------------------------------------------------------
-- 2. GT cadence — its own bands, sized for its own catalogue
--
-- Inflow arithmetic on the current 4,221-event pollable set:
--   band      events   old (EVO)  ->  new     polls/day old -> new
--   ≤3d           86     5m           10m        24,768 ->  12,384
--   4–7d          41    15m           30m         3,936 ->   1,968
--   8–14d        151    30m/60m       60m/180m    5,436 ->   2,718
--   15–30d       394    60m          180m         9,456 ->   3,152
--   31–60d       679   240m          480m         4,074 ->   2,037
--   61d+       2,870   720m         1440m         5,740 ->   2,870
--                                       total    53,410 ->  25,129
-- ~2.6M snapshot rows/day, comfortably under what retention_tick clears.
-- The sub finder is unaffected: N2S cover pulls go through
-- n2s_pull_events() on demand, not through this background cadence.
-- ---------------------------------------------------------------------------
UPDATE public.collector_cadence SET
  peak_interval_min = v.peak, offpeak_interval_min = v.offpeak, updated_at = now(),
  notes = 'GT catalogue cadence (20260911233000). Was inert while '
          'gt_listings_poll_tick hardcoded collector_band(''EVO'',...).'
FROM (VALUES
  ('le3d',    10,   10),
  ('le7d',    30,   30),
  ('d8_14',   60,  180),
  ('d15_30', 180,  180),
  ('d31_60', 480,  480),
  ('d61p',  1440, 1440),
  ('d181p', 2880, 2880)
) AS v(band, peak, offpeak)
WHERE collector_cadence.source = 'GT'
  AND collector_cadence.scope  = 'listings'
  AND collector_cadence.band   = v.band;

-- ---------------------------------------------------------------------------
-- 3. Deadlock: serialise the deals scan behind the ingest drain
--
-- Body is unchanged from the existing job (12-minute window, all_in_price > 0);
-- the only additions are the shared advisory lock and a statement timeout.
-- ---------------------------------------------------------------------------
SELECT cron.unschedule('gt_deals_scan_odd_min')
 WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'gt_deals_scan_odd_min');

SELECT cron.schedule(
  'gt_deals_scan_odd_min',
  '1-59/2 * * * *',
  $cron$
  SET statement_timeout='100s';
  DO $guard$ BEGIN
    -- Same lock gt_ingest_drain_1min holds. Both write gt_listings_poll_state;
    -- without this they deadlock every other minute.
    IF NOT public.cron_try_lock('gt_listings_drain') THEN RETURN; END IF;
    UPDATE public.gt_listings_poll_state ps SET event_median_price = m.med
      FROM (SELECT gt_event_id, percentile_cont(0.5) WITHIN GROUP (ORDER BY all_in_price)::numeric AS med
            FROM public.gotickets_listings_snapshots
            WHERE captured_at > now()-interval '12 min' AND all_in_price > 0 GROUP BY gt_event_id) m
     WHERE ps.gt_event_id = m.gt_event_id;
  END $guard$;
  $cron$);

-- ---------------------------------------------------------------------------
-- 4. Cap the jobs that overrun their own period
--
-- Bodies unchanged apart from the statement timeout and, for the poll tick,
-- passing the new wall-clock budget.
-- ---------------------------------------------------------------------------
SELECT cron.unschedule('gt_listings_poll_2min')
 WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'gt_listings_poll_2min');

SELECT cron.schedule(
  'gt_listings_poll_2min',
  '*/2 * * * *',
  $cron$
 SET statement_timeout='110s';
 DO $guard$ BEGIN IF NOT public.cron_try_lock('gt_listings_poll_tick') THEN RETURN; END IF; PERFORM public.gt_listings_poll_tick(300, 75); END $guard$;
 $cron$);

SELECT cron.unschedule('gt_ingest_drain_1min')
 WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'gt_ingest_drain_1min');

SELECT cron.schedule(
  'gt_ingest_drain_1min',
  '* * * * *',
  $cron$
SET statement_timeout='55s';
DO $guard$ BEGIN
  IF NOT public.cron_try_lock('gt_listings_drain') THEN RETURN; END IF;
  PERFORM public.gt_listings_drain(3000);
  BEGIN
    PERFORM public.gt_deals_retire_tick();
  EXCEPTION WHEN OTHERS THEN RAISE WARNING 'gt retire skipped: %', SQLERRM;
  END;
END $guard$;
$cron$);

-- deal_scan_tick_1min was added today on a 1-minute schedule and has been
-- averaging 53s per run — it never releases its slot. The deal feed is not
-- timer-bound the way the sub finder is, so 5 minutes is ample. The job gates
-- on cron_try_lock, not cron_should_fire, so the cadence lives in the schedule
-- itself; the cron_policy row is renamed alongside it to stay discoverable.
SELECT cron.unschedule('deal_scan_tick_1min')
 WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'deal_scan_tick_1min');

SELECT cron.schedule(
  'deal_scan_tick_5min',
  '1-59/5 * * * *',
  $cron$
    SET statement_timeout='120s';
    DO $b$ BEGIN
      IF NOT public.cron_try_lock('deal_scan_tick') THEN RETURN; END IF;
      BEGIN PERFORM public.scan_listing_deals('gotickets', 25); EXCEPTION WHEN OTHERS THEN RAISE WARNING 'gt deal scan skipped: %', SQLERRM; END;
      BEGIN PERFORM public.scan_listing_deals('evo', 25);       EXCEPTION WHEN OTHERS THEN RAISE WARNING 'evo deal scan skipped: %', SQLERRM; END;
    END $b$;
  $cron$);

UPDATE public.cron_policy
   SET jobname = 'deal_scan_tick_5min',
       peak_min_interval_min    = 5,
       offpeak_min_interval_min = 15,
       notes = coalesce(notes,'') ||
               ' [20260911233000: renamed from deal_scan_tick_1min, 1min->5min; '
               '53s avg runtime on a 1-minute schedule held a cron slot continuously.]',
       updated_at = now()
 WHERE jobname = 'deal_scan_tick_1min';
