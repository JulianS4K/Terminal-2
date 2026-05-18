-- Migration 20260520330000 · lane:A1 · writes:sg_sales_poll_tick,sg_priority_poll_tick,cron · pre:20260520310000
--
-- SG sales polling rewire (operator design 2026-05-18)
--
-- New global cadence for ALL events' sales polling (REPLACES existing
-- HOT/WARM/COOL/COLD/WATCH/OBSERVE sales-side cadence):
--
--   hours_to_event in [168, 1440]   (7-60 days)        every 6h    4 polls/day
--   hours_to_event in [24, 168)     (1-7 days)         every 4h    6 polls/day
--   hours_to_event in [0, 24)       (last day)         every 2h   12 polls/day
--   post-event window [2h, 24h]     (after start)      one-time   1 poll
--   outside any window                                              skipped
--
-- TRADE-OFF (operator accepted): owned events near gameday lose tick-rate
-- signal. Existing HOT polled sales every 4 min (360/day); new cadence is
-- 12/day in last 24h. ~97% reduction in tick rate for owned events on game
-- day, in exchange for broader-coverage tracking across the unmatched pool.
--
-- Two functions touched:
--   1. NEW: sg_sales_poll_tick(p_max int default 50)
--      — Reads sg_event_priority_state, applies the new cadence rules,
--        fires SG /sales GETs, inserts pending rows.
--      — Eligibility CTE buckets events by required cadence; LOOP picks
--        the most-overdue first.
--   2. CREATE OR REPLACE sg_priority_poll_tick: removes the sales loop
--      entirely. Listings loop unchanged. Return shape preserved (sales
--      rows in the report just report 0 events_polled).
--
-- Plus cron + cron_policy row for the new sales tick at every 5 min, 24/7
-- (the per-event interval rule handles cadence, not the cron schedule).
--
-- THROUGHPUT MATH
--   Assume distribution of priority_state events (≈4,000 non-SKIP):
--     - 0-24h (12 polls/day):     ~50 events  →   600 polls/day
--     - 1-7d  (6 polls/day):     ~250 events  → 1,500 polls/day
--     - 7-60d (4 polls/day):   ~3,500 events  → 14,000 polls/day
--     - Post-event (1 once):     ~30 events   →    30 polls/day
--   Total ≈ 16,130 polls/day = 0.187 req/s. SG quota 1.25 req/s. ~15%.
--   Cron at */5 24/7 = 288 fires/day. With p_max=60 = 17,280 capacity.
--
-- VERIFICATION (after apply, before cron's first natural fire)
--   1) Function callable + dry-run safe:
--      SELECT public.sg_sales_poll_tick(0);   -- expect 0
--
--   2) Eligibility check (no SG hit, just count):
--      WITH e AS (...)  -- inline the eligibility CTE
--      SELECT bucket, count(*) FROM e GROUP BY bucket;
--      -- expect rows in d1, d2_6, d7_60, post_event buckets
--
--   3) Smoke fire (8 events):
--      SELECT public.sg_sales_poll_tick(8);
--      SELECT count(*) FROM sg_broker_pending
--      WHERE scope='sales' AND fired_at > now() - interval '2 min';
--      -- expect 8 new rows
--
--   4) Confirm sg_priority_poll_tick no longer fires sales:
--      SELECT * FROM public.sg_priority_poll_tick(6);
--      -- expect all 'sales' rows to be 0; listings rows unchanged
--
--   5) Drain pending + verify sales rows landed:
--      SELECT public.sg_broker_sales_process(50);
--      SELECT scope, count(*) FROM sg_broker_pending
--      WHERE fired_at > now() - interval '5 min' GROUP BY scope;

-- ============================================================
-- 1. sg_sales_poll_tick — the new global sales polling driver
-- ============================================================
CREATE OR REPLACE FUNCTION public.sg_sales_poll_tick(p_max int DEFAULT 50)
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
    RAISE EXCEPTION 'sg_sales_poll_tick: caller % not authorized', current_user;
  END IF;

  IF v_token IS NULL OR v_token = '' THEN
    RAISE NOTICE 'sg_sales_poll_tick: SEATGEEK_API_TOKEN missing';
    RETURN 0;
  END IF;

  IF p_max <= 0 THEN
    RETURN 0;
  END IF;

  FOR r IN
    WITH eligible AS (
      SELECT s.sg_event_id, s.sg_datetime_utc, s.last_polled_sales_at,
        CASE
          -- Post-event one-shot: in [event_at + 2h, event_at + 24h] AND
          -- last_polled_sales_at < event_at (we haven't polled post-event yet)
          WHEN s.sg_datetime_utc < v_now - interval '2 hours'
               AND s.sg_datetime_utc > v_now - interval '24 hours'
               AND (s.last_polled_sales_at IS NULL
                    OR s.last_polled_sales_at < s.sg_datetime_utc) THEN 'post_event'
          -- Last 24h: every 2h
          WHEN s.sg_datetime_utc BETWEEN v_now
                                    AND v_now + interval '24 hours' THEN 'd1'
          -- 1-7 days out: every 4h
          WHEN s.sg_datetime_utc > v_now + interval '24 hours'
               AND s.sg_datetime_utc <= v_now + interval '168 hours' THEN 'd2_6'
          -- 7-60 days out: every 6h
          WHEN s.sg_datetime_utc > v_now + interval '168 hours'
               AND s.sg_datetime_utc <= v_now + interval '1440 hours' THEN 'd7_60'
          ELSE NULL
        END AS bucket,
        CASE
          WHEN s.sg_datetime_utc < v_now - interval '2 hours'
               AND s.sg_datetime_utc > v_now - interval '24 hours'
               AND (s.last_polled_sales_at IS NULL
                    OR s.last_polled_sales_at < s.sg_datetime_utc) THEN interval '0'
          WHEN s.sg_datetime_utc BETWEEN v_now
                                    AND v_now + interval '24 hours' THEN interval '2 hours'
          WHEN s.sg_datetime_utc > v_now + interval '24 hours'
               AND s.sg_datetime_utc <= v_now + interval '168 hours' THEN interval '4 hours'
          WHEN s.sg_datetime_utc > v_now + interval '168 hours'
               AND s.sg_datetime_utc <= v_now + interval '1440 hours' THEN interval '6 hours'
          ELSE NULL
        END AS required_interval
      FROM public.sg_event_priority_state s
      WHERE s.sg_datetime_utc > v_now - interval '24 hours'
        AND s.sg_datetime_utc <= v_now + interval '1440 hours'
    )
    SELECT sg_event_id, bucket
    FROM eligible
    WHERE bucket IS NOT NULL
      AND (last_polled_sales_at IS NULL
           OR v_now - last_polled_sales_at >= required_interval)
    -- post_event first (one-shot, time-sensitive), then most-overdue, then by id
    ORDER BY
      CASE bucket WHEN 'post_event' THEN 0 WHEN 'd1' THEN 1 WHEN 'd2_6' THEN 2 ELSE 3 END,
      last_polled_sales_at NULLS FIRST,
      sg_event_id
    LIMIT p_max
  LOOP
    SELECT net.http_get(
      url := 'https://brokerdata.seatgeek.com/sales?token=' || v_token
             || '&event_id=' || r.sg_event_id::text,
      timeout_milliseconds := 30000
    ) INTO v_req;

    INSERT INTO public.sg_broker_pending(sg_event_id, scope, request_id, fired_at)
    VALUES (r.sg_event_id, 'sales', v_req, v_now);

    UPDATE public.sg_event_priority_state
       SET last_polled_sales_at = v_now,
           sales_polls_today    = sales_polls_today + 1
     WHERE sg_event_id = r.sg_event_id;

    v_polled := v_polled + 1;
  END LOOP;

  RETURN v_polled;
END
$func$;

REVOKE EXECUTE ON FUNCTION public.sg_sales_poll_tick(int) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.sg_sales_poll_tick(int) FROM anon;
REVOKE EXECUTE ON FUNCTION public.sg_sales_poll_tick(int) FROM authenticated;
GRANT  EXECUTE ON FUNCTION public.sg_sales_poll_tick(int) TO service_role;


-- ============================================================
-- 2. CREATE OR REPLACE sg_priority_poll_tick — drop sales loop
-- ============================================================
-- Signature + return shape preserved (existing crons keep working). The
-- sales loop is removed entirely; listings loop is byte-identical to the
-- prior body. Reports still emit 'sales' rows but with events_polled=0.
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
  v_polled_listings jsonb := '{}'::jsonb;
  v_tier_name text;
BEGIN
  IF v_token IS NULL OR v_token = '' THEN
    RAISE NOTICE 'sg_priority_poll_tick: SEATGEEK_API_TOKEN missing';
    RETURN;
  END IF;

  -- Listings polling unchanged from prior body. Full p_max_polls budget now
  -- goes to listings since sales is handled by sg_sales_poll_tick.
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
    LIMIT p_max_polls
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

  -- Report rows for backward compat: emit (tier, sales, 0) + (tier, listings, N) per enabled tier
  FOR v_tier_name IN SELECT pp.tier FROM public.sg_priority_policy pp WHERE pp.enabled = true AND pp.tier <> 'SKIP'
  LOOP
    rpt_tier := v_tier_name;
    rpt_scope := 'sales';
    rpt_events_polled := 0;  -- sales handled by sg_sales_poll_tick now
    RETURN NEXT;
    rpt_scope := 'listings';
    rpt_events_polled := coalesce((v_polled_listings->>v_tier_name)::int, 0);
    RETURN NEXT;
  END LOOP;
END $function$;


-- ============================================================
-- 3. cron schedule for the new sales tick
-- ============================================================
SELECT cron.schedule(
  'sg_sales_poll_5min',
  '*/5 * * * *',
  $cron$
  DO $body$
  BEGIN
    IF NOT public.cron_should_fire('sg_sales_poll_5min') THEN
      RETURN;
    END IF;
    PERFORM public.sg_sales_poll_tick(60);
  END $body$;
  $cron$
);


-- ============================================================
-- 4. cron_policy row
-- ============================================================
INSERT INTO public.cron_policy
  (jobname, peak_hours_et, peak_min_interval_min, offpeak_min_interval_min,
   work_check_sql, daily_max_fires, enabled, notes, updated_at)
VALUES
  ('sg_sales_poll_5min',
   ARRAY[]::int[],
   5, 5,
   $$ SELECT EXISTS (
        SELECT 1 FROM public.sg_event_priority_state s
        WHERE s.sg_datetime_utc > now() - interval '24 hours'
          AND s.sg_datetime_utc <= now() + interval '1440 hours'
          AND (s.last_polled_sales_at IS NULL OR s.last_polled_sales_at < s.sg_datetime_utc)
        LIMIT 1
      ) $$,
   300,
   true,
   'Global sales polling (replaces tier-based sales in sg_priority_poll_tick). Cadence: 7-60d every 6h, 1-7d every 4h, 0-24h every 2h, +1 final pull 2h post-event. 288 fires/day × 60 burst = 17,280 capacity vs ≈16K expected daily polls.',
   now())
ON CONFLICT (jobname) DO NOTHING;
