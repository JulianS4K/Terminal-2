-- 20260527230000_sg_peak_capacity_retention.sql
--
-- Two changes:
--
-- 1. SG 5-min peak boost: replace hourly peak (sg_broker_listings_queue_peak,
--    30 16-23,0-3, 25 events/hr) with 5-min peak cron
--    (sg_broker_listings_queue_5min_peak, */5 16-23,0-3, 25 events/fire).
--
--    Rate math (verified against live 429 data 2026-05-27):
--      Off-peak (4-15 UTC): baseline 8 events/5min = 96 events/hr (24/7, unchanged)
--      Peak (16-23,0-3 UTC): baseline 8 + peak 25 = 33/5min = 396 events/hr
--      396/hr = 63% of observed safe ceiling (~630/hr). 429 health check continues.
--
-- 2. SG raw retention: 14 days → 24 hours, sweep 4×/day (3,9,15,21 UTC).
--    seatgeek_listings_snapshots had ZERO TTL since 2026-05-09 = ~7.8 GB.
--    First sweep at 3:15 UTC will delete everything older than 24h (one-time large delete).
--    Steady-state: ~6h of rows per run (~108 MB/run at current volume).
--    Metric snapshots (event_listing_snapshot_daily) retain 1 year — 24h raw is safe.

-- ── 1. Replace hourly peak with 5-min peak ────────────────────────────────────

DO $sched$ BEGIN

  -- Unschedule hourly peak (30 16-23,0-3, added 20260527190000)
  PERFORM cron.unschedule('sg_broker_listings_queue_peak');

  -- New 5-min peak: fires in addition to baseline sg_broker_listings_queue_5min (*/5, 24/7)
  PERFORM cron.schedule(
    'sg_broker_listings_queue_5min_peak',
    '*/5 16-23,0-3 * * *',
    $cron$DO $b$ BEGIN
      IF NOT public.cron_should_fire('sg_broker_listings_queue_5min_peak') THEN RETURN; END IF;
      PERFORM public.sg_broker_listings_queue(25);
    END $b$;$cron$
  );

-- ── 2. Reschedule SG sweep to 4×/day ─────────────────────────────────────────

  -- Current: 15 3 * * * (daily). New: 4×/day at 3:15, 9:15, 15:15, 21:15 UTC.
  PERFORM cron.schedule(
    'sweep-old-sg-listings',
    '15 3,9,15,21 * * *',
    $cron$DO $b$ BEGIN
      IF NOT public.cron_should_fire('sweep-old-sg-listings') THEN RETURN; END IF;
      PERFORM public.sweep_old_sg_listings(24);
    END $b$;$cron$
  );

END $sched$;

-- ── 3. Update sweep_old_sg_listings: p_hours signature, 24h TTL ──────────────
-- Must DROP first — Postgres disallows parameter renames via CREATE OR REPLACE.

DROP FUNCTION IF EXISTS public.sweep_old_sg_listings(int);

CREATE OR REPLACE FUNCTION public.sweep_old_sg_listings(
  p_hours int DEFAULT 24
)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
  v_count integer;
BEGIN
  -- 24h rolling window for seatgeek_listings_snapshots (raw broker listing data).
  -- Metric snapshots (event_listing_snapshot_daily) retain 1 year for trend analysis.
  -- First run at 3:15 UTC will delete all rows older than 24h (one-time ~7.8 GB delete).
  DELETE FROM public.seatgeek_listings_snapshots
  WHERE captured_at < now() - make_interval(hours => p_hours);
  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END;
$$;
REVOKE ALL ON FUNCTION public.sweep_old_sg_listings(int) FROM anon, public;
COMMENT ON FUNCTION public.sweep_old_sg_listings(int) IS
  'UPDATED 2026-05-27: 24h TTL (was 14d). '
  'Runs 4x/day at 3:15/9:15/15:15/21:15 UTC. '
  'First run deletes ~7.8 GB of backlog (May 9 onward). '
  'Steady-state: ~108 MB/run at current SG volume. '
  'Trend data kept 1 year in event_listing_snapshot_daily.';

-- ── 4. cron_policy updates ────────────────────────────────────────────────────

-- Remove stale policy for hourly peak (unscheduled above)
DELETE FROM public.cron_policy WHERE jobname = 'sg_broker_listings_queue_peak';

-- New 5-min peak policy
INSERT INTO public.cron_policy
  (jobname, peak_hours_et, peak_min_interval_min, offpeak_min_interval_min,
   daily_max_fires, work_check_sql, enabled, notes)
VALUES
  ('sg_broker_listings_queue_5min_peak',
   ARRAY[12,13,14,15,16,17,18,19,20,21,22,23]::int[], 4, 4, 144,
   'SELECT true', true,
   'SG broker listings peak boost: sg_broker_listings_queue(25) every 5 min during peak '
   '(*/5 16-23,0-3 UTC = noon-11pm ET). '
   'Stacks on top of baseline sg_broker_listings_queue_5min (8 events/5min, 24/7). '
   'Combined peak rate: 33 events/5min = 396/hr = 63% of safe ceiling (~630/hr). '
   'Replaces hourly peak (sg_broker_listings_queue_peak) added 2026-05-27.')
ON CONFLICT (jobname) DO UPDATE
  SET notes      = EXCLUDED.notes,
      enabled    = true,
      updated_at = now();

-- Update sweep policy: 4×/day, 6h interval
UPDATE public.cron_policy SET
  peak_min_interval_min    = 360,
  offpeak_min_interval_min = 360,
  daily_max_fires          = 4,
  notes = 'SG listings sweep: DELETE seatgeek_listings_snapshots WHERE captured_at < now()-24h. '
          '4x/day at 3:15/9:15/15:15/21:15 UTC. '
          'Was daily 14d TTL (activated 2026-05-27 from 7.8 GB zero-TTL table). '
          'First run deletes ~7.8 GB. Steady-state ~108 MB/run.',
  updated_at = now()
WHERE jobname = 'sweep-old-sg-listings';
