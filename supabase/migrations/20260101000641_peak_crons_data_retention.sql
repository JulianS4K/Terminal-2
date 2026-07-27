-- 20260527190000_peak_crons_data_retention.sql
--
-- Four areas in one migration:
--
-- 1. ACTIVATE GT — lower td_enqueue_peak LIMIT 37 → 25
--    GT xref now has 77 active rows with event_url (td_gt_discover ran 2026-05-27).
--    Math: 25 × 3 platforms × 4 fires = 300 credits/day = daily cap exactly.
--    Old: 37 × 2 platforms × 4 fires = 296/day (SH+VD only).
--    New: 25 × 3 platforms × 4 fires = 300/day (SH+GT+VD).
--
-- 2. EVO 1-7d PEAK CRON — collect-listings-1-7d-peak
--    Schedule: */30 16-23,0-3 UTC (every 30 min, noon-11pm ET).
--    Extends the 1-7d window from 2×/day → continuous peak coverage for ALL events.
--    Uses min_age_seconds=1500 (25 min) so 30-min fires always find fresh work.
--    Complements collect-listings-0-24h (every 10 min) with near-imminent events.
--
-- 3. SG BROKER HOURLY PEAK BOOST — sg_broker_listings_queue_peak
--    Schedule: 30 16-23,0-3 UTC (:30 each peak hour, noon-11pm ET).
--    Fires sg_broker_listings_queue(25): 25 events/hr × all sg_events_canonical.
--    Stacked on top of existing 5-min/8-event baseline for denser peak coverage.
--    Offset :30 avoids collision with TD platform crons at :00.
--
-- 4. DATA RETENTION SWEEPS
--    seatgeek_listings_snapshots: 7.8 GB, ZERO TTL since table creation (2026-05-09).
--      sweep_old_sg_listings(p_days=14): daily at 03:15 UTC.
--      First run deletes ~1.7 GB (May 9-13). Steady-state ~433 MB/day.
--    ticketsdata_listings_snapshots: tiny now, will grow with 3-platform coverage.
--      sweep_old_td_listings(p_days=14): daily at 03:30 UTC.

-- ── 1. td_enqueue_peak: LIMIT 37 → 25 for GT activation ─────────────────────────

CREATE OR REPLACE FUNCTION public.td_enqueue_peak(
  p_platform     text    DEFAULT NULL,
  p_interval_tag text    DEFAULT 'manual'
)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
  r         RECORD;
  v_count   int := 0;
  v_now     timestamptz := clock_timestamp();
  v_jobname text;
BEGIN
  v_jobname := CASE
    WHEN p_platform IS NOT NULL THEN 'td_enqueue_peak_' || lower(p_platform)
    ELSE 'td_enqueue_peak'
  END;

  IF NOT public.cron_should_fire(v_jobname) THEN RETURN 0; END IF;

  IF NOT public.td_budget_ok() THEN
    RAISE NOTICE 'td_enqueue_peak(%): budget exhausted (daily or monthly), skipping',
      COALESCE(p_platform, 'all');
    RETURN 0;
  END IF;

  FOR r IN
    SELECT x.event_id, x.platform, x.event_url, x.always_on
    FROM public.ticketsdata_event_xref x
    JOIN public.sg_events_canonical sgc ON sgc.sg_event_id = (
      SELECT aem.sg_event_id FROM public.aq_event_map aem
      WHERE aem.aq_short_event_id = x.aq_short_event_id
      LIMIT 1)
    WHERE x.active            = true
      AND x.event_url         IS NOT NULL
      AND x.enqueues_today    < 4
      AND (p_platform IS NULL OR x.platform = p_platform)
      AND (x.always_on = true OR sgc.sg_datetime_utc < v_now + interval '7 days')
      AND NOT EXISTS (
        SELECT 1 FROM public.td_pull_queue q
        WHERE q.event_id  = x.event_id
          AND q.platform  = x.platform
          AND q.resolved_at IS NULL)
    ORDER BY
      x.always_on            DESC,
      x.owned_tickets        DESC NULLS LAST,
      x.median_retail_price  DESC NULLS LAST,
      x.last_enqueued_at     NULLS FIRST
    LIMIT 25   -- 25 × 3 platforms × 4 fires = 300 credits/day = daily cap
  LOOP
    INSERT INTO public.td_pull_queue
      (event_id, platform, event_url, interval_tag, created_at)
    VALUES (r.event_id, r.platform, r.event_url, p_interval_tag, v_now);

    UPDATE public.ticketsdata_event_xref
    SET last_enqueued_at = v_now,
        enqueues_today   = enqueues_today + 1,
        updated_at       = v_now
    WHERE (event_id, platform) = (r.event_id, r.platform);

    v_count := v_count + 1;
  END LOOP;

  RETURN v_count;
END $$;
REVOKE ALL ON FUNCTION public.td_enqueue_peak(text, text) FROM anon, public;
COMMENT ON FUNCTION public.td_enqueue_peak(text, text) IS
  'Push (event×platform) pairs to td_pull_queue. '
  'Priority: always_on DESC → owned_tickets DESC → median_retail_price DESC → last_enqueued_at ASC. '
  'LIMIT 25/call: 25 × 3 platforms × 4 fires = 300 credits/day (= 300/day cap). '
  'p_platform scopes to SH|GT|VD when called by per-platform staggered crons. '
  'GT activated 2026-05-27 (77 xref rows with event_url from td_gt_discover_drain). '
  'Budget gate: td_budget_ok() = td_daily_budget_ok() AND td_monthly_budget_ok(). '
  'Phase 2 note: if adding TP, revisit LIMIT (25 × 4 × 4 = 400 > 300 daily cap).';

-- Update cron_policy notes for all 3 platform crons to reflect new math + GT active
UPDATE public.cron_policy SET
  notes      = 'TD enqueue SH — noon/3pm/6pm/9pm ET (0 16,19,22,1 UTC). '
                'LIMIT 25/call: 25 × 3 platforms × 4 fires = 300 credits/day (daily cap). '
                'GT activated 2026-05-27.',
  updated_at = now()
WHERE jobname = 'td_enqueue_peak_sh';

UPDATE public.cron_policy SET
  notes      = 'TD enqueue GT — 1pm/4pm/7pm/10pm ET (0 17,20,23,2 UTC). '
                'ACTIVATED 2026-05-27: 77 GT xref rows with seo_url from td_gt_discover_drain. '
                'LIMIT 25/call. Hourly offset +1h from SH for clean drain windows.',
  updated_at = now()
WHERE jobname = 'td_enqueue_peak_gt';

UPDATE public.cron_policy SET
  notes      = 'TD enqueue VD — 2pm/5pm/8pm/11pm ET (0 18,21,0,3 UTC). '
                'LIMIT 25/call: 25 × 3 platforms × 4 fires = 300 credits/day. '
                'Hourly offset +2h from SH. VD normalizer strips word prefixes from sections.',
  updated_at = now()
WHERE jobname = 'td_enqueue_peak_vd';

-- ── 2. EVO 1-7d peak cron ────────────────────────────────────────────────────────

DO $sched$ BEGIN

  PERFORM cron.schedule(
    'collect-listings-1-7d-peak',
    '*/30 16-23,0-3 * * *',
    $cron$DO $b$ BEGIN
      IF NOT public.cron_should_fire('collect-listings-1-7d-peak') THEN RETURN; END IF;
      PERFORM public._cron_invoke_edge_fn(
        'https://hzrizjeaxlqcxfrtczpq.supabase.co/functions/v1/collect-listings?window=1-7d&min_age_seconds=1500',
        '{}'::jsonb);
    END $b$;$cron$
  );

-- ── 3. SG broker hourly peak boost ───────────────────────────────────────────────

  PERFORM cron.schedule(
    'sg_broker_listings_queue_peak',
    '30 16-23,0-3 * * *',
    $cron$DO $b$ BEGIN
      IF NOT public.cron_should_fire('sg_broker_listings_queue_peak') THEN RETURN; END IF;
      PERFORM public.sg_broker_listings_queue(25);
    END $b$;$cron$
  );

-- ── 4a. Sweep crons ───────────────────────────────────────────────────────────────

  PERFORM cron.schedule(
    'sweep-old-sg-listings',
    '15 3 * * *',
    $cron$DO $b$ BEGIN
      IF NOT public.cron_should_fire('sweep-old-sg-listings') THEN RETURN; END IF;
      PERFORM public.sweep_old_sg_listings(14);
    END $b$;$cron$
  );

  PERFORM cron.schedule(
    'sweep-old-td-listings',
    '30 3 * * *',
    $cron$DO $b$ BEGIN
      IF NOT public.cron_should_fire('sweep-old-td-listings') THEN RETURN; END IF;
      PERFORM public.sweep_old_td_listings(14);
    END $b$;$cron$
  );

END $sched$;

-- ── 4b. Sweep functions ───────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.sweep_old_sg_listings(
  p_days int DEFAULT 14
)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
  v_count integer;
BEGIN
  -- seatgeek_listings_snapshots has composite indexes on (tevo_event_id, captured_at)
  -- and (sg_event_id, captured_at). Planner will bitmap-OR them for the delete.
  -- First run (2026-05-27): ~4 days of rows deleted (~1.7 GB).
  -- Steady-state: ~1 day of rows (~433 MB) per daily 03:15 UTC fire.
  DELETE FROM public.seatgeek_listings_snapshots
  WHERE captured_at < now() - make_interval(days => p_days);
  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END;
$$;
REVOKE ALL ON FUNCTION public.sweep_old_sg_listings(int) FROM anon, public;
COMMENT ON FUNCTION public.sweep_old_sg_listings(int) IS
  '14-day TTL sweep for seatgeek_listings_snapshots. '
  'Ran daily at 03:15 UTC. Table was 7.8 GB with zero TTL before this migration. '
  'Returns rows deleted.';

CREATE OR REPLACE FUNCTION public.sweep_old_td_listings(
  p_days int DEFAULT 14
)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
  v_count integer;
BEGIN
  DELETE FROM public.ticketsdata_listings_snapshots
  WHERE captured_at < now() - make_interval(days => p_days);
  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END;
$$;
REVOKE ALL ON FUNCTION public.sweep_old_td_listings(int) FROM anon, public;
COMMENT ON FUNCTION public.sweep_old_td_listings(int) IS
  '14-day TTL sweep for ticketsdata_listings_snapshots. '
  'Ran daily at 03:30 UTC. Content-hash dedup keeps volume manageable. '
  'Returns rows deleted.';

-- ── 4c. cron_policy rows for new crons ───────────────────────────────────────────

INSERT INTO public.cron_policy
  (jobname, peak_hours_et, peak_min_interval_min, offpeak_min_interval_min,
   daily_max_fires, work_check_sql, enabled, notes)
VALUES
  -- EVO 1-7d peak: fires every 30 min during noon-11pm ET.
  -- Schedule itself gates to peak hours; cron_should_fire just checks enabled + interval.
  ('collect-listings-1-7d-peak',
   ARRAY[12,13,14,15,16,17,18,19,20,21,22,23]::int[],
   25, 55, 24,
   'SELECT true',
   true,
   'EVO 1-7d collect-listings every 30 min during peak (*/30 16-23,0-3 UTC). '
   'Extends 1-7d from 2×/day → continuous peak coverage. '
   'min_age_seconds=1500 prevents re-pulling events collected within 25 min. '
   'Covers ALL sg_events_canonical (not just TD-tracked). Activated 2026-05-27.'),

  -- SG broker hourly peak: fires at :30 each peak hour.
  -- 25 events/fire × 12 fires/day = 300 events/day of fresh broker data.
  ('sg_broker_listings_queue_peak',
   ARRAY[12,13,14,15,16,17,18,19,20,21,22,23]::int[],
   55, 1440, 12,
   'SELECT true',
   true,
   'SG broker listings peak boost: sg_broker_listings_queue(25) at :30 each peak hour '
   '(30 16-23,0-3 UTC = noon-11pm ET). '
   '25 events × 12 hr = 300 broker pulls/day on top of existing 5-min/8-event baseline. '
   'Orders by sg_event_date ASC — most imminent events first. Activated 2026-05-27.'),

  -- Sweep crons: once daily in overnight window.
  ('sweep-old-sg-listings',
   ARRAY[]::int[], 1440, 1440, 1,
   'SELECT true',
   true,
   'TTL sweep: DELETE FROM seatgeek_listings_snapshots WHERE captured_at < now()-14d. '
   'Daily 03:15 UTC. Table was 7.8 GB with zero TTL at activation (2026-05-27). '
   'Steady-state ~433 MB/day deleted. Returns deleted row count.'),

  ('sweep-old-td-listings',
   ARRAY[]::int[], 1440, 1440, 1,
   'SELECT true',
   true,
   'TTL sweep: DELETE FROM ticketsdata_listings_snapshots WHERE captured_at < now()-14d. '
   'Daily 03:30 UTC. Content-hash dedup limits growth. Returns deleted row count.')

ON CONFLICT (jobname) DO UPDATE
  SET notes      = EXCLUDED.notes,
      enabled    = true,
      updated_at = now();
