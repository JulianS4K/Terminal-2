-- Migration 20260520310000 · lane:A1 · writes:sg_blindspot_poll_tick,cron · pre:20260520290000
--
-- STEP 2 of 5 — Blindspot polling (listings only, 12h-spread, off-peak + mid-day)
--
-- Goal: poll the 3,154 TRACK_BLINDSPOT events at 2 polls/day with 12h spread,
-- anchored to UTC 04-10 (off-peak ET overnight) + UTC 16-22 (mid-day ET).
-- Listings only — sales has different semantics (point events) and isn't
-- relevant for the price/inventory delta detection in Step 3.
--
-- DESIGN
--   - New function: sg_blindspot_poll_tick(p_max int default 40)
--     - Reads priority_state for tier='TRACK_BLINDSPOT' AND
--       (last_polled_listings_at IS NULL OR < now() - 12 hours)
--     - Fires SG /listings GET via net.http_get for up to p_max events
--     - Inserts sg_broker_pending row + bumps last_polled_listings_at
--     - Mirrors sg_priority_poll_tick's pattern but is scoped to TRACK_BLINDSPOT
--   - New cron 'sg_blindspot_poll_5min':
--     - Schedule: '*/5 4-10,16-22 * * *' (every 5 min during UTC 04-10 + 16-22)
--     - 168 fires/day × 40 events = 6,720/day capacity
--     - Actual: 3,154 events × 2 polls/day = 6,308 polls
--   - cron_policy row with daily_max_fires + work_check_sql skip
--
-- BURST CAP RATIONALE
--   p_max=40 per fire. pg_net is async — the 40 GET requests queue and SG's
--   10/8s token bucket drains them over ~32 seconds. Within 5-min cycle. Other
--   SG-polling crons (sg_priority_*_5min) fire on alternating minute offsets,
--   so concurrent bucket pressure stays under quota. Per PROJECT_BIBLE §7
--   pg_net macro: "burst × firings/hr ≥ inflow_rate" — 40 × 12/hr = 480/hr =
--   0.13 req/s avg, well under 1.25 quota.
--
-- ALTERNATIVE NOT TAKEN
--   We could've extended sg_priority_poll_tick to include TRACK_BLINDSPOT.
--   Reasons against:
--     - TRACK_BLINDSPOT has enabled=false (intentional, per Step 1 — keeps
--       ELSE policy lookup from accidentally tagging non-US events).
--       sg_priority_poll_tick filters on enabled=true.
--     - Separate cron lets us gate by hour (04-10, 16-22) without affecting
--       HOT/WARM/etc. polling.
--     - Cleaner failure isolation if SG /listings starts 429ing on
--       blindspot specifically.
--
-- VERIFICATION QUERIES (operator runs after apply)
--   1) Function exists and is callable:
--      SELECT public.sg_blindspot_poll_tick(0);  -- p_max=0 = dry-run check
--
--   2) Manual smoke fire (p_max=4, hits 4 events):
--      SELECT public.sg_blindspot_poll_tick(4);
--      SELECT count(*) FROM public.sg_broker_pending
--      WHERE scope='listings' AND fired_at > now() - interval '5 minutes';
--      -- expect: 4 new pending rows
--
--   3) Verify the poll request resolved + rows landed:
--      SELECT p.fired_at, p.resolved_at, p.rows_persisted
--      FROM public.sg_broker_pending p
--      WHERE p.scope='listings' AND p.fired_at > now() - interval '10 minutes'
--      ORDER BY p.fired_at DESC LIMIT 10;
--
--   4) After cron fires for the first 04:00-10:00 window, check coverage:
--      SELECT count(*) FILTER (WHERE last_polled_listings_at IS NOT NULL) AS polled,
--             count(*)                                                     AS total
--      FROM public.sg_event_priority_state WHERE tier = 'TRACK_BLINDSPOT';
--      -- expect: polled ≈ total within 6 hours of cron starting

-- ============================================================
-- 1. sg_blindspot_poll_tick function
-- ============================================================
CREATE OR REPLACE FUNCTION public.sg_blindspot_poll_tick(p_max int DEFAULT 40)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'extensions', 'pg_temp'
AS $func$
DECLARE
  r RECORD;
  v_req bigint;
  v_now timestamptz := clock_timestamp();
  v_token text := public.get_app_secret('SEATGEEK_API_TOKEN');
  v_polled int := 0;
BEGIN
  IF current_user NOT IN ('service_role', 'postgres', 'supabase_admin') THEN
    RAISE EXCEPTION 'sg_blindspot_poll_tick: caller % not authorized', current_user;
  END IF;

  IF v_token IS NULL OR v_token = '' THEN
    RAISE NOTICE 'sg_blindspot_poll_tick: SEATGEEK_API_TOKEN missing';
    RETURN 0;
  END IF;

  -- p_max=0 = dry-run / health check
  IF p_max <= 0 THEN
    RETURN 0;
  END IF;

  FOR r IN
    SELECT s.sg_event_id
    FROM public.sg_event_priority_state s
    WHERE s.tier = 'TRACK_BLINDSPOT'
      AND (s.last_polled_listings_at IS NULL
           OR v_now - s.last_polled_listings_at >= interval '12 hours')
    ORDER BY s.last_polled_listings_at NULLS FIRST, s.sg_event_id
    LIMIT p_max
  LOOP
    SELECT net.http_get(
      url := 'https://brokerdata.seatgeek.com/listings?token=' || v_token
             || '&event_id=' || r.sg_event_id::text,
      timeout_milliseconds := 30000
    ) INTO v_req;

    INSERT INTO public.sg_broker_pending(sg_event_id, scope, request_id, fired_at)
    VALUES (r.sg_event_id, 'listings', v_req, v_now);

    UPDATE public.sg_event_priority_state
       SET last_polled_listings_at = v_now,
           listings_polls_today    = listings_polls_today + 1
     WHERE sg_event_id = r.sg_event_id;

    v_polled := v_polled + 1;
  END LOOP;

  RETURN v_polled;
END
$func$;

REVOKE EXECUTE ON FUNCTION public.sg_blindspot_poll_tick(int) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.sg_blindspot_poll_tick(int) FROM anon;
REVOKE EXECUTE ON FUNCTION public.sg_blindspot_poll_tick(int) FROM authenticated;
GRANT  EXECUTE ON FUNCTION public.sg_blindspot_poll_tick(int) TO service_role;


-- ============================================================
-- 2. cron schedule (off-peak + mid-day windows)
-- ============================================================
SELECT cron.schedule(
  'sg_blindspot_poll_5min',
  '*/5 4-10,16-22 * * *',
  $cron$
  DO $body$
  BEGIN
    IF NOT public.cron_should_fire('sg_blindspot_poll_5min') THEN
      RETURN;
    END IF;
    PERFORM public.sg_blindspot_poll_tick(40);
  END $body$;
  $cron$
);


-- ============================================================
-- 3. cron_policy row
-- ============================================================
INSERT INTO public.cron_policy
  (jobname, peak_hours_et, peak_min_interval_min, offpeak_min_interval_min,
   work_check_sql, daily_max_fires, enabled, notes, updated_at)
VALUES
  ('sg_blindspot_poll_5min',
   ARRAY[]::int[],
   5, 5,
   $$ SELECT EXISTS (
        SELECT 1 FROM public.sg_event_priority_state
        WHERE tier = 'TRACK_BLINDSPOT'
          AND (last_polled_listings_at IS NULL
               OR last_polled_listings_at < now() - interval '12 hours')
        LIMIT 1
      ) $$,
   180,
   true,
   'Off-peak (UTC 04-10) + mid-day (UTC 16-22) blindspot polling. 168 fires/day max via schedule, daily_max_fires=180 ceiling. Skip when no eligible events remain.',
   now())
ON CONFLICT (jobname) DO NOTHING;
