-- Migration 20260519180000 · lane:A1 · writes:v_tevo_blindspot_movers,get_blind_spots_tevo_selling · pre:20260520370000
--
-- TEvo blindspot detection — companion to SG blindspot system (mig 20260520370000).
--
-- DIFFERENCE FROM SG VERSION (operator design 2026-05-19):
--   * No tier table. SG's TRACK_BLINDSPOT exists because each SG poll burns
--     one of the 10/sec quota, so we tier-classify what's worth polling.
--     TEvo's /v9/events search is broker-side, higher-quota, and supports
--     filtered discovery on demand. Events worth investigating can be pulled
--     ad-hoc via the existing `sg_to_tevo_search_bridge` pattern.
--   * No sales signals. TEvo doesn't expose broker-side sales data — we only
--     see listing-side movement (broker-pool tickets disappearing) +
--     get-in price firming. Composite score drops from 4 signals (SG)
--     to 2 signals (TEvo).
--   * Scope is naturally NYC-first since that's the storefront focus, but
--     RPC accepts a location filter for future expansion.
--
-- DETECTION GATES:
--   * owned_tickets_count = 0       (the "blindspot" — we don't own any)
--   * tickets_count >= 10            (real broker-market depth)
--   * occurs_at in [today, +90d]    (forward-looking only)
--   * event_lifecycle is_active     (drop ghost/cancelled)
--   * velocity_fresh                 (tevo_now_at within 3h — §9 cadence gap landmine)
--
-- COMPOSITE 2-SIGNAL SCORE:
--   signal_listings_drop  tevo_tix_d24h <= -10   (≥10 tix disappeared from broker pool)
--   signal_price_rise     tevo_getin_d24h_pct >= +5%
--   Surface events where BOTH fire (score=2). Score=1 (one-sided) returned
--   in view but the default RPC threshold returns only score=2 events.
--
-- WHY THRESHOLDS DIFFER FROM SG:
--   SG composite uses 5% / 10% / 30% / 0%. Tighter because SG firehose is
--   noisier (consumer marketplace, more listing churn). TEvo broker pool is
--   stickier — a 10-ticket drop + 5% getin rise is meaningful.
--
-- ============================================================
-- 1. View — per-event composite score (anchored to latest_event_metrics +
--    v_event_velocity_windows). Reads are cheap because both upstream
--    matviews/views are already pre-aggregated.
-- ============================================================
DROP VIEW IF EXISTS public.v_tevo_blindspot_movers;

CREATE VIEW public.v_tevo_blindspot_movers
WITH (security_invoker = on) AS
WITH base AS (
  SELECT
    e.id                       AS tevo_event_id,
    e.name                     AS event_name,
    e.occurs_at_local,
    e.venue_id,
    e.venue_name,
    e.venue_location,
    e.primary_performer_id,
    e.primary_performer_name,
    lem.owned_tickets_count,
    lem.tickets_count,
    lem.retail_min,
    lem.retail_median,
    lem.captured_at            AS metrics_captured_at
  FROM public.events e
  JOIN public.latest_event_metrics lem ON lem.event_id = e.id
  LEFT JOIN public.event_lifecycle el  ON el.event_id = e.id
  WHERE e.occurs_at_local::date >= CURRENT_DATE
    AND e.occurs_at_local::date <= CURRENT_DATE + interval '90 days'
    AND lem.owned_tickets_count = 0          -- blindspot: we own nothing
    AND lem.tickets_count >= 10              -- real broker depth
    AND (el.is_active IS NULL OR el.is_active = true)
    -- Drop speculative names (mirrors storefront filter)
    AND e.name NOT ILIKE '%CANCELLED%'
    AND e.name NOT ILIKE '%(If Necessary)%'
    AND e.name NOT ILIKE '%(Date TBD)%'
),
velocity AS (
  SELECT
    tevo_event_id,
    tevo_tix_d24h,
    tevo_getin_d24h_pct,
    tevo_getin_now,
    tevo_median_now,
    tevo_now_at,
    -- Freshness gate: cadence gap (collect-listings 1-7d, 60d+) can leave
    -- d24h subqueries falling back to the same ancient sample, making
    -- d24h = 0 misleadingly. Treat stale rows as no-signal. §9 landmine.
    (tevo_now_at IS NOT NULL AND tevo_now_at > now() - interval '3 hours') AS velocity_fresh
  FROM public.v_event_velocity_windows
),
scored AS (
  SELECT
    b.*,
    v.tevo_tix_d24h,
    v.tevo_getin_d24h_pct,
    v.tevo_getin_now,
    v.tevo_median_now,
    v.tevo_now_at,
    v.velocity_fresh,
    (v.velocity_fresh AND v.tevo_tix_d24h IS NOT NULL
     AND v.tevo_tix_d24h <= -10)                                                 AS signal_listings_drop,
    (v.velocity_fresh AND v.tevo_getin_d24h_pct IS NOT NULL
     AND v.tevo_getin_d24h_pct >= 5.0)                                           AS signal_price_rise
  FROM base b
  LEFT JOIN velocity v ON v.tevo_event_id = b.tevo_event_id
)
SELECT
  *,
  (signal_listings_drop::int + signal_price_rise::int) AS selling_score
FROM scored
WHERE velocity_fresh
  AND (signal_listings_drop OR signal_price_rise);

COMMENT ON VIEW public.v_tevo_blindspot_movers IS
  'TEvo blindspot mover candidates: events where we own 0 tickets but
   broker-pool listings are shrinking and/or get-in price is firming.
   2-signal composite (no sales data on TEvo broker side). Owned >0 events
   live in `latest_event_metrics` direct — this view targets the inverse.
   Companion to v_sg_blindspot_movers (mig 20260520370000) which uses a
   4-signal composite on SG data.';

REVOKE ALL ON public.v_tevo_blindspot_movers FROM PUBLIC;
GRANT SELECT ON public.v_tevo_blindspot_movers TO anon, authenticated, service_role;

-- ============================================================
-- 2. RPC — caller-facing wrapper. Returns JSON array sorted by score DESC,
--    then by velocity magnitude. Email-gated per §6 caller guard.
-- ============================================================
CREATE OR REPLACE FUNCTION public.get_blind_spots_tevo_selling(
  p_min_score int       DEFAULT 2,    -- 2 = both signals fire; 1 = either
  p_horizon_days int    DEFAULT 90,
  p_limit int           DEFAULT 25,
  p_venue_pattern text  DEFAULT NULL  -- e.g. '%New York%' to scope to NYC
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
  v_email text;
  v_result jsonb;
BEGIN
  -- §6 caller guard — email-required
  v_email := nullif((select auth.jwt())->>'email', '');
  IF v_email IS NULL THEN
    RAISE EXCEPTION 'email required' USING errcode = '42501';
  END IF;

  SELECT coalesce(jsonb_agg(row_to_json(m) ORDER BY m.selling_score DESC,
                                              abs(coalesce(m.tevo_tix_d24h, 0)) DESC,
                                              m.occurs_at_local ASC), '[]'::jsonb)
    INTO v_result
  FROM (
    SELECT
      tevo_event_id,
      event_name,
      occurs_at_local,
      venue_id,
      venue_name,
      venue_location,
      primary_performer_id,
      primary_performer_name,
      tickets_count,
      retail_min,
      retail_median,
      tevo_tix_d24h,
      tevo_getin_d24h_pct,
      tevo_getin_now,
      tevo_median_now,
      signal_listings_drop,
      signal_price_rise,
      selling_score
    FROM public.v_tevo_blindspot_movers
    WHERE selling_score >= p_min_score
      AND occurs_at_local::date <= CURRENT_DATE + (p_horizon_days || ' days')::interval
      AND (p_venue_pattern IS NULL OR venue_location ILIKE p_venue_pattern)
    LIMIT p_limit
  ) m;

  RETURN v_result;
END;
$$;

REVOKE ALL    ON FUNCTION public.get_blind_spots_tevo_selling(int, int, int, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_blind_spots_tevo_selling(int, int, int, text) TO anon, authenticated;

COMMENT ON FUNCTION public.get_blind_spots_tevo_selling(int, int, int, text) IS
  'BLIND SPOTS — TEvo SELLING, WE''RE NOT. 2-signal composite over broker
   pool (no sales data on TEvo broker side). Signals: listings shrinking
   (d24h ≤ -10) + get-in price rising (≥ +5%). Default min_score=2 returns
   only events where both signals fire. p_venue_pattern accepts ILIKE
   wildcards for geo scoping. Companion to get_blind_spots_sg_selling().';

-- ============================================================
-- VERIFICATION (operator runs after apply):
--
--   -- 1. View populated count + signal distribution
--   SELECT count(*),
--          count(*) FILTER (WHERE selling_score=2) AS both_signals,
--          count(*) FILTER (WHERE selling_score=1) AS one_signal
--   FROM public.v_tevo_blindspot_movers;
--
--   -- 2. RPC smoke (run as authenticated user with email JWT)
--   SELECT public.get_blind_spots_tevo_selling();      -- default: min_score=2, 90d, top 25
--   SELECT public.get_blind_spots_tevo_selling(1);     -- one-signal min, more results
--   SELECT public.get_blind_spots_tevo_selling(2, 90, 10, '%New York%');  -- NYC only
--
--   -- 3. Spot-check: every result must have owned_tickets_count = 0 in
--   --    the source latest_event_metrics row
--   WITH r AS (
--     SELECT (jsonb_array_elements(public.get_blind_spots_tevo_selling())->>'tevo_event_id')::bigint AS eid
--   )
--   SELECT count(*) FILTER (WHERE lem.owned_tickets_count = 0) AS clean,
--          count(*)                                            AS total
--   FROM r JOIN public.latest_event_metrics lem ON lem.event_id = r.eid;
--   -- Expect clean == total.
-- ============================================================
