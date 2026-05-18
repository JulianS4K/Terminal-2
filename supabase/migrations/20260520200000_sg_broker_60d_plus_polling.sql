-- Migration 20260520200000 · lane:A1 · writes:sg_events_canonical+sg_broker_60d_plus_*_queue+4 crons · pre:20260520000000 · auth:operator-approved 2026-05-18
--
-- Add broker /listings + /sales polling for events >60 days out, off-peak
-- (ET 12am-6am + 1pm-4pm). Closes the gap exposed by the Yankees audit:
-- 46/60 home games had 0 SG listings + 0 sales because the priority
-- pipeline's classifier only audits events ≤60d out, and SKIP-tier policy
-- (min_hours_to_event=720) excludes anything 30-60d for non-owned teams.
--
-- Operator ask (2026-05-18): "still poll anything over 60 days+ for all
-- events so we can actually update movers with future events but not use
-- up cron and rate limits. need to poll those between 12am and 6am for
-- first run and then between 1pm and 4pm for second run."
--
-- Design:
--   • 1 schema add: sg_events_canonical.last_60d_pulled_at (round-robin key)
--   • 2 new functions: sg_broker_60d_plus_{listings,sales}_queue(p_max)
--   • 4 new crons (offset to non-occupied :1/:3 minutes within 5-min cycle):
--       sg_60d_listings_morning   '1-59/5 4-9 * * *'   UTC=ET 12-5:56am EDT
--       sg_60d_sales_morning      '3-58/5 4-9 * * *'   (same window, +2min)
--       sg_60d_listings_afternoon '1-59/5 17-19 * * *' UTC=ET 1-3:56pm EDT
--       sg_60d_sales_afternoon    '3-58/5 17-19 * * *' (same window, +2min)
--   • 4 cron_policy rows for pause/resume
--
-- Reuses existing sg_broker_pending + sg_broker_{listings,sales}_process
-- drain crons — no new persistence code needed.
--
-- Throughput math:
--   Morning:   72 firings/window × 8 events = 576 events/scope/day
--   Afternoon: 36 firings/window × 8 events = 288 events/scope/day
--   Total:     864 events × 2 scopes = 1,728 broker polls/day
--   Sustained: 0.02 req/sec << 1.25 SG quota ✓
--   Per-second burst at offset min :1 or :3: ≤8 polls (under 10/8s bucket)
--
-- Estimated 60d+ event count: ~700-1,000 (multi-sport + concerts). Full
-- cycle ~1 day per scope. Newly-added events (NULL last_60d_pulled_at)
-- jump to head of queue.
--
-- Per §3 landmines: pg_net is async (no pg_sleep); SKIP regex split
-- (cancelled/if-necessary always; TBD only when no TEvo bridge).

-- ============================================================
-- Part 1: schema
-- ============================================================
ALTER TABLE public.sg_events_canonical
  ADD COLUMN IF NOT EXISTS last_60d_pulled_at timestamptz;
CREATE INDEX IF NOT EXISTS idx_sg_canonical_60d_pulled
  ON public.sg_events_canonical (last_60d_pulled_at NULLS FIRST)
  WHERE sg_datetime_utc IS NOT NULL;

-- ============================================================
-- Part 2: Listings queue for >60d events
-- ============================================================
CREATE OR REPLACE FUNCTION public.sg_broker_60d_plus_listings_queue(p_max_events integer DEFAULT 8)
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
    SELECT c.sg_event_id
    FROM public.sg_events_canonical c
    WHERE c.sg_datetime_utc > now() + interval '60 days'
      AND c.sg_event_name !~* '(cancelled|if necessary)'
      AND NOT (c.sg_event_name ~* '(\(date tbd\)|^TBD at )' AND c.tevo_event_id IS NULL)
      AND NOT EXISTS (
        SELECT 1 FROM public.sg_broker_pending p
        WHERE p.sg_event_id = c.sg_event_id
          AND p.scope = 'listings'
          AND p.resolved_at IS NULL
      )
    ORDER BY c.last_60d_pulled_at NULLS FIRST, c.sg_event_id
    LIMIT p_max_events
  LOOP
    SELECT net.http_get(
      url := 'https://brokerdata.seatgeek.com/listings?token=' || v_token || '&event_id=' || r.sg_event_id::text,
      timeout_milliseconds := 30000
    ) INTO v_req_id;
    INSERT INTO public.sg_broker_pending(request_id, scope, sg_event_id)
      VALUES (v_req_id, 'listings', r.sg_event_id);
    UPDATE public.sg_events_canonical
      SET last_60d_pulled_at = now()
      WHERE sg_event_id = r.sg_event_id;
    v_count := v_count + 1;
  END LOOP;
  RETURN v_count;
END $function$;

COMMENT ON FUNCTION public.sg_broker_60d_plus_listings_queue(integer) IS
  'A1 mig 20260520200000: queue broker /listings for events >60d out. Default 8/call. Round-robin via last_60d_pulled_at NULLS FIRST. Skip cancelled/if-necessary; skip TBD-without-bridge. Off-peak only.';

-- ============================================================
-- Part 2: Sales queue for >60d events
-- ============================================================
CREATE OR REPLACE FUNCTION public.sg_broker_60d_plus_sales_queue(p_max_events integer DEFAULT 8)
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
    SELECT c.sg_event_id
    FROM public.sg_events_canonical c
    WHERE c.sg_datetime_utc > now() + interval '60 days'
      AND c.sg_event_name !~* '(cancelled|if necessary)'
      AND NOT (c.sg_event_name ~* '(\(date tbd\)|^TBD at )' AND c.tevo_event_id IS NULL)
      AND NOT EXISTS (
        SELECT 1 FROM public.sg_broker_pending p
        WHERE p.sg_event_id = c.sg_event_id
          AND p.scope = 'sales'
          AND p.resolved_at IS NULL
      )
    ORDER BY c.last_60d_pulled_at NULLS FIRST, c.sg_event_id
    LIMIT p_max_events
  LOOP
    SELECT net.http_get(
      url := 'https://brokerdata.seatgeek.com/sales?token=' || v_token || '&event_id=' || r.sg_event_id::text,
      timeout_milliseconds := 30000
    ) INTO v_req_id;
    INSERT INTO public.sg_broker_pending(request_id, scope, sg_event_id)
      VALUES (v_req_id, 'sales', r.sg_event_id);
    UPDATE public.sg_events_canonical
      SET last_60d_pulled_at = now()
      WHERE sg_event_id = r.sg_event_id;
    v_count := v_count + 1;
  END LOOP;
  RETURN v_count;
END $function$;

COMMENT ON FUNCTION public.sg_broker_60d_plus_sales_queue(integer) IS
  'A1 mig 20260520200000: queue broker /sales for events >60d out. First-ever sales coverage for 60d+ events (legacy sg_listings_60d+ cron handles only /v2/listings).';

-- ============================================================
-- Part 3: 4 cron entries (2 windows × {listings, sales})
-- ============================================================
DO $body$ DECLARE v_jobid bigint;
BEGIN
  FOR v_jobid IN SELECT jobid FROM cron.job
                 WHERE jobname IN ('sg_60d_listings_morning','sg_60d_sales_morning',
                                   'sg_60d_listings_afternoon','sg_60d_sales_afternoon')
  LOOP PERFORM cron.unschedule(v_jobid); END LOOP;

  -- Morning listings @ ET 12am-5:56am EDT (UTC 4:01-9:56)
  PERFORM cron.schedule(
    'sg_60d_listings_morning',
    '1-59/5 4-9 * * *',
    $cron$DO $cronbody$
    BEGIN
      IF NOT public.cron_should_fire('sg_60d_listings_morning') THEN RETURN; END IF;
      PERFORM public.sg_broker_60d_plus_listings_queue(8);
    END $cronbody$;$cron$
  );

  -- Morning sales (same window, +2min offset to alternate with listings)
  PERFORM cron.schedule(
    'sg_60d_sales_morning',
    '3-58/5 4-9 * * *',
    $cron$DO $cronbody$
    BEGIN
      IF NOT public.cron_should_fire('sg_60d_sales_morning') THEN RETURN; END IF;
      PERFORM public.sg_broker_60d_plus_sales_queue(8);
    END $cronbody$;$cron$
  );

  -- Afternoon listings @ ET 1pm-3:56pm EDT (UTC 17:01-19:56)
  PERFORM cron.schedule(
    'sg_60d_listings_afternoon',
    '1-59/5 17-19 * * *',
    $cron$DO $cronbody$
    BEGIN
      IF NOT public.cron_should_fire('sg_60d_listings_afternoon') THEN RETURN; END IF;
      PERFORM public.sg_broker_60d_plus_listings_queue(8);
    END $cronbody$;$cron$
  );

  -- Afternoon sales (same window, +2min offset)
  PERFORM cron.schedule(
    'sg_60d_sales_afternoon',
    '3-58/5 17-19 * * *',
    $cron$DO $cronbody$
    BEGIN
      IF NOT public.cron_should_fire('sg_60d_sales_afternoon') THEN RETURN; END IF;
      PERFORM public.sg_broker_60d_plus_sales_queue(8);
    END $cronbody$;$cron$
  );
END $body$;

-- ============================================================
-- Part 4: cron_policy rows (pause/resume + daily fire caps)
-- ============================================================
INSERT INTO public.cron_policy (jobname, peak_hours_et, peak_min_interval_min,
  offpeak_min_interval_min, daily_max_fires, enabled, notes)
VALUES
  ('sg_60d_listings_morning',   '{}'::int[], 5, 5, 72, true,
   '60d+ batch — ET 12-6am EDT (UTC 4-9), :1 offset, 8 events/firing'),
  ('sg_60d_sales_morning',      '{}'::int[], 5, 5, 72, true,
   '60d+ batch — ET 12-6am EDT (UTC 4-9), :3 offset, 8 events/firing'),
  ('sg_60d_listings_afternoon', '{}'::int[], 5, 5, 36, true,
   '60d+ batch — ET 1-4pm EDT (UTC 17-19), :1 offset, 8 events/firing'),
  ('sg_60d_sales_afternoon',    '{}'::int[], 5, 5, 36, true,
   '60d+ batch — ET 1-4pm EDT (UTC 17-19), :3 offset, 8 events/firing')
ON CONFLICT (jobname) DO UPDATE SET notes=EXCLUDED.notes, enabled=true, updated_at=now();
