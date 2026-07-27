-- Migration 20260519120000 · lane:A1 · writes:sg_priority_poll_tick + cron schedules · pre:20260519110000 · auth:operator-approved 2026-05-19
--
-- A1 — move 3 every-minute SG priority crons to 5-min cadence + add
-- pg_sleep stagger inside sg_priority_poll_tick.
--
-- Closes the flag in the previous session's audit: sg_priority_poll_tick
-- was the only SG http_get path without PR #212's 0.9s stagger, contributing
-- to potential 429 collisions.
--
-- Why move 1-min → 5-min:
--   1. Operator preference for safety / lower pg_cron load
--   2. Inflow rate (365 listings/hr, 361 sales/hr) easily drained by
--      process(p_limit=100) at 5-min cadence: 100/5min = 1200/hr capacity
--      vs 365/hr inflow = 3.3× headroom
--   3. Tier policy impact:
--        HOT      interval_seconds=240 (4min) — now effectively 5min (20% slower)
--        WARM     300 (5min)             — exact match, no change
--        COOL+    1800+ (30min+)          — unchanged (policy >> cron cadence)
--      Only HOT degrades slightly; acceptable trade for safer pipeline.
--
-- Why add pg_sleep(0.9) to sg_priority_poll_tick:
--   PR #212 fixed thundering-herd on sg_broker_{listings,sales}_queue but
--   sg_priority_poll_tick was missed — it also fires up to 25 sales + 25
--   listings net.http_get per tick. At 5-min cadence with stagger, it
--   contributes ~0.17 req/sec on average — comfortably under SG's
--   ~1.25 req/sec quota.
--
-- Cron staggering (different minute offsets to avoid pg_cron tick collision):
--   sg_priority_poll_tick_5min        */5 * * * *   (0, 5, 10, 15, …)
--   sg_priority_listings_process_5min 1-59/5 * * * * (1, 6, 11, 16, …)
--   sg_priority_sales_process_5min    2-59/5 * * * * (2, 7, 12, 17, …)
-- Each fires within seconds, so 1-min offsets between them is plenty.

-- ============================================================
-- Part 1: sg_priority_poll_tick — add 0.9s pg_sleep stagger after each net.http_get
-- ============================================================
CREATE OR REPLACE FUNCTION public.sg_priority_poll_tick(p_max_polls integer DEFAULT 50)
 RETURNS TABLE(rpt_tier text, rpt_scope text, rpt_events_polled integer)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
DECLARE
  r RECORD;
  v_req bigint;
  v_now timestamptz := clock_timestamp();
  v_token text := public.get_app_secret('SEATGEEK_API_TOKEN');
  v_polled_sales jsonb := '{}'::jsonb;
  v_polled_listings jsonb := '{}'::jsonb;
  v_sales_budget int := p_max_polls / 2;
  v_listings_budget int := p_max_polls - (p_max_polls / 2);
  v_tier_name text;
BEGIN
  IF v_token IS NULL OR v_token = '' THEN
    RAISE NOTICE 'sg_priority_poll_tick: SEATGEEK_API_TOKEN missing';
    RETURN;
  END IF;

  FOR r IN
    SELECT s.sg_event_id, s.tier, s.sales_polls_today, p.interval_seconds, p.daily_polls_per_event
    FROM public.sg_event_priority_state s
    JOIN public.sg_priority_policy p ON p.tier = s.tier AND p.enabled = true
    WHERE p.tier <> 'SKIP'
      AND s.sg_datetime_utc > v_now - interval '2 hours'
      AND (s.last_polled_sales_at IS NULL
           OR v_now - s.last_polled_sales_at >= make_interval(secs => p.interval_seconds))
      AND (p.daily_polls_per_event IS NULL OR s.sales_polls_today < p.daily_polls_per_event)
    ORDER BY p.sort_order, s.sg_datetime_utc
    LIMIT v_sales_budget
  LOOP
    SELECT net.http_get(
      url := 'https://brokerdata.seatgeek.com/sales?token=' || v_token || '&event_id=' || r.sg_event_id::text,
      timeout_milliseconds := 30000
    ) INTO v_req;
    INSERT INTO public.sg_broker_pending(sg_event_id, scope, request_id, fired_at)
      VALUES (r.sg_event_id, 'sales', v_req, v_now);
    UPDATE public.sg_event_priority_state
      SET last_polled_sales_at = v_now, sales_polls_today = sales_polls_today + 1
      WHERE sg_event_id = r.sg_event_id;
    v_polled_sales := v_polled_sales || jsonb_build_object(r.tier, coalesce((v_polled_sales->>r.tier)::int, 0) + 1);
    -- A1 2026-05-19: 0.9s pg_sleep stagger — same rationale as PR #212's queue fns.
    -- SG quota = 10/8s ≈ 1.25 req/sec. 0.9s gives ~1.1 req/sec contribution from poll_tick.
    PERFORM pg_sleep(0.9);
  END LOOP;

  FOR r IN
    SELECT s.sg_event_id, s.tier, s.listings_polls_today, p.interval_seconds, p.daily_polls_per_event
    FROM public.sg_event_priority_state s
    JOIN public.sg_priority_policy p ON p.tier = s.tier AND p.enabled = true
    WHERE p.tier <> 'SKIP'
      AND s.sg_datetime_utc > v_now - interval '2 hours'
      AND (s.last_polled_listings_at IS NULL
           OR v_now - s.last_polled_listings_at >= make_interval(secs => p.interval_seconds))
      AND (p.daily_polls_per_event IS NULL OR s.listings_polls_today < p.daily_polls_per_event)
    ORDER BY p.sort_order, s.sg_datetime_utc
    LIMIT v_listings_budget
  LOOP
    SELECT net.http_get(
      url := 'https://brokerdata.seatgeek.com/listings?token=' || v_token || '&event_id=' || r.sg_event_id::text,
      timeout_milliseconds := 30000
    ) INTO v_req;
    INSERT INTO public.sg_broker_pending(sg_event_id, scope, request_id, fired_at)
      VALUES (r.sg_event_id, 'listings', v_req, v_now);
    UPDATE public.sg_event_priority_state
      SET last_polled_listings_at = v_now, listings_polls_today = listings_polls_today + 1
      WHERE sg_event_id = r.sg_event_id;
    v_polled_listings := v_polled_listings || jsonb_build_object(r.tier, coalesce((v_polled_listings->>r.tier)::int, 0) + 1);
    -- A1 2026-05-19: 0.9s pg_sleep stagger
    PERFORM pg_sleep(0.9);
  END LOOP;

  FOR v_tier_name IN SELECT pp.tier FROM public.sg_priority_policy pp WHERE pp.enabled = true AND pp.tier <> 'SKIP'
  LOOP
    rpt_tier := v_tier_name;
    rpt_scope := 'sales';
    rpt_events_polled := coalesce((v_polled_sales->>v_tier_name)::int, 0);
    RETURN NEXT;
    rpt_scope := 'listings';
    rpt_events_polled := coalesce((v_polled_listings->>v_tier_name)::int, 0);
    RETURN NEXT;
  END LOOP;
END $function$;

COMMENT ON FUNCTION public.sg_priority_poll_tick(integer) IS
  'Priority-tier SG broker poller. A1 2026-05-19: added 0.9s pg_sleep stagger per HTTP GET (mirrors PR #212 queue fns) — keeps poll_tick contribution under SG 10/8s quota even on busy 5-min ticks.';

-- ============================================================
-- Part 2: Reschedule 3 every-minute crons → 5-min cadence + rename
-- ============================================================
DO $body$
DECLARE v_jobid bigint;
BEGIN
  FOR v_jobid IN SELECT jobid FROM cron.job
                 WHERE jobname IN ('sg_priority_poll_tick_1min',
                                   'sg_priority_listings_process_1min',
                                   'sg_priority_sales_process_1min')
  LOOP
    PERFORM cron.unschedule(v_jobid);
  END LOOP;

  PERFORM cron.schedule(
    'sg_priority_poll_tick_5min',
    '*/5 * * * *',
    $cron$DO $cronbody$
    BEGIN
      IF NOT public.cron_should_fire('sg_priority_poll_tick_5min') THEN RETURN; END IF;
      PERFORM * FROM public.sg_priority_poll_tick(50);
    END $cronbody$;$cron$
  );

  PERFORM cron.schedule(
    'sg_priority_listings_process_5min',
    '1-59/5 * * * *',
    $cron$DO $cronbody$
    BEGIN
      IF NOT public.cron_should_fire('sg_priority_listings_process_5min') THEN RETURN; END IF;
      -- p_limit=100: 5-min inflow ~30, queue-burst can add 50 at once. 100 = safe margin.
      PERFORM public.sg_broker_listings_process(100);
    END $cronbody$;$cron$
  );

  PERFORM cron.schedule(
    'sg_priority_sales_process_5min',
    '2-59/5 * * * *',
    $cron$DO $cronbody$
    BEGIN
      IF NOT public.cron_should_fire('sg_priority_sales_process_5min') THEN RETURN; END IF;
      PERFORM public.sg_broker_sales_process(100);
    END $cronbody$;$cron$
  );
END $body$;

-- ============================================================
-- Part 3: Update cron_policy entries
-- ============================================================
DELETE FROM public.cron_policy
WHERE jobname IN ('sg_priority_poll_tick_1min',
                  'sg_priority_listings_process_1min',
                  'sg_priority_sales_process_1min');

INSERT INTO public.cron_policy (jobname, peak_hours_et, peak_min_interval_min,
  offpeak_min_interval_min, daily_max_fires, enabled, notes)
VALUES
  ('sg_priority_poll_tick_5min',
   '{9,10,11,12,13,14,15,16,17,18,19,20}'::int[],
   5, 5, 288, true,
   'Priority-tier SG broker poller. Wakes every 5min, fires up to 50 HTTP GETs with 0.9s pg_sleep stagger. Tier policy controls per-event cadence; cron just wakes the driver.'),
  ('sg_priority_listings_process_5min',
   '{9,10,11,12,13,14,15,16,17,18,19,20}'::int[],
   5, 5, 288, true,
   'Drains sg_broker_pending listings responses into seatgeek_listings_snapshots. p_limit=100 per firing covers normal inflow + queue-burst bursts.'),
  ('sg_priority_sales_process_5min',
   '{9,10,11,12,13,14,15,16,17,18,19,20}'::int[],
   5, 5, 288, true,
   '429-aware drain of sg_broker_pending sales responses (post-PR #212). p_limit=100.')
ON CONFLICT (jobname) DO UPDATE SET enabled = true, notes = EXCLUDED.notes, updated_at = now();
