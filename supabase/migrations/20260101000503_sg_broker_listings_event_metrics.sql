-- Migration 20260517260000 · lane:A1 · writes:seatgeek_event_metrics+refresh_sg_broker_listings_event_metrics+cron · reads:seatgeek_listings_snapshots,seatgeek_event_xref · pre:20260517250000 · auth:operator-approved 2026-05-17
--
-- A1 — SG broker-listings event metrics (companion to PR #161 sales-side).
--
-- BACKGROUND
-- ---------
-- Operator: "do broadcast price, rename only if necessary or name new something
-- else but need user needs to know which is sales metrics and which is listing
-- metrics - also sg gives broker and owned for listings so need to create metrics
-- for each."
--
-- Today the SG-side distribution columns (cost_*) on seatgeek_event_metrics are
-- empty: compute_seatgeek_event_metrics reads from seatgeek_seller_listings
-- (our SG SellerDirect inventory — 1031 rows total, 47 events). The marketplace
-- firehose seatgeek_listings_snapshots (1.2M rows/24h, 437 events/24h) is never
-- aggregated into per-event distribution metrics.
--
-- Per-cohort split verified meaningful (24h sample):
--   is_broker_owned=true  (real inventory):  18,640 listings / 342 events
--                                            median $103, mean $218, p90 $519
--   is_broker_owned=false (speculative):    326,748 listings / 430 events
--                                            median $91, mean $184, p90 $368
--   Spec cohort is 17x the count and aggressively undercuts.
--
-- DESIGN
-- ------
-- Two parallel distribution sets on seatgeek_event_metrics:
--   listings_all_*    — full broker firehose, broadcast_price
--   listings_owned_*  — is_broker_owned=true subset, broadcast_price
-- Existing sold_* columns (PR #161 sales firehose) unchanged.
-- Existing cost_* columns marked DEPRECATED (legacy seller-only path; drop
-- in a future cleanup PR after confirming no readers).
--
-- New RPC + hourly cron @ :47 (off-cycle from sold @ :17, sg_canonical @ :12,:42).
--
-- FIXUPS BUNDLED HERE (applied separately on prod as 260001 + 260002; merging
-- into this file for cleaner git history since they were same-session):
--   - percentile_cont returns double precision; round(double, int) doesn't
--     exist. Cast to ::numeric before round.
--   - seatgeek_event_metrics.tevo_event_id was NOT NULL but the firehose has
--     SG-only events (no TEvo xref bridge). DROP NOT NULL so we can capture
--     those events too — many SG events have no TEvo counterpart but should
--     still get firehose aggregates.

-- ============================================================
-- Part 1: ADD 18 columns to seatgeek_event_metrics + drop NOT NULL on tevo_event_id
-- ============================================================
ALTER TABLE public.seatgeek_event_metrics
  ADD COLUMN IF NOT EXISTS listings_all_count    integer,
  ADD COLUMN IF NOT EXISTS listings_all_tickets  integer,
  ADD COLUMN IF NOT EXISTS listings_all_min      numeric,
  ADD COLUMN IF NOT EXISTS listings_all_p25      numeric,
  ADD COLUMN IF NOT EXISTS listings_all_median   numeric,
  ADD COLUMN IF NOT EXISTS listings_all_mean     numeric,
  ADD COLUMN IF NOT EXISTS listings_all_p75      numeric,
  ADD COLUMN IF NOT EXISTS listings_all_p90      numeric,
  ADD COLUMN IF NOT EXISTS listings_all_max      numeric,
  ADD COLUMN IF NOT EXISTS listings_owned_count    integer,
  ADD COLUMN IF NOT EXISTS listings_owned_tickets  integer,
  ADD COLUMN IF NOT EXISTS listings_owned_min      numeric,
  ADD COLUMN IF NOT EXISTS listings_owned_p25      numeric,
  ADD COLUMN IF NOT EXISTS listings_owned_median   numeric,
  ADD COLUMN IF NOT EXISTS listings_owned_mean     numeric,
  ADD COLUMN IF NOT EXISTS listings_owned_p75      numeric,
  ADD COLUMN IF NOT EXISTS listings_owned_p90      numeric,
  ADD COLUMN IF NOT EXISTS listings_owned_max      numeric;

-- tevo_event_id needs to be nullable: SG firehose has events with no TEvo xref
ALTER TABLE public.seatgeek_event_metrics
  ALTER COLUMN tevo_event_id DROP NOT NULL;

COMMENT ON COLUMN public.seatgeek_event_metrics.tevo_event_id IS
  'TEvo event id when a seatgeek_event_xref bridge exists, NULL when SG-only (no TEvo counterpart). A1 2026-05-17: dropped NOT NULL to allow firehose coverage on non-bridged events.';
COMMENT ON COLUMN public.seatgeek_event_metrics.listings_all_count IS 'SG broker firehose: count of live listings (DISTINCT ON sglid, 24h window). Populated by refresh_sg_broker_listings_event_metrics.';
COMMENT ON COLUMN public.seatgeek_event_metrics.listings_owned_count IS 'SG broker firehose subset where is_broker_owned=true (broker holds real ticket inventory, not speculative).';
COMMENT ON COLUMN public.seatgeek_event_metrics.cost_min IS 'DEPRECATED — populated only by legacy compute_seatgeek_event_metrics from seatgeek_seller_listings (our SG SellerDirect only). Use listings_all_min for marketplace-wide stats.';

-- ============================================================
-- Part 2: refresh_sg_broker_listings_event_metrics RPC
-- ============================================================
CREATE OR REPLACE FUNCTION public.refresh_sg_broker_listings_event_metrics(
  p_max_events integer DEFAULT 200
)
RETURNS integer
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = public, extensions, pg_temp
AS $func$
DECLARE
  r RECORD;
  v_count int := 0;
  v_tevo_event_id bigint;
BEGIN
  -- Per-event distribution from deduped 24h firehose. Two cohorts computed in
  -- a single pass via FILTER (WHERE is_broker_owned).
  -- DISTINCT ON (sglid) mandatory: SG pulls replay 11x per polling cycle per
  -- PROJECT_BIBLE §3. Scope to sg_event_id uses idx_sg_listings_sg_event_id_time.
  -- ::numeric casts before round() because percentile_cont returns double precision.
  FOR r IN
    WITH deduped AS (
      SELECT DISTINCT ON (sglid)
        sg_event_id, sglid, broadcast_price, quantity, is_broker_owned
      FROM public.seatgeek_listings_snapshots
      WHERE captured_at > now() - interval '24 hours'
      ORDER BY sglid, captured_at DESC
    )
    SELECT
      d.sg_event_id,
      count(*)::int                                            AS lall_count,
      coalesce(sum(quantity), 0)::int                          AS lall_tickets,
      min(broadcast_price)::numeric                            AS lall_min,
      percentile_cont(0.25) WITHIN GROUP (ORDER BY broadcast_price)::numeric AS lall_p25,
      percentile_cont(0.50) WITHIN GROUP (ORDER BY broadcast_price)::numeric AS lall_median,
      avg(broadcast_price)::numeric                            AS lall_mean,
      percentile_cont(0.75) WITHIN GROUP (ORDER BY broadcast_price)::numeric AS lall_p75,
      percentile_cont(0.90) WITHIN GROUP (ORDER BY broadcast_price)::numeric AS lall_p90,
      max(broadcast_price)::numeric                            AS lall_max,
      count(*) FILTER (WHERE is_broker_owned)::int             AS lown_count,
      coalesce(sum(quantity) FILTER (WHERE is_broker_owned), 0)::int AS lown_tickets,
      min(broadcast_price) FILTER (WHERE is_broker_owned)::numeric AS lown_min,
      (percentile_cont(0.25) WITHIN GROUP (ORDER BY broadcast_price) FILTER (WHERE is_broker_owned))::numeric AS lown_p25,
      (percentile_cont(0.50) WITHIN GROUP (ORDER BY broadcast_price) FILTER (WHERE is_broker_owned))::numeric AS lown_median,
      avg(broadcast_price) FILTER (WHERE is_broker_owned)::numeric AS lown_mean,
      (percentile_cont(0.75) WITHIN GROUP (ORDER BY broadcast_price) FILTER (WHERE is_broker_owned))::numeric AS lown_p75,
      (percentile_cont(0.90) WITHIN GROUP (ORDER BY broadcast_price) FILTER (WHERE is_broker_owned))::numeric AS lown_p90,
      max(broadcast_price) FILTER (WHERE is_broker_owned)::numeric AS lown_max
    FROM deduped d
    GROUP BY d.sg_event_id
    HAVING count(*) > 0
    ORDER BY lall_count DESC
    LIMIT p_max_events
  LOOP
    -- Resolve tevo_event_id (may be NULL if no xref bridge — column nullable per Part 1)
    SELECT tevo_event_id INTO v_tevo_event_id
    FROM public.seatgeek_event_xref WHERE sg_event_id = r.sg_event_id LIMIT 1;

    INSERT INTO public.seatgeek_event_metrics (
      sg_event_id, tevo_event_id, captured_at,
      listings_all_count, listings_all_tickets,
      listings_all_min, listings_all_p25, listings_all_median, listings_all_mean,
      listings_all_p75, listings_all_p90, listings_all_max,
      listings_owned_count, listings_owned_tickets,
      listings_owned_min, listings_owned_p25, listings_owned_median, listings_owned_mean,
      listings_owned_p75, listings_owned_p90, listings_owned_max
    )
    VALUES (
      r.sg_event_id, v_tevo_event_id, now(),
      r.lall_count, r.lall_tickets,
      round(r.lall_min, 2), round(r.lall_p25, 2), round(r.lall_median, 2), round(r.lall_mean, 2),
      round(r.lall_p75, 2), round(r.lall_p90, 2), round(r.lall_max, 2),
      r.lown_count, r.lown_tickets,
      round(r.lown_min, 2), round(r.lown_p25, 2), round(r.lown_median, 2), round(r.lown_mean, 2),
      round(r.lown_p75, 2), round(r.lown_p90, 2), round(r.lown_max, 2)
    );
    v_count := v_count + 1;
  END LOOP;
  RETURN v_count;
END $func$;

REVOKE ALL ON FUNCTION public.refresh_sg_broker_listings_event_metrics(integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.refresh_sg_broker_listings_event_metrics(integer) TO service_role;

COMMENT ON FUNCTION public.refresh_sg_broker_listings_event_metrics(integer) IS
  'A1 2026-05-17 — populates seatgeek_event_metrics.listings_all_* + listings_owned_* per event from the SG broker firehose (seatgeek_listings_snapshots, DISTINCT ON sglid, 24h window). Hourly cron @ :47. Companion to refresh_sg_broker_sales_event_metrics (sales, @ :17).';

-- ============================================================
-- Part 3: schedule hourly cron @ :47 via cron_should_fire gate
-- ============================================================
DO $body$
DECLARE v_jobid bigint;
BEGIN
  SELECT jobid INTO v_jobid FROM cron.job WHERE jobname = 'sg_broker_listings_metrics_refresh_hourly';
  IF v_jobid IS NOT NULL THEN
    PERFORM cron.unschedule(v_jobid);
  END IF;

  PERFORM cron.schedule(
    'sg_broker_listings_metrics_refresh_hourly',
    '47 * * * *',
    $cron$DO $cronbody$
    BEGIN
      IF NOT public.cron_should_fire('sg_broker_listings_metrics_refresh_hourly') THEN RETURN; END IF;
      PERFORM public.refresh_sg_broker_listings_event_metrics(200);
    END $cronbody$;$cron$
  );
END $body$;

-- Seed cron_policy entry so the gate has a known offpeak/peak schedule
INSERT INTO public.cron_policy (
  jobname, peak_hours_et, peak_min_interval_min, offpeak_min_interval_min,
  daily_max_fires, enabled, notes
) VALUES (
  'sg_broker_listings_metrics_refresh_hourly',
  '{9,10,11,12,13,14,15,16,17,18,19,20}'::int[],
  60, 60, 24, true,
  'SG broker-listings event metrics refresh — companion to sales-side @ :17. Reads firehose, computes listings_all_* + listings_owned_* distributions per event.'
) ON CONFLICT (jobname) DO UPDATE SET
  notes = EXCLUDED.notes,
  enabled = EXCLUDED.enabled,
  updated_at = now();
