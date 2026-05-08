-- Splits inventory metrics on event_metrics + compute fn + cron.
-- Applied to prod 2026-05-08 ~23:00 UTC (this file captures it for git parity).
--
-- Why: TEvo ticket_groups carry a `splits` integer[] column meaning "buyer
-- can purchase any of these quantities" (e.g. [2,4] = pairs or all-four,
-- [1,2,3,4] = anything 1-4, NULL = all-or-nothing). This is real broker
-- inventory signal: how flexible is the book — are buyers forced to buy
-- pairs, can they buy singles, etc. We aggregate per-event into 8 columns
-- so the chart workbench + Market structure panel can plot/show them.
--
-- Functions:
--   compute_event_splits_metrics(p_event_id)
--     Computes splits stats from latest listings_snapshots and UPDATEs the
--     latest event_metrics row. Idempotent.
--   backfill_event_splits_metrics(p_max_events)
--     Loops compute_event_splits_metrics over recently-active events that
--     haven't been computed yet. Used both for one-shot backfill and for
--     the cron job below.
--
-- Schedule: 'compute-event-splits-30min' fires at :03/:33 every hour, after
-- collect-listings has had a chance to write the new metrics row.

ALTER TABLE event_metrics
  ADD COLUMN IF NOT EXISTS splits_min_q                int,
  ADD COLUMN IF NOT EXISTS splits_listings_with_singles int,
  ADD COLUMN IF NOT EXISTS splits_listings_with_pairs   int,
  ADD COLUMN IF NOT EXISTS splits_listings_with_3       int,
  ADD COLUMN IF NOT EXISTS splits_listings_with_4plus   int,
  ADD COLUMN IF NOT EXISTS splits_listings_no_split     int,
  ADD COLUMN IF NOT EXISTS splits_pct_pairs             numeric(5,4),
  ADD COLUMN IF NOT EXISTS splits_pct_singles           numeric(5,4);

COMMENT ON COLUMN event_metrics.splits_min_q IS
  'Median of MIN(splits) across non-ancillary listings — the typical minimum quantity a buyer must purchase.';
COMMENT ON COLUMN event_metrics.splits_pct_pairs IS
  'Share of non-ancillary listings whose splits[] contains 2 — % of inventory that can sell pairs.';
COMMENT ON COLUMN event_metrics.splits_pct_singles IS
  'Share of non-ancillary listings whose splits[] contains 1 — % of inventory that can sell singles.';

CREATE OR REPLACE FUNCTION compute_event_splits_metrics(p_event_id bigint)
RETURNS TABLE(updated_at timestamptz, splits_min_q int, with_singles int, with_pairs int, no_split int) LANGUAGE plpgsql AS $$
DECLARE
  v_latest timestamptz;
  v_min_q int;
  v_singles int; v_pairs int; v_three int; v_fourplus int; v_no int;
  v_total int;
BEGIN
  SELECT MAX(captured_at) INTO v_latest FROM listings_snapshots WHERE event_id = p_event_id;
  IF v_latest IS NULL THEN RETURN; END IF;

  WITH ls AS (
    SELECT splits, quantity FROM listings_snapshots
    WHERE event_id = p_event_id
      AND captured_at = v_latest
      AND COALESCE(is_ancillary, false) = false
  )
  SELECT
    COALESCE(percentile_disc(0.5) WITHIN GROUP (
      ORDER BY (CASE WHEN splits IS NULL OR cardinality(splits)=0 THEN quantity ELSE splits[1] END)
    ), NULL),
    COUNT(*) FILTER (WHERE splits IS NOT NULL AND 1 = ANY(splits)),
    COUNT(*) FILTER (WHERE splits IS NOT NULL AND 2 = ANY(splits)),
    COUNT(*) FILTER (WHERE splits IS NOT NULL AND 3 = ANY(splits)),
    COUNT(*) FILTER (WHERE splits IS NOT NULL AND EXISTS (SELECT 1 FROM unnest(splits) s WHERE s >= 4)),
    COUNT(*) FILTER (WHERE splits IS NULL OR cardinality(splits) = 0),
    COUNT(*)
  INTO v_min_q, v_singles, v_pairs, v_three, v_fourplus, v_no, v_total
  FROM ls;

  IF v_total IS NULL OR v_total = 0 THEN RETURN; END IF;

  UPDATE event_metrics SET
    splits_min_q                  = v_min_q,
    splits_listings_with_singles  = v_singles,
    splits_listings_with_pairs    = v_pairs,
    splits_listings_with_3        = v_three,
    splits_listings_with_4plus    = v_fourplus,
    splits_listings_no_split      = v_no,
    splits_pct_pairs              = CASE WHEN v_total > 0 THEN ROUND((v_pairs::numeric / v_total)::numeric, 4) END,
    splits_pct_singles            = CASE WHEN v_total > 0 THEN ROUND((v_singles::numeric / v_total)::numeric, 4) END
  WHERE event_id = p_event_id AND captured_at = v_latest;

  updated_at := v_latest;
  splits_min_q := v_min_q;
  with_singles := v_singles;
  with_pairs := v_pairs;
  no_split := v_no;
  RETURN NEXT;
END $$;

GRANT EXECUTE ON FUNCTION compute_event_splits_metrics(bigint) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION backfill_event_splits_metrics(p_max_events int DEFAULT 1000)
RETURNS TABLE(updated_count int) LANGUAGE plpgsql AS $$
DECLARE r RECORD; n int := 0;
BEGIN
  FOR r IN (
    SELECT DISTINCT event_id FROM event_metrics
    WHERE captured_at >= NOW() - INTERVAL '7 days'
      AND splits_min_q IS NULL
    LIMIT p_max_events
  ) LOOP
    PERFORM compute_event_splits_metrics(r.event_id);
    n := n + 1;
  END LOOP;
  updated_count := n;
  RETURN NEXT;
END $$;

GRANT EXECUTE ON FUNCTION backfill_event_splits_metrics(int) TO service_role;

SELECT cron.schedule(
  'compute-event-splits-30min',
  '3,33 * * * *',
  $$ SELECT public.backfill_event_splits_metrics(500); $$
);
