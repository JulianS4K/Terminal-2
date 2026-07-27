-- Migration 20260519140000 · lane:A1 · CRITICAL HOTFIX · pre:20260519130000 · auth:operator-approved 2026-05-19
--
-- A1 — emergency hotfix on the 429 regression.
--
-- ROOT CAUSE DISCOVERED 2026-05-19 02:45 UTC:
--   pg_net.http_get() is ASYNCHRONOUS. The PR #212/#214 pg_sleep(0.9) calls
--   inside the FOR LOOP only delayed the function's RETURN, not the actual
--   HTTP dispatch. pg_net queued all 50 requests immediately when the
--   function called net.http_get(), and dispatched them in a tight burst.
--
--   Evidence: query of net._http_response.created for the 02:34 listings_queue
--   firing showed all 50 rows with IDENTICAL timestamp 02:34:45.137759.
--   Whatever pg_net's dispatch worker does, it doesn't honor function-side
--   pg_sleep gaps.
--
-- SG rate limit (re-confirmed via response headers):
--   ratelimit-limit: 10
--   retry-after: 8s
--   = 10 requests per ~8s rolling window (token bucket).
--
-- FIX: cap burst size to 8 per call (under the 10-token quota). Then the
-- bucket refills before the next cron firing.
--
-- THROUGHPUT MAINTAINED by increasing cron frequency:
--   was: listings_queue @ :04,:34  (50 events × 2/hr = 100/hr)
--   now: listings_queue @ */5     (8 events × 12/hr = 96/hr)
--   same shape for sales_queue (offset 2 min: 2-57/5)
--
-- Per-call burst (8 events) finishes in <1 second (pg_net dispatches
-- concurrently). SG sees 8 requests → token bucket = 10 → 8 OK.
-- 5-min interval >> 8s reset → bucket fully refilled by next firing.
--
-- Priority poll_tick: cap at 6 per firing (3 sales + 3 listings).
--
-- Remove broken pg_sleep(0.9) calls (no-op given pg_net is async).
--
-- Combined sustained rate: (96 listings + 96 sales + 72 poll_tick) / 3600s
--   = 0.73 req/sec  <<  1.25 req/sec quota.

-- ============================================================
-- 1. sg_broker_listings_queue — default 50 → 8, drop pg_sleep
-- ============================================================
CREATE OR REPLACE FUNCTION public.sg_broker_listings_queue(p_max_events integer DEFAULT 8)
 RETURNS integer
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_token   text := get_app_secret('SEATGEEK_API_TOKEN');
  r         RECORD;
  v_req_id  bigint;
  v_count   int := 0;
BEGIN
  IF v_token IS NULL OR v_token = '' THEN RETURN 0; END IF;
  FOR r IN
    SELECT sg_event_id FROM public.sg_events_canonical
    WHERE sg_event_date >= current_date
    ORDER BY sg_event_date LIMIT p_max_events
  LOOP
    SELECT net.http_get(
      url := 'https://brokerdata.seatgeek.com/listings?token=' || v_token || '&event_id=' || r.sg_event_id::text,
      timeout_milliseconds := 30000
    ) INTO v_req_id;
    INSERT INTO public.sg_broker_pending(request_id, scope, sg_event_id) VALUES (v_req_id, 'listings', r.sg_event_id);
    v_count := v_count + 1;
    -- A1 2026-05-19: REMOVED pg_sleep(0.9) — pg_net is async, sleep doesn't
    -- pace HTTP dispatch. Burst-size cap (default 8) is the real rate limiter.
  END LOOP;
  RETURN v_count;
END $function$;

COMMENT ON FUNCTION public.sg_broker_listings_queue(integer) IS
  'A1 2026-05-19 burst-fix: default 8 events/call (under SG 10-req quota). pg_net async = pg_sleep ineffective. 5-min cron schedule maintains throughput.';

-- ============================================================
-- 2. sg_broker_sales_queue — same shape
-- ============================================================
CREATE OR REPLACE FUNCTION public.sg_broker_sales_queue(p_max_events integer DEFAULT 8)
 RETURNS integer
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_token   text := get_app_secret('SEATGEEK_API_TOKEN');
  r         RECORD;
  v_req_id  bigint;
  v_count   int := 0;
BEGIN
  IF v_token IS NULL OR v_token = '' THEN RETURN 0; END IF;
  FOR r IN
    WITH events_with_activity AS (
      SELECT DISTINCT aq.sg_event_id, 1 AS priority
      FROM public.evo_order_items i
      JOIN public.aq_event_map aq ON aq.aq_short_event_id = i.aq_short_event_id
      WHERE aq.sg_event_id IS NOT NULL AND i.occurs_at >= now()
      UNION
      SELECT DISTINCT aq.sg_event_id, 2
      FROM (SELECT aq_short_event_id FROM public.tickpick_orders WHERE aq_short_event_id IS NOT NULL
            UNION
            SELECT aq_short_event_id FROM public.vivid_orders    WHERE aq_short_event_id IS NOT NULL) cross_src
      JOIN public.aq_event_map aq ON aq.aq_short_event_id = cross_src.aq_short_event_id
      WHERE aq.sg_event_id IS NOT NULL
    )
    SELECT sgc.sg_event_id, COALESCE(ew.priority, 3) AS priority
    FROM public.sg_events_canonical sgc
    LEFT JOIN events_with_activity ew ON ew.sg_event_id = sgc.sg_event_id
    WHERE sgc.sg_event_date >= current_date
      AND NOT EXISTS (
        SELECT 1 FROM public.sg_broker_pending p
        WHERE p.sg_event_id = sgc.sg_event_id
          AND p.scope = 'sales'
          AND p.resolved_at IS NULL
      )
    ORDER BY priority, sgc.sg_event_date
    LIMIT p_max_events
  LOOP
    SELECT net.http_get(
      url := 'https://brokerdata.seatgeek.com/sales?token=' || v_token || '&event_id=' || r.sg_event_id::text,
      timeout_milliseconds := 30000
    ) INTO v_req_id;
    INSERT INTO public.sg_broker_pending(request_id, scope, sg_event_id) VALUES (v_req_id, 'sales', r.sg_event_id);
    v_count := v_count + 1;
    -- A1 2026-05-19: REMOVED pg_sleep(0.9) (no-op given pg_net async)
  END LOOP;
  RETURN v_count;
END $function$;

COMMENT ON FUNCTION public.sg_broker_sales_queue(integer) IS
  'A1 2026-05-19 burst-fix: default 8 events/call. Same rationale as sg_broker_listings_queue.';

-- ============================================================
-- 3. sg_priority_poll_tick — default 50 → 6, drop pg_sleep
-- ============================================================
CREATE OR REPLACE FUNCTION public.sg_priority_poll_tick(p_max_polls integer DEFAULT 6)
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
    -- A1 2026-05-19: REMOVED pg_sleep(0.9) (no-op given pg_net async)
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
  'A1 2026-05-19 burst-fix: default 6 polls/call (3 sales + 3 listings). pg_net async = pg_sleep removed.';

-- ============================================================
-- 4. Reschedule crons for higher frequency × smaller burst
-- ============================================================
DO $body$ DECLARE v_jobid bigint;
BEGIN
  -- Listings queue: was :04,:34 (2/hr), now every 5 min @ :00,:05,...,:55
  SELECT jobid INTO v_jobid FROM cron.job WHERE jobname = 'sg_broker_listings_queue_30min';
  IF v_jobid IS NOT NULL THEN PERFORM cron.unschedule(v_jobid); END IF;
  PERFORM cron.schedule(
    'sg_broker_listings_queue_5min',
    '*/5 * * * *',
    $cron$DO $cronbody$
    BEGIN
      IF NOT public.cron_should_fire('sg_broker_listings_queue_5min') THEN RETURN; END IF;
      PERFORM public.sg_broker_listings_queue(8);
    END $cronbody$;$cron$
  );

  -- Sales queue: was :09,:39, now every 5 min @ :02,:07,...,:57 (offset to avoid simultaneity)
  SELECT jobid INTO v_jobid FROM cron.job WHERE jobname = 'sg_broker_sales_queue_30min';
  IF v_jobid IS NOT NULL THEN PERFORM cron.unschedule(v_jobid); END IF;
  PERFORM cron.schedule(
    'sg_broker_sales_queue_5min',
    '2-57/5 * * * *',
    $cron$DO $cronbody$
    BEGIN
      IF NOT public.cron_should_fire('sg_broker_sales_queue_5min') THEN RETURN; END IF;
      PERFORM public.sg_broker_sales_queue(8);
    END $cronbody$;$cron$
  );

  -- poll_tick: stays @ */5 but smaller burst (6 events)
  SELECT jobid INTO v_jobid FROM cron.job WHERE jobname = 'sg_priority_poll_tick_5min';
  IF v_jobid IS NOT NULL THEN PERFORM cron.unschedule(v_jobid); END IF;
  PERFORM cron.schedule(
    'sg_priority_poll_tick_5min',
    '4-59/5 * * * *',
    $cron$DO $cronbody$
    BEGIN
      IF NOT public.cron_should_fire('sg_priority_poll_tick_5min') THEN RETURN; END IF;
      PERFORM * FROM public.sg_priority_poll_tick(6);
    END $cronbody$;$cron$
  );
END $body$;

-- Update cron_policy: 5-min interval for the new fast queues, 96 fires/day max
INSERT INTO public.cron_policy (jobname, peak_hours_et, peak_min_interval_min,
  offpeak_min_interval_min, daily_max_fires, enabled, notes)
VALUES
  ('sg_broker_listings_queue_5min',
   '{9,10,11,12,13,14,15,16,17,18,19,20}'::int[],
   5, 5, 288, true,
   'A1 2026-05-19 hotfix: 8 events/firing × 5-min cadence = 96/hr (was 100/hr at 50×2). Under SG quota.'),
  ('sg_broker_sales_queue_5min',
   '{9,10,11,12,13,14,15,16,17,18,19,20}'::int[],
   5, 5, 288, true,
   'A1 2026-05-19 hotfix: 8 events/firing × 5-min cadence × offset minute = 96/hr. Avoids overlap with listings queue.')
ON CONFLICT (jobname) DO UPDATE SET enabled=true, notes=EXCLUDED.notes, updated_at=now();

DELETE FROM public.cron_policy
WHERE jobname IN ('sg_broker_listings_queue_30min','sg_broker_sales_queue_30min');
