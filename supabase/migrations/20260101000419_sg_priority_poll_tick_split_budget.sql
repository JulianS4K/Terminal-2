-- Migration 20260516000000 · admin · fix sg_priority_poll_tick listings starvation · pre:20260515390000
-- Discovered via diagnostic on Yankees@Mets 5/16 event: HOT tier promises 60s listings polls,
-- but actual last_polled_listings was 23 hours ago. Sales side polled fine.
--
-- ROOT CAUSE: sequential loops in the function — sales runs FIRST with the full p_max_polls
-- budget, listings only runs IF v_remaining > 0. With ~50 HOT events × 60s sales polls due
-- each tick, sales consumes all 50 per tick → listings starves.
--
-- FIX: split the budget evenly between sales and listings. Each scope gets p_max_polls / 2.
-- Tradeoff: each event polled every 2 min instead of 1 min on HOT tier. To restore 60s
-- coverage on both scopes, operator can bump cron command to p_max_polls=100.
--
-- Function signature unchanged (p_max_polls int DEFAULT 50). RETURNS TABLE shape unchanged.

CREATE OR REPLACE FUNCTION public.sg_priority_poll_tick(p_max_polls integer DEFAULT 50)
RETURNS TABLE(rpt_tier text, rpt_scope text, rpt_events_polled integer)
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = public, extensions, pg_temp
AS $func$
DECLARE
  r RECORD;
  v_req bigint;
  v_now timestamptz := clock_timestamp();
  v_token text := public.get_app_secret('SEATGEEK_API_TOKEN');
  v_polled_sales jsonb := '{}'::jsonb;
  v_polled_listings jsonb := '{}'::jsonb;
  -- Split budget evenly. p_max_polls=50 → 25 sales + 25 listings per tick.
  v_sales_budget int := p_max_polls / 2;
  v_listings_budget int := p_max_polls - (p_max_polls / 2);
  v_tier_name text;
BEGIN
  IF v_token IS NULL OR v_token = '' THEN
    RAISE NOTICE 'sg_priority_poll_tick: SEATGEEK_API_TOKEN missing';
    RETURN;
  END IF;

  -- SALES loop (independent budget v_sales_budget)
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
  END LOOP;

  -- LISTINGS loop (independent budget v_listings_budget — no longer starved by sales)
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
END $func$;
