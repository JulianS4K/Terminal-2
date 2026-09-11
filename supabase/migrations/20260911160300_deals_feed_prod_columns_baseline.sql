-- ============================================================================
-- Migration 20260911160300 — gotickets_deals_feed: record the prod-only columns
--
-- Lane:     D0 (deals surface)
-- Touches:  gotickets_deals_feed (W — ADD COLUMN IF NOT EXISTS ×10, all nullable)
-- Pre-reqs: 20260811240000 (feed + gt_event_id)
--
-- BASELINE CAPTURE, no behaviour change. The live scan_gotickets_deals in prod
-- (its own header cites "D0 mig 20260812120000" + the 2026-08-19 zone-level
-- rewrite) writes ten feed columns that no committed migration ever added:
-- regime / dte_now / degr_excess_pct / degr_factor (event-specific degradation),
-- est_net_resale_raw / net_profit_pct_raw / win_prob_raw (pre-degradation
-- readouts) and zone_median / zone_n / vs_zone_pct (the curated-zone outlier
-- statistics). The committed tree therefore cannot build a feed the outcome
-- label (mig 20260911160400) can read, and migrations-from-zero would fail on
-- the first reference. Every ADD is IF NOT EXISTS and nullable: a no-op on
-- prod, the missing shape everywhere else.
--
-- The function BODIES that write these columns are still prod-only; capturing
-- them is a separate reconciliation task (KANBAN D0-DEALS-1), deliberately not
-- bundled here so this file stays a pure, reversible schema record.
--
-- READ-ONLY upstream: no API call.
-- ROLLBACK: ALTER TABLE public.gotickets_deals_feed DROP COLUMN <each>;
--           (only safe where the prod scanner has first stopped writing them)
-- ============================================================================

ALTER TABLE public.gotickets_deals_feed
  ADD COLUMN IF NOT EXISTS regime             text,
  ADD COLUMN IF NOT EXISTS dte_now            int,
  ADD COLUMN IF NOT EXISTS degr_excess_pct    numeric,
  ADD COLUMN IF NOT EXISTS degr_factor        numeric,
  ADD COLUMN IF NOT EXISTS est_net_resale_raw numeric,
  ADD COLUMN IF NOT EXISTS net_profit_pct_raw int,
  ADD COLUMN IF NOT EXISTS win_prob_raw       numeric,
  ADD COLUMN IF NOT EXISTS zone_median        numeric,
  ADD COLUMN IF NOT EXISTS zone_n             int,
  ADD COLUMN IF NOT EXISTS vs_zone_pct        int;

COMMENT ON COLUMN public.gotickets_deals_feed.regime IS
  'Event price regime at scan time from the 14d-MA excess over clearing_dte_curve: DUMPING (<=-8) / SOFTENING (<=-3) / RISING (>=+5) / STABLE / UNKNOWN (no history). Written by the prod scanner; recorded in the tree by mig 20260911160300.';
COMMENT ON COLUMN public.gotickets_deals_feed.degr_factor IS
  'Event-specific forward degradation multiplier applied to the realized anchor (Ornstein-Uhlenbeck decay of the MA excess to event day; floor/ceil clamped). 1.0 = no history. Prod scanner; recorded mig 20260911160300.';
COMMENT ON COLUMN public.gotickets_deals_feed.zone_median IS
  'Curated-zone (performer_zones via gt_curated_zone_id) GoTickets median the listing was tested against — the outlier baseline since the 2026-08-19 zone-level directive. zone_n = listings in that zone; vs_zone_pct = price vs zone_median. Recorded mig 20260911160300.';
