-- Migration 20260515260000 · level:admin · lane:Audit/Push · writes:sg_event_priority_state (new), sg_priority_policy (new), sg_classify_events() fn, sg_priority_poll_tick() fn, 4 new crons (paused via cron_pause_state_20260514 insert) · reads:sg_events_canonical, aq_event_map, listings_snapshots, sg_broker_pending · pre:20260515250001
-- Stock-broker-style tiered polling: high-frequency for HOT events (owned + imminent),
-- throttled for far-future / non-owned. Replaces "every-30-min for all events" with
-- per-event tier classification + minute-cadence driver that fires only due polls.
--
-- Operator directive 2026-05-14:
--   "for knicks we want to track sales more often closer to event start time where
--    listings-owned are greater than zero. tie event listing counts in sg and evo to
--    sales crons as well as event time. think stock broker max data refresh rates while
--    managing cpu usage, and environmental concerns."
--
-- Tier definitions:
--   HOT     | owned > 0, <6h to event       | 60s   | 360/event/day
--   WARM    | owned > 0, <24h to event      | 5min  | 96/event/day
--   COOL    | owned > 0, <7d to event       | 30min | 24/event/day
--   COLD    | owned > 0, <30d to event      | 4h    | 6/event/day
--   OBSERVE | upcoming, NOT owned           | 12h   | 2/event/day
--   SKIP    | far future or no signal       | n/a   | 0
--
-- ## Already applied to prod
-- Applied via MCP 2026-05-14. New crons are paused via cron_pause_state_20260514
-- snapshot insert; operator graduates through cron_resume_with_gate() per the gate pattern.

CREATE TABLE IF NOT EXISTS public.sg_priority_policy (
  tier                  text PRIMARY KEY,
  label                 text NOT NULL,
  interval_seconds      int  NOT NULL,
  min_hours_to_event    numeric,
  max_hours_to_event    numeric,
  requires_owned        boolean NOT NULL DEFAULT false,
  daily_polls_per_event int,
  enabled               boolean NOT NULL DEFAULT true,
  sort_order            int NOT NULL DEFAULT 0,
  notes                 text,
  updated_at            timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.sg_priority_policy IS
  'Per-tier polling cadence definitions. Operator edits these to retune. Order of evaluation: lowest sort_order first; first match by (requires_owned + hours-to-event range) wins.';

INSERT INTO public.sg_priority_policy
  (tier, label, interval_seconds, min_hours_to_event, max_hours_to_event,
   requires_owned, daily_polls_per_event, sort_order, notes)
VALUES
  ('HOT',     'Owned + <6h to event',    60,    0,    6,   true,  360, 1, 'Stock-broker tick rate equivalent'),
  ('WARM',    'Owned + <24h to event',   300,   6,    24,  true,  96,  2, '5-min cadence; last-day repricing window'),
  ('COOL',    'Owned + <7d to event',    1800,  24,   168, true,  24,  3, '30-min cadence; 3-7d peak repricing per backtests'),
  ('COLD',    'Owned + <30d to event',   14400, 168,  720, true,  6,   4, '4-hour cadence; pre-clearance window'),
  ('OBSERVE', 'Upcoming, not owned',     43200, 0,    720, false, 2,   5, '12-hour cadence; observe broker network'),
  ('SKIP',    'Far future / no signal',  0,     720,  NULL,false, 0,   6, 'Beyond 30d - rely on per-window collectors')
ON CONFLICT (tier) DO NOTHING;

CREATE TABLE IF NOT EXISTS public.sg_event_priority_state (
  sg_event_id              bigint PRIMARY KEY,
  sg_event_name            text,
  sg_venue_name            text,
  sg_datetime_utc          timestamptz,
  aq_short_event_id        text,
  owned_count_last_7d      int NOT NULL DEFAULT 0,
  active_listings_last_7d  int NOT NULL DEFAULT 0,
  tier                     text NOT NULL,
  hours_to_event           numeric,
  last_polled_sales_at     timestamptz,
  last_polled_listings_at  timestamptz,
  sales_polls_today        int NOT NULL DEFAULT 0,
  listings_polls_today     int NOT NULL DEFAULT 0,
  budget_day               date NOT NULL DEFAULT current_date,
  computed_at              timestamptz NOT NULL DEFAULT clock_timestamp()
);

CREATE INDEX IF NOT EXISTS sg_event_priority_state_tier_due_idx
  ON public.sg_event_priority_state (tier, last_polled_sales_at NULLS FIRST);
CREATE INDEX IF NOT EXISTS sg_event_priority_state_due_listings_idx
  ON public.sg_event_priority_state (tier, last_polled_listings_at NULLS FIRST);

COMMENT ON TABLE public.sg_event_priority_state IS
  'Per-sg-event polling state. Tier is recomputed every 5 min by sg_classify_events(). poll_tick() reads this to decide which events to fire next.';

CREATE OR REPLACE FUNCTION public.sg_classify_events()
RETURNS integer
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = public, extensions, pg_temp
AS $func$
DECLARE
  v_now timestamptz := clock_timestamp();
  v_updated int := 0;
BEGIN
  -- CTE-aggregate-then-join pattern (correlated subqueries on 8.16M-row
  -- listings_snapshots time out).
  WITH listings_agg AS (
    SELECT
      aq_short_event_id,
      count(*) FILTER (WHERE is_owned = true) AS owned_cnt,
      count(*) AS listings_cnt
    FROM public.listings_snapshots
    WHERE captured_at > v_now - interval '7 days'
      AND aq_short_event_id IS NOT NULL
    GROUP BY aq_short_event_id
  ),
  event_metrics AS (
    SELECT
      c.sg_event_id,
      c.sg_event_name,
      c.sg_venue_name,
      c.sg_datetime_utc,
      a.aq_short_event_id,
      EXTRACT(epoch FROM (c.sg_datetime_utc - v_now)) / 3600 AS hours_to_event,
      coalesce(la.owned_cnt, 0)    AS owned_cnt,
      coalesce(la.listings_cnt, 0) AS listings_cnt
    FROM public.sg_events_canonical c
    LEFT JOIN public.aq_event_map a ON a.sg_event_id = c.sg_event_id
    LEFT JOIN listings_agg la ON la.aq_short_event_id = a.aq_short_event_id
    WHERE c.sg_datetime_utc IS NOT NULL
      AND c.sg_datetime_utc BETWEEN v_now - interval '6 hours' AND v_now + interval '60 days'
  ),
  classified AS (
    SELECT em.*,
      (SELECT p.tier FROM public.sg_priority_policy p
       WHERE p.enabled = true
         AND em.hours_to_event >= coalesce(p.min_hours_to_event, -999999)
         AND em.hours_to_event <  coalesce(p.max_hours_to_event, 999999)
         AND (p.requires_owned = false OR em.owned_cnt > 0)
       ORDER BY p.sort_order LIMIT 1) AS tier
    FROM event_metrics em
  )
  INSERT INTO public.sg_event_priority_state AS s
    (sg_event_id, sg_event_name, sg_venue_name, sg_datetime_utc, aq_short_event_id,
     owned_count_last_7d, active_listings_last_7d, tier, hours_to_event, computed_at)
  SELECT sg_event_id, sg_event_name, sg_venue_name, sg_datetime_utc, aq_short_event_id,
         owned_cnt, listings_cnt, coalesce(tier, 'SKIP'), hours_to_event, v_now
  FROM classified
  WHERE sg_event_id IS NOT NULL
  ON CONFLICT (sg_event_id) DO UPDATE SET
    sg_event_name           = EXCLUDED.sg_event_name,
    sg_venue_name           = EXCLUDED.sg_venue_name,
    sg_datetime_utc         = EXCLUDED.sg_datetime_utc,
    aq_short_event_id       = EXCLUDED.aq_short_event_id,
    owned_count_last_7d     = EXCLUDED.owned_count_last_7d,
    active_listings_last_7d = EXCLUDED.active_listings_last_7d,
    tier                    = EXCLUDED.tier,
    hours_to_event          = EXCLUDED.hours_to_event,
    computed_at             = EXCLUDED.computed_at,
    -- Reset daily counters at day rollover
    sales_polls_today       = CASE WHEN s.budget_day < current_date THEN 0 ELSE s.sales_polls_today END,
    listings_polls_today    = CASE WHEN s.budget_day < current_date THEN 0 ELSE s.listings_polls_today END,
    budget_day              = current_date;

  GET DIAGNOSTICS v_updated = ROW_COUNT;
  RETURN v_updated;
END $func$;

COMMENT ON FUNCTION public.sg_classify_events IS
  'Recomputes per-event tier + metrics. Run every 5 min. Reads sg_events_canonical join aq_event_map (sg_event_id) and listings_snapshots (aq_short_event_id) for owned + active counts. Cost: O(N) where N=upcoming sg events. Resets daily poll counters at day rollover.';

-- Note: secret is SEATGEEK_API_TOKEN (matches get_app_secret allowlist).
-- Token in query string (mirrors existing sg_broker_sales_queue pattern).
-- Return cols prefixed rpt_* to avoid ambiguity with sg_priority_policy.tier column.
DROP FUNCTION IF EXISTS public.sg_priority_poll_tick(int);
CREATE OR REPLACE FUNCTION public.sg_priority_poll_tick(p_max_polls int DEFAULT 50)
RETURNS TABLE (rpt_tier text, rpt_events_polled int, rpt_scope text)
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
  v_remaining int := p_max_polls;
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
    LIMIT v_remaining
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
    v_remaining := v_remaining - 1;
    EXIT WHEN v_remaining <= 0;
  END LOOP;

  IF v_remaining > 0 THEN
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
      LIMIT v_remaining
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
      v_remaining := v_remaining - 1;
      EXIT WHEN v_remaining <= 0;
    END LOOP;
  END IF;

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

COMMENT ON FUNCTION public.sg_priority_poll_tick IS
  'High-frequency polling driver. Reads sg_event_priority_state, fires HTTP polls for events whose tier interval has elapsed. p_max_polls caps per-fire cost. Sales loop runs first, then listings with remaining budget.';

-- Register the 4 new crons as PAUSED in the snapshot so operator can graduate via cron_resume_with_gate.
-- We use INSERT into the snapshot (not cron.schedule) so they're recorded but not active.
INSERT INTO public.cron_pause_state_20260514 (jobid, jobname, schedule, command)
VALUES
  (10000260001, 'sg_classify_events_5min', '*/5 * * * *',
   'SELECT public.sg_classify_events();'),
  (10000260002, 'sg_priority_poll_tick_1min', '* * * * *',
   'SELECT * FROM public.sg_priority_poll_tick(50);'),
  (10000260003, 'sg_priority_sales_process_1min', '* * * * *',
   'SELECT public.sg_broker_sales_process();'),
  (10000260004, 'sg_priority_listings_process_1min', '* * * * *',
   'SELECT public.sg_broker_listings_process();')
ON CONFLICT (jobid) DO NOTHING;

-- Seed cron_policy rows for the 4 new crons so cron_resume_with_gate works
INSERT INTO public.cron_policy
  (jobname, peak_hours_et, peak_min_interval_min, offpeak_min_interval_min,
   work_check_sql, daily_max_fires, notes)
VALUES
  ('sg_classify_events_5min',
   ARRAY[0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23],
   5, 15, NULL, 288, 'Always-on reclassifier; 5-min cadence captures tier transitions'),
  ('sg_priority_poll_tick_1min',
   ARRAY[0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23],
   1, 5,
   'SELECT EXISTS (SELECT 1 FROM public.sg_event_priority_state WHERE tier IN (''HOT'',''WARM'',''COOL'') LIMIT 1)',
   1440, 'Fires every minute IF there is any HOT/WARM/COOL event; gate work_check_sql short-circuits when nothing imminent'),
  ('sg_priority_sales_process_1min',
   ARRAY[0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23],
   1, 5,
   'SELECT EXISTS (SELECT 1 FROM public.sg_broker_pending WHERE scope=''sales'' AND resolved_at IS NULL LIMIT 1)',
   1440, 'Drains pending sales queue; skip when nothing pending'),
  ('sg_priority_listings_process_1min',
   ARRAY[0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23],
   1, 5,
   'SELECT EXISTS (SELECT 1 FROM public.sg_broker_pending WHERE scope=''listings'' AND resolved_at IS NULL LIMIT 1)',
   1440, 'Drains pending listings queue; skip when nothing pending')
ON CONFLICT (jobname) DO NOTHING;
