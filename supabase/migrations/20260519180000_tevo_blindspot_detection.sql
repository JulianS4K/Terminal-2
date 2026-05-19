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
--
-- CANDIDATE GATES (operator-confirmed 2026-05-19):
--   * owned_tickets_count = 0           — the blindspot
--   * tickets_count       >= 25          — real broker market depth
--   * occurs_at in [today+31d, today+365d] — drop game-time noise + open
--     the upper bound to 1 year (was 90d in v1; widened per operator
--     2026-05-19 — longer-horizon inventory is sourcing-actionable too)
--   * US or Canada venue                 — state/province regex match on
--     `events.venue_location` (e.g. "Boston, MA" / "Toronto, ON")
--   * get-in-without-parking >= $50      — recomputed from
--     `listings_snapshots.retail_price` excluding sections matching
--     `%park%|%lot%|%garage%|%valet%`. TEvo bible §3 landmine: parking
--     rows fold into the main listing pool, dragging native `getin_now`
--     down artificially.
--   * event_lifecycle.is_active          — drops ghost/cancelled/postponed
--   * speculative-name filter             — CANCELLED / If Necessary /
--                                            Date TBD
--
-- COMPOSITE 2-SIGNAL SCORE:
--   signal_listings_drop  tevo_tix_d24h <= -10   (≥10 tix gone in 24h)
--   signal_price_rise     tevo_getin_d24h_pct >= +5%
--   selling_score         sum of the two booleans (0..2)
--   Default RPC threshold: min_score=2 (both fire). min_score=1 for the
--   exploratory mode (one-sided).
--
-- WHY THRESHOLDS DIFFER FROM SG:
--   SG composite uses 5% / 10% / 30% / 0%. Tighter because SG firehose is
--   noisier (consumer marketplace, more listing churn). TEvo broker pool is
--   stickier — a 10-ticket drop + 5% getin rise is meaningful.

-- ============================================================
-- 1. View — per-event composite score
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
    lem.captured_at            AS metrics_captured_at,
    -- Get-in without parking — recomputed from raw listings_snapshots
    -- so the parking-section drag (bible §3 landmine) is excluded.
    -- Correlated subquery on PRIMARY KEY (event_id) — fast.
    (SELECT min(ls.retail_price)
       FROM public.listings_snapshots ls
      WHERE ls.event_id = e.id
        AND ls.retail_price IS NOT NULL
        AND NOT (
          ls.section ILIKE '%park%' OR ls.section ILIKE '%lot%'
          OR ls.section ILIKE '%garage%' OR ls.section ILIKE '%valet%'
        )
    )                          AS getin_no_parking
  FROM public.events e
  JOIN public.latest_event_metrics lem ON lem.event_id = e.id
  LEFT JOIN public.event_lifecycle el  ON el.event_id = e.id
  WHERE
    -- Forward window: 31..365 days out (drop game-time, allow long horizon)
    e.occurs_at_local::date >= CURRENT_DATE + interval '31 days'
    AND e.occurs_at_local::date <= CURRENT_DATE + interval '365 days'
    -- Blindspot: we own nothing
    AND lem.owned_tickets_count = 0
    -- Real market depth
    AND lem.tickets_count >= 25
    -- Active lifecycle
    AND (el.is_active IS NULL OR el.is_active = true)
    -- Speculative-name filter (mirrors storefront)
    AND e.name NOT ILIKE '%CANCELLED%'
    AND e.name NOT ILIKE '%(If Necessary)%'
    AND e.name NOT ILIKE '%(Date TBD)%'
    -- US or Canada only (state/province at end of venue_location string)
    AND (
      e.venue_location ~ ',\s*(AL|AK|AZ|AR|CA|CO|CT|DE|FL|GA|HI|ID|IL|IN|IA|KS|KY|LA|ME|MD|MA|MI|MN|MS|MO|MT|NE|NV|NH|NJ|NM|NY|NC|ND|OH|OK|OR|PA|RI|SC|SD|TN|TX|UT|VT|VA|WA|WV|WI|WY|DC)\s*$'
      OR e.venue_location ~ ',\s*(AB|BC|MB|NB|NL|NS|ON|PE|QC|SK|YT|NT|NU)\s*$'
    )
),
gated AS (
  -- Apply the parking-aware get-in floor in a second pass so the IS NOT NULL
  -- + threshold gate sit together (clearer than a CASE in the base WHERE).
  SELECT * FROM base
  WHERE getin_no_parking IS NOT NULL
    AND getin_no_parking >= 50
),
velocity AS (
  SELECT
    tevo_event_id,
    tevo_tix_d24h,
    tevo_getin_d24h_pct,
    tevo_getin_now,
    tevo_median_now,
    tevo_now_at,
    -- Freshness gate: cadence-gap landmine (collect-listings 1-7d / 60d+
    -- can leave d24h subqueries falling back to ancient samples). Treat
    -- stale rows as no-signal.
    (tevo_now_at IS NOT NULL AND tevo_now_at > now() - interval '3 hours') AS velocity_fresh
  FROM public.v_event_velocity_windows
),
scored AS (
  SELECT
    g.*,
    v.tevo_tix_d24h,
    v.tevo_getin_d24h_pct,
    v.tevo_getin_now,
    v.tevo_median_now,
    v.tevo_now_at,
    v.velocity_fresh,
    (v.velocity_fresh AND v.tevo_tix_d24h IS NOT NULL
     AND v.tevo_tix_d24h <= -10)                                              AS signal_listings_drop,
    (v.velocity_fresh AND v.tevo_getin_d24h_pct IS NOT NULL
     AND v.tevo_getin_d24h_pct >= 5.0)                                        AS signal_price_rise
  FROM gated g
  LEFT JOIN velocity v ON v.tevo_event_id = g.tevo_event_id
)
SELECT
  *,
  (signal_listings_drop::int + signal_price_rise::int) AS selling_score
FROM scored
WHERE velocity_fresh
  AND (signal_listings_drop OR signal_price_rise);

COMMENT ON VIEW public.v_tevo_blindspot_movers IS
  'TEvo blindspot mover candidates: US/CA events 31-365d out where we own 0
   tickets, broker pool has >=25 listings, parking-aware get-in >= $50, and
   the pool is showing demand signals (listings shrinking and/or get-in
   firming). 2-signal composite (no sales data on TEvo broker side).
   Companion to v_sg_blindspot_movers (mig 20260520370000) which uses a
   4-signal composite on SG data.';

REVOKE ALL ON public.v_tevo_blindspot_movers FROM PUBLIC;
GRANT SELECT ON public.v_tevo_blindspot_movers TO anon, authenticated, service_role;

-- ============================================================
-- 2. RPC — caller-facing wrapper. Returns JSON array sorted by score DESC,
--    then by velocity magnitude. Email-gated per §6 caller guard.
-- ============================================================
DROP FUNCTION IF EXISTS public.get_blind_spots_tevo_selling(int, int, int, text);

CREATE OR REPLACE FUNCTION public.get_blind_spots_tevo_selling(
  p_min_score int       DEFAULT 2,    -- 2 = both signals fire; 1 = either
  p_horizon_days int    DEFAULT 365,  -- view caps at 365d; callers can tighten
  p_limit int           DEFAULT 25,
  p_venue_pattern text  DEFAULT NULL  -- e.g. '%New York%' to narrow within US/CA
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
      getin_no_parking,
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
   pool (no sales data on TEvo broker side). Candidate gates: owned=0,
   tickets>=25, 31-365d out, US/CA venue, parking-aware get-in >= $50.
   Signals: listings shrinking (d24h <= -10) + get-in rising (>= +5%).
   Default min_score=2 = both signals. p_venue_pattern accepts ILIKE
   wildcards for narrower geo scoping within US/CA. Companion to
   get_blind_spots_sg_selling().';

-- ============================================================
-- VERIFICATION (operator runs after apply):
--
--   -- 1. View population
--   SELECT count(*) AS total,
--          count(*) FILTER (WHERE selling_score=2) AS both_signals,
--          count(*) FILTER (WHERE selling_score=1) AS one_signal,
--          round(avg(getin_no_parking)::numeric, 0) AS avg_getin
--   FROM public.v_tevo_blindspot_movers;
--   -- Baseline pool (any signal): ~34+ events expected (34 measured
--   -- 2026-05-19 with 31-365d window, before velocity scoring layered on)
--
--   -- 2. RPC smoke (as authenticated user with email JWT)
--   SELECT public.get_blind_spots_tevo_selling();             -- defaults
--   SELECT public.get_blind_spots_tevo_selling(1);            -- one-signal min
--   SELECT public.get_blind_spots_tevo_selling(2, 90, 10, '%New York%');
--
--   -- 3. Spot-check gates
--   SELECT count(*) AS leaks
--   FROM public.v_tevo_blindspot_movers
--   WHERE getin_no_parking < 50
--      OR tickets_count < 25
--      OR owned_tickets_count <> 0
--      OR occurs_at_local::date < CURRENT_DATE + interval '31 days'
--      OR occurs_at_local::date > CURRENT_DATE + interval '365 days';
--   -- Expect 0.
-- ============================================================
