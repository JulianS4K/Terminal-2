-- Migration 20260520370000 · lane:A1 · writes:v_sg_blindspot_movers,get_blind_spots_sg_selling · pre:20260520360000
--
-- STEP 3.5 — Blindspot detection with composite 4-signal score
-- (replaces the AND-trigger from mig 20260520360000)
--
-- Operator design (2026-05-18): 4-signal composite score:
--   1. listings shrinking      (listings_pct_delta <= -5% over 48h)
--   2. price rising            (price_pct_delta    >= +10% over 48h)
--   3. sales accelerating      (sales_velocity_pct >= +30% over last 24h vs prior 24h)
--   4. sales clearing-above-ask(sale_vs_listing_pct >= 0%)
--   Surface events with score >= 3 of 4.
--
-- ADDED COLUMNS vs mig 20260520360000:
--   sales_24h_count           DISTINCT sg_sale_id sold in last 24h (per bible §3 dedup)
--   sales_prior_24h_count     DISTINCT sg_sale_id sold 24-48h ago
--   sales_velocity_pct        % delta between the two windows
--   median_sale_24h           median broadcast_price of last 24h sales
--   sale_vs_listing_pct       (median_sale_24h - median_listing_now) / median_listing_now × 100
--   clearing_ratio            sales_24h_count / listings_now
--   signal_listings_drop      bool   (signal 1)
--   signal_price_rise         bool   (signal 2)
--   signal_sales_accel        bool   (signal 3)
--   signal_sales_above_ask    bool   (signal 4)
--   selling_score             int 0-4 (sum of signal_* booleans)
--
-- SALES DEDUP per PROJECT_BIBLE §3 landmine: UNIQUE (sg_event_id, sg_sale_id,
-- pulled_at) means each logical sale re-inserts every poll. Must use
-- DISTINCT ON (sg_sale_id) ORDER BY pulled_at DESC before aggregating.
-- 11-23× overcount otherwise.
--
-- THRESHOLDS — RPC accepts overrides; defaults match the operator design above.

-- ============================================================
-- 1. View (uses correlated-subquery anchors for per-event index lookups)
-- ============================================================
-- The earlier draft used CTE anchors with a captured_at range scan that
-- pulled 640K rows from the firehose. The current shape forces 3,154
-- per-event lookups via idx_sg_listings_sg_event_id_time. ~2.9s on empty
-- baseline (0 rows in the view today); expect similar latency at 1,500-row
-- output. Materializing is a future v2 optimization.
DROP VIEW IF EXISTS public.v_sg_blindspot_movers;

CREATE VIEW public.v_sg_blindspot_movers
WITH (security_invoker = on) AS
WITH blindspot_events AS (
  SELECT sg_event_id FROM public.sg_event_priority_state WHERE tier = 'TRACK_BLINDSPOT'
),
anchors AS (
  SELECT
    e.sg_event_id,
    (SELECT max(l.captured_at) FROM public.seatgeek_listings_snapshots l
     WHERE l.sg_event_id = e.sg_event_id
       AND l.captured_at > now() - interval '12 hours') AS t0_at,
    (SELECT max(l.captured_at) FROM public.seatgeek_listings_snapshots l
     WHERE l.sg_event_id = e.sg_event_id
       AND l.captured_at BETWEEN now() - interval '54 hours' AND now() - interval '42 hours') AS t48_at
  FROM blindspot_events e
),
now_agg AS (
  SELECT l.sg_event_id,
         count(DISTINCT l.sglid)                                                AS listings_now,
         coalesce(sum(l.quantity), 0)                                            AS tickets_now,
         percentile_cont(0.5) WITHIN GROUP (ORDER BY l.broadcast_price)::numeric AS median_now
  FROM public.seatgeek_listings_snapshots l
  JOIN anchors a ON a.sg_event_id = l.sg_event_id AND a.t0_at = l.captured_at
  WHERE a.t0_at IS NOT NULL AND l.broadcast_price IS NOT NULL
  GROUP BY l.sg_event_id
),
prior_agg AS (
  SELECT l.sg_event_id,
         count(DISTINCT l.sglid)                                                AS listings_prior,
         coalesce(sum(l.quantity), 0)                                            AS tickets_prior,
         percentile_cont(0.5) WITHIN GROUP (ORDER BY l.broadcast_price)::numeric AS median_prior
  FROM public.seatgeek_listings_snapshots l
  JOIN anchors a ON a.sg_event_id = l.sg_event_id AND a.t48_at = l.captured_at
  WHERE a.t48_at IS NOT NULL AND l.broadcast_price IS NOT NULL
  GROUP BY l.sg_event_id
),
-- Sales last 24h + prior 24h (both deduped by sg_sale_id per bible §3 landmine)
sales_dedup AS (
  SELECT DISTINCT ON (sg_sale_id)
    sg_event_id, sg_sale_id, sale_at_utc, broadcast_price, quantity
  FROM public.seatgeek_sales_snapshots
  WHERE coalesce(sale_at_utc, pulled_at) > now() - interval '48 hours'
    AND sg_event_id IN (SELECT sg_event_id FROM blindspot_events)
  ORDER BY sg_sale_id, pulled_at DESC
),
sales_24h AS (
  SELECT sg_event_id,
         count(*)                                                               AS sales_24h_count,
         sum(quantity)                                                          AS sales_24h_tickets,
         percentile_cont(0.5) WITHIN GROUP (ORDER BY broadcast_price)::numeric  AS median_sale_24h
  FROM sales_dedup
  WHERE coalesce(sale_at_utc, now()) > now() - interval '24 hours'
  GROUP BY sg_event_id
),
sales_prior_24h AS (
  SELECT sg_event_id,
         count(*) AS sales_prior_24h_count
  FROM sales_dedup
  WHERE coalesce(sale_at_utc, now()) <= now() - interval '24 hours'
    AND coalesce(sale_at_utc, now()) >  now() - interval '48 hours'
  GROUP BY sg_event_id
)
SELECT
  n.sg_event_id,
  -- Listings
  n.listings_now,         p.listings_prior,
  n.tickets_now,          p.tickets_prior,
  n.median_now,           p.median_prior,
  CASE WHEN p.listings_prior > 0
       THEN round(100.0 * (n.listings_now - p.listings_prior) / p.listings_prior::numeric, 2)
       END AS listings_pct_delta,
  CASE WHEN p.median_prior > 0
       THEN round(100.0 * (n.median_now - p.median_prior) / p.median_prior, 2)
       END AS price_pct_delta,
  -- Sales
  coalesce(s24.sales_24h_count, 0)        AS sales_24h_count,
  coalesce(sp.sales_prior_24h_count, 0)   AS sales_prior_24h_count,
  CASE WHEN coalesce(sp.sales_prior_24h_count, 0) > 0
       THEN round(100.0 * (coalesce(s24.sales_24h_count, 0) - sp.sales_prior_24h_count)
                  / sp.sales_prior_24h_count::numeric, 2)
       END AS sales_velocity_pct,
  round(s24.median_sale_24h, 2)           AS median_sale_24h,
  CASE WHEN n.median_now > 0 AND s24.median_sale_24h IS NOT NULL
       THEN round(100.0 * (s24.median_sale_24h - n.median_now) / n.median_now, 2)
       END AS sale_vs_listing_pct,
  CASE WHEN n.listings_now > 0
       THEN round(coalesce(s24.sales_24h_count, 0)::numeric / n.listings_now, 4)
       END AS clearing_ratio,
  -- 4-signal flags (defaults match operator design 2026-05-18)
  (p.listings_prior > 0
   AND 100.0 * (n.listings_now - p.listings_prior) / p.listings_prior::numeric <= -5
  )                                                                            AS signal_listings_drop,
  (p.median_prior > 0
   AND 100.0 * (n.median_now - p.median_prior) / p.median_prior >= 10
  )                                                                            AS signal_price_rise,
  (coalesce(sp.sales_prior_24h_count, 0) > 0
   AND 100.0 * (coalesce(s24.sales_24h_count, 0) - sp.sales_prior_24h_count)
       / sp.sales_prior_24h_count::numeric >= 30
  )                                                                            AS signal_sales_accel,
  (n.median_now > 0 AND s24.median_sale_24h IS NOT NULL
   AND s24.median_sale_24h >= n.median_now
  )                                                                            AS signal_sales_above_ask,
  -- Composite 0-4 score
  (
    (p.listings_prior > 0
     AND 100.0 * (n.listings_now - p.listings_prior) / p.listings_prior::numeric <= -5)::int +
    (p.median_prior > 0
     AND 100.0 * (n.median_now - p.median_prior) / p.median_prior >= 10)::int +
    (coalesce(sp.sales_prior_24h_count, 0) > 0
     AND 100.0 * (coalesce(s24.sales_24h_count, 0) - sp.sales_prior_24h_count)
         / sp.sales_prior_24h_count::numeric >= 30)::int +
    (n.median_now > 0 AND s24.median_sale_24h IS NOT NULL
     AND s24.median_sale_24h >= n.median_now)::int
  ) AS selling_score,
  -- Original directional flag retained for back-compat / panel UI
  (n.listings_now < p.listings_prior AND n.median_now > p.median_prior) AS selling_pressure
FROM now_agg n
JOIN prior_agg p USING (sg_event_id)
LEFT JOIN sales_24h       s24 USING (sg_event_id)
LEFT JOIN sales_prior_24h sp  USING (sg_event_id)
WHERE p.listings_prior > 0 AND p.median_prior > 0;

REVOKE ALL ON public.v_sg_blindspot_movers FROM PUBLIC;
GRANT SELECT ON public.v_sg_blindspot_movers TO anon, authenticated, service_role;


-- ============================================================
-- 2. RPC (score-based filter, threshold-tunable)
-- ============================================================
CREATE OR REPLACE FUNCTION public.get_blind_spots_sg_selling(
  p_min_score int DEFAULT 3
)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, extensions, pg_temp
AS $func$
DECLARE
  v_email text;
BEGIN
  v_email := coalesce(auth.jwt()->>'email', '');
  IF v_email NOT LIKE '%@s4kent.com' THEN
    RAISE EXCEPTION 'forbidden: % is not an @s4kent.com email', v_email USING ERRCODE = '42501';
  END IF;

  RETURN coalesce((
    SELECT jsonb_agg(jsonb_build_object(
             'sg_event_id',          m.sg_event_id,
             'tevo_event_id',        c.tevo_event_id,
             'sg_event_name',        c.sg_event_name,
             'sg_venue_name',        c.sg_venue_name,
             'sg_venue_city',        c.sg_venue_city,
             'sg_venue_state',       c.sg_venue_state,
             'sg_datetime_utc',      to_char(c.sg_datetime_utc AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
             -- Listings half
             'listings_now',         m.listings_now,
             'listings_prior',       m.listings_prior,
             'listings_pct_delta',   m.listings_pct_delta,
             'median_now',           round(m.median_now, 2),
             'median_prior',         round(m.median_prior, 2),
             'price_pct_delta',      m.price_pct_delta,
             -- Sales half
             'sales_24h_count',      m.sales_24h_count,
             'sales_prior_24h_count',m.sales_prior_24h_count,
             'sales_velocity_pct',   m.sales_velocity_pct,
             'median_sale_24h',      m.median_sale_24h,
             'sale_vs_listing_pct',  m.sale_vs_listing_pct,
             'clearing_ratio',       m.clearing_ratio,
             -- Signal flags + score
             'signal_listings_drop',    m.signal_listings_drop,
             'signal_price_rise',       m.signal_price_rise,
             'signal_sales_accel',      m.signal_sales_accel,
             'signal_sales_above_ask',  m.signal_sales_above_ask,
             'selling_score',           m.selling_score,
             'selling_pressure',        m.selling_pressure
           ) ORDER BY m.selling_score DESC,
                     coalesce(m.sales_velocity_pct, 0) DESC,
                     abs(coalesce(m.price_pct_delta, 0)) DESC)
    FROM public.v_sg_blindspot_movers m
    JOIN public.sg_events_canonical c ON c.sg_event_id = m.sg_event_id
    WHERE m.selling_score >= p_min_score
      AND c.sg_datetime_utc > now()
  ), '[]'::jsonb);
END
$func$;

REVOKE ALL    ON FUNCTION public.get_blind_spots_sg_selling(int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_blind_spots_sg_selling(int) TO anon, authenticated;

-- Drop the prior 2-numeric-arg overload from mig 20260520360000 (per
-- PROJECT_BIBLE §7 function-signature landmine: CREATE OR REPLACE with a
-- different signature creates an additional overload, not a replacement).
DROP FUNCTION IF EXISTS public.get_blind_spots_sg_selling(numeric, numeric);

COMMENT ON FUNCTION public.get_blind_spots_sg_selling(int) IS
  'BLIND SPOTS — SG SELLING, WE''RE NOT. Composite 4-signal score:
     1. listings shrinking      >= 5% over 48h
     2. price rising            >= 10% over 48h
     3. sales accelerating      >= 30% velocity (last 24h vs prior 24h)
     4. sales clearing at/above current ask
   Default surface threshold: score >= 3. Sorted by score DESC, sales_velocity_pct DESC, |price_pct_delta| DESC. Email-gated.';

-- ============================================================
-- Post-apply verification
-- ============================================================
-- 1) View resolves with new columns (returns 0 rows today — no 48h history)
--    \\d+ public.v_sg_blindspot_movers
--    SELECT count(*) FROM public.v_sg_blindspot_movers;
--
-- 2) RPC overload cleanup confirmed (only 1 row):
--    SELECT pg_get_function_identity_arguments(p.oid)
--    FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
--    WHERE n.nspname='public' AND p.proname='get_blind_spots_sg_selling';
--
-- 3) RPC w/ faked @s4kent.com JWT, default score >= 3:
--    SELECT set_config('request.jwt.claims', '{"email":"test@s4kent.com"}', true);
--    SELECT public.get_blind_spots_sg_selling();    -- expect '[]'
--    SELECT public.get_blind_spots_sg_selling(0);   -- expect '[]' (no 48h data)
