-- Fix: sweep_old_listings overload ambiguity + sweep_old_sg_listings unbounded DELETE timeout
-- Authored by D0 2026-05-28. A1 to review + apply.
--
-- PROBLEM A — sweep_old_listings "not unique" (100% failure rate, 4x/day cron)
--   Two overloads both callable as sweep_old_listings():
--     1. sweep_old_listings()            — 0-arg, deletes listings_snapshots > 30d
--     2. sweep_old_listings(p_days int)  — 1-arg with DEFAULT 1, also callable with 0 args
--   Postgres: "Could not choose a best candidate function" → cron fails every time.
--   Fix: DROP 0-arg overload. Fix 1-arg body (hardcoded 24h → uses p_days). DEFAULT 30 (30d TTL
--   per mig 240000). Update cron to call sweep_old_listings(30) explicitly.
--
-- PROBLEM B — sweep_old_sg_listings timeout (100% failure rate, 4x/day cron)
--   Single unbounded DELETE on seatgeek_listings_snapshots (9.2M rows, 8 GB).
--   Always hits 120s statement_timeout before finishing.
--   Fix: time-bounded batch loop — deletes 10K rows/iteration up to 90s wall time per call.
--   At 4 fires/day × 90s each, handles up to ~5M row purge/day.

-- ── PART A: sweep_old_listings ───────────────────────────────────────────────

-- Drop the ambiguous 0-arg overload (30d listings-only version)
DROP FUNCTION IF EXISTS public.sweep_old_listings();

-- Rebuild 1-arg to actually use p_days (was hardcoded to 24h), keep event_metrics cleanup
CREATE OR REPLACE FUNCTION public.sweep_old_listings(p_days integer DEFAULT 30)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
  v_start     timestamptz := clock_timestamp();
  v_ls_count  integer     := 0;
  v_em_count  integer;
  v_batch     integer;
  v_cutoff    timestamptz := now() - make_interval(days => p_days);
BEGIN
  -- Batch-delete listings_snapshots in 50K chunks, time-bounded to 80s
  LOOP
    EXIT WHEN clock_timestamp() - v_start > interval '80 seconds';
    WITH to_delete AS (
      SELECT id FROM public.listings_snapshots
      WHERE captured_at < v_cutoff
      ORDER BY captured_at
      LIMIT 50000
    )
    DELETE FROM public.listings_snapshots
    WHERE id IN (SELECT id FROM to_delete);
    GET DIAGNOSTICS v_batch = ROW_COUNT;
    v_ls_count := v_ls_count + v_batch;
    EXIT WHEN v_batch = 0;
  END LOOP;

  -- Sweep event_metrics older than 7 days (lightweight — 85K rows total)
  DELETE FROM public.event_metrics
  WHERE captured_at < now() - interval '7 days';
  GET DIAGNOSTICS v_em_count = ROW_COUNT;

  RETURN v_ls_count + v_em_count;
END;
$$;

-- Update cron to call explicitly (no ambiguity)
SELECT cron.unschedule('sweep-old-listings');
SELECT cron.schedule(
  'sweep-old-listings',
  '20 3,9,15,21 * * *',
  $cronbody$
    DO $b$ BEGIN
      IF NOT public.cron_should_fire('sweep-old-listings') THEN RETURN; END IF;
      PERFORM public.sweep_old_listings(30);
    END $b$;
  $cronbody$
);

-- ── PART B: sweep_old_sg_listings ───────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.sweep_old_sg_listings(p_hours integer DEFAULT 48)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
  v_start  timestamptz := clock_timestamp();
  v_total  integer     := 0;
  v_batch  integer;
  v_cutoff timestamptz := now() - make_interval(hours => p_hours);
BEGIN
  -- Batch-delete in 10K chunks, time-bounded to 90s wall time per cron call.
  -- At 4 fires/day this handles up to ~4M row purge/day on seatgeek_listings_snapshots.
  LOOP
    EXIT WHEN clock_timestamp() - v_start > interval '90 seconds';
    WITH to_delete AS (
      SELECT id FROM public.seatgeek_listings_snapshots
      WHERE captured_at < v_cutoff
      ORDER BY captured_at
      LIMIT 10000
    )
    DELETE FROM public.seatgeek_listings_snapshots
    WHERE id IN (SELECT id FROM to_delete);
    GET DIAGNOSTICS v_batch = ROW_COUNT;
    v_total := v_total + v_batch;
    EXIT WHEN v_batch = 0;
  END LOOP;
  RETURN v_total;
END;
$$;

-- Verify overloads (should be exactly 1 row for sweep_old_listings after DROP)
SELECT proname, pg_get_function_identity_arguments(oid) AS args
FROM pg_proc
WHERE proname IN ('sweep_old_listings','sweep_old_sg_listings')
  AND pronamespace = 'public'::regnamespace
ORDER BY proname, args;
