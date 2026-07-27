-- Migration 20260512220000 · level:admin · lane:Audit/Push · writes:sweep_duplicate_listings,cron(sweep_duplicate_listings_hourly) · reads:listings_snapshots · pre:20260512210000
-- Periodic-sweep dedup for listings_snapshots, per-event batched.
--
-- Context: 47.7% redundancy measured on 24h sample (state-stable listings
-- re-snapshot every poll, same content different captured_at). Live consumer
-- audit 2026-05-12 confirmed no UI reads listings_snapshots beyond 96h —
-- removing stable-state duplicates is invisible to all UI surfaces.
--
-- Why per-event batching: full-table lag() over 9.6M rows times out at
-- Supabase's statement_timeout. Per-event partitioning is bounded
-- (largest events ~50K rows) and parallelizable across hourly cron runs.
--
-- Why periodic sweep vs INSERT trigger: trigger approach would break the
-- aggregate-generation functions (event_metrics/zone_metrics/section_metrics)
-- which compute "all listings at captured_at = X". Sweep happens AFTER
-- aggregates are computed so aggregates see the full pre-dedup snapshot
-- and remain correct.
--
-- Sales tables (evo_orders, evo_order_items, seatgeek_*_sales,
-- seatdata_sales_snapshots) NEVER touched — forever retention policy.

CREATE OR REPLACE FUNCTION public.sweep_duplicate_listings(p_max_events int DEFAULT 100)
RETURNS TABLE(events_swept int, rows_deleted int)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_event_id bigint;
  v_total_deleted int := 0;
  v_events_count int := 0;
  v_batch_deleted int;
BEGIN
  FOR v_event_id IN
    SELECT DISTINCT event_id
    FROM listings_snapshots
    ORDER BY event_id
    LIMIT p_max_events
  LOOP
    WITH dups AS (
      SELECT s.ctid,
        lag(quantity)         OVER w IS NOT DISTINCT FROM quantity         AS q_same,
        lag(retail_price)     OVER w IS NOT DISTINCT FROM retail_price     AS rp_same,
        lag(wholesale_price)  OVER w IS NOT DISTINCT FROM wholesale_price  AS wp_same,
        lag(format)           OVER w IS NOT DISTINCT FROM format           AS fmt_same,
        lag(splits)           OVER w IS NOT DISTINCT FROM splits           AS spl_same,
        lag(type)             OVER w IS NOT DISTINCT FROM type             AS typ_same,
        lag(wheelchair)       OVER w IS NOT DISTINCT FROM wheelchair       AS wc_same,
        lag(instant_delivery) OVER w IS NOT DISTINCT FROM instant_delivery AS idn_same,
        lag(eticket)          OVER w IS NOT DISTINCT FROM eticket          AS et_same,
        lag(is_ancillary)     OVER w IS NOT DISTINCT FROM is_ancillary     AS ia_same,
        lag(is_owned)         OVER w IS NOT DISTINCT FROM is_owned         AS io_same,
        lag(office_id)        OVER w IS NOT DISTINCT FROM office_id        AS off_same,
        lag(brokerage_id)     OVER w IS NOT DISTINCT FROM brokerage_id     AS brk_same,
        lag(section)          OVER w IS NOT DISTINCT FROM section          AS sec_same,
        lag(row)              OVER w IS NOT DISTINCT FROM row              AS rw_same
      FROM listings_snapshots s
      WHERE event_id = v_event_id
      WINDOW w AS (PARTITION BY tevo_ticket_group_id ORDER BY captured_at)
    )
    DELETE FROM listings_snapshots WHERE ctid IN (
      SELECT ctid FROM dups
      WHERE q_same AND rp_same AND wp_same AND fmt_same AND spl_same AND typ_same
        AND wc_same AND idn_same AND et_same AND ia_same AND io_same AND off_same
        AND brk_same AND sec_same AND rw_same
    );
    GET DIAGNOSTICS v_batch_deleted = ROW_COUNT;
    v_total_deleted := v_total_deleted + v_batch_deleted;
    v_events_count := v_events_count + 1;
  END LOOP;

  RETURN QUERY SELECT v_events_count, v_total_deleted;
END $$;

COMMENT ON FUNCTION public.sweep_duplicate_listings(int) IS
  'Per-event sweep of consecutive-identical-state rows. Cron hourly at :15, 50 events/run. Aggregates unaffected.';

-- Hourly sweep — 50 events/run is safe (largest events under statement_timeout)
SELECT cron.schedule(
  'sweep_duplicate_listings_hourly',
  '15 * * * *',
  $$ SELECT public.sweep_duplicate_listings(50); $$
);
