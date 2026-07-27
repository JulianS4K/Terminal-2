-- "MARKET NOT US" median — median retail across non-S4K listings only.
-- Applied to prod 2026-05-09 ~03:30 UTC; this file captures it for git parity.
--
-- Why: chart's default view per user spec needs THREE price-line series:
--   - Market median (all listings, including S4K)        → retail_median
--   - Owned median (S4K only)                            → owned_median_retail
--   - Market median NOT including S4K                    → nonowned_median_retail (NEW)
-- Median-of-subset can't be derived from medians-of-whole + medians-of-complement,
-- so we have to aggregate directly from listings_snapshots filtered to is_owned=false.
--
-- For Knicks G5 (3345925) the difference is meaningful:
--   retail_median (all)      $988.26
--   owned_median_retail       $1,117.19  (S4K asking 13% premium)
--   nonowned_median_retail    $950.04   (rest of market, $38 below all-market)

ALTER TABLE event_metrics ADD COLUMN IF NOT EXISTS nonowned_median_retail numeric;

COMMENT ON COLUMN event_metrics.nonowned_median_retail IS
  'Median retail_price across non-ancillary, non-S4K-owned listings (is_owned=false). Computed from listings_snapshots; backfilled by compute_event_nonowned_median(event_id) and cron-driven by midnight-catchup-sweep + nonowned-median-30min crons. Used by chart "MARKET NOT US" series.';

CREATE OR REPLACE FUNCTION compute_event_nonowned_median(p_event_id bigint)
RETURNS TABLE(updated_at timestamptz, nonowned_median numeric) LANGUAGE plpgsql AS $$
DECLARE
  v_latest timestamptz;
  v_med numeric;
BEGIN
  SELECT MAX(captured_at) INTO v_latest FROM listings_snapshots WHERE event_id = p_event_id;
  IF v_latest IS NULL THEN RETURN; END IF;

  SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY retail_price)
  INTO v_med
  FROM listings_snapshots
  WHERE event_id = p_event_id
    AND captured_at = v_latest
    AND COALESCE(is_ancillary, false) = false
    AND COALESCE(is_owned, false) = false
    AND retail_price IS NOT NULL;

  IF v_med IS NULL THEN RETURN; END IF;

  UPDATE event_metrics SET nonowned_median_retail = round(v_med::numeric, 2)
  WHERE event_id = p_event_id AND captured_at = v_latest;

  updated_at := v_latest;
  nonowned_median := round(v_med::numeric, 2);
  RETURN NEXT;
END $$;

GRANT EXECUTE ON FUNCTION compute_event_nonowned_median(bigint) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION backfill_event_nonowned_median(p_max_events int DEFAULT 500)
RETURNS TABLE(updated_count int) LANGUAGE plpgsql AS $$
DECLARE r RECORD; n int := 0;
BEGIN
  FOR r IN (
    SELECT DISTINCT event_id FROM event_metrics
    WHERE captured_at >= NOW() - INTERVAL '7 days'
      AND nonowned_median_retail IS NULL
    LIMIT p_max_events
  ) LOOP
    BEGIN
      PERFORM compute_event_nonowned_median(r.event_id);
      n := n + 1;
    EXCEPTION WHEN OTHERS THEN
      RAISE NOTICE 'compute_event_nonowned_median failed for event %: %', r.event_id, SQLERRM;
    END;
  END LOOP;
  updated_count := n;
  RETURN NEXT;
END $$;

GRANT EXECUTE ON FUNCTION backfill_event_nonowned_median(int) TO service_role;

SELECT cron.schedule(
  'compute-event-nonowned-30min',
  '7,37 * * * *',
  $$ SELECT public.backfill_event_nonowned_median(500); $$
);
