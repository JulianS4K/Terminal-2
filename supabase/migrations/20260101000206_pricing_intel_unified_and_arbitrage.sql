-- ============================================================================
-- Migration 20260509380000 — Unified pricing intelligence + arbitrage view
--
-- Per directive: "5 should already exist for each data source need to
-- connect, do 6-7" — this migration UNIFIES the per-source pricing
-- intelligence we already have, then adds the cross-source arbitrage view.
--
-- WHAT EXISTS PER-SOURCE (ALREADY):
--   TEvo:   latest_event_metrics (event-level), section_metrics, zone_metrics,
--           event_velocity (vs immediately-prior capture)
--   SG:     seatgeek_event_metrics (494 rows; cost percentiles, orders by
--           status, sold quantity, fill_rate)
--   SD:     seatdata_event_stats (snapshot ts, get_in, total_listings, etc.)
--   Cross:  v_pricing_cross_source (section-level TEvo↔SG↔SD)
--
-- WHAT THIS ADDS:
--   v_event_velocity_windows — 1h/6h/24h price + inventory deltas, PER source
--                              (not just "vs previous capture")
--   v_arbitrage_opportunities — section-level TEvo↔SG price gap > threshold
-- ============================================================================

-- ============================================================================
-- (1) Unified velocity windows
--
-- Computes Δ price + Δ tickets over 1h / 6h / 24h windows for both TEvo and
-- SG event-level metrics. This is what a day-trader actually wants to read
-- ("what moved in the last hour"), not "vs whatever the previous capture
-- was, which could be 5 min ago or 12 hours ago."
-- ============================================================================

CREATE OR REPLACE VIEW v_event_velocity_windows AS
WITH tevo_now AS (
  SELECT DISTINCT ON (event_id)
    event_id, captured_at, getin_price, retail_median, tickets_count
  FROM latest_event_metrics
  ORDER BY event_id, captured_at DESC
),
tevo_lookback AS (
  SELECT
    event_id, captured_at, getin_price, retail_median, tickets_count,
    LAG(getin_price)    OVER (PARTITION BY event_id ORDER BY captured_at) AS prev_getin,
    LAG(retail_median)  OVER (PARTITION BY event_id ORDER BY captured_at) AS prev_median,
    LAG(tickets_count)  OVER (PARTITION BY event_id ORDER BY captured_at) AS prev_tickets
  FROM event_metrics
),
tevo_w AS (
  SELECT
    n.event_id,
    n.captured_at AS tevo_now_at, n.getin_price AS tevo_getin_now,
    n.retail_median AS tevo_median_now, n.tickets_count AS tevo_tix_now,
    -- 1h window
    (SELECT getin_price FROM event_metrics em
      WHERE em.event_id = n.event_id AND em.captured_at <= n.captured_at - interval '1 hour'
      ORDER BY em.captured_at DESC LIMIT 1) AS tevo_getin_1h_ago,
    (SELECT tickets_count FROM event_metrics em
      WHERE em.event_id = n.event_id AND em.captured_at <= n.captured_at - interval '1 hour'
      ORDER BY em.captured_at DESC LIMIT 1) AS tevo_tix_1h_ago,
    -- 6h window
    (SELECT getin_price FROM event_metrics em
      WHERE em.event_id = n.event_id AND em.captured_at <= n.captured_at - interval '6 hours'
      ORDER BY em.captured_at DESC LIMIT 1) AS tevo_getin_6h_ago,
    (SELECT tickets_count FROM event_metrics em
      WHERE em.event_id = n.event_id AND em.captured_at <= n.captured_at - interval '6 hours'
      ORDER BY em.captured_at DESC LIMIT 1) AS tevo_tix_6h_ago,
    -- 24h window
    (SELECT getin_price FROM event_metrics em
      WHERE em.event_id = n.event_id AND em.captured_at <= n.captured_at - interval '24 hours'
      ORDER BY em.captured_at DESC LIMIT 1) AS tevo_getin_24h_ago,
    (SELECT tickets_count FROM event_metrics em
      WHERE em.event_id = n.event_id AND em.captured_at <= n.captured_at - interval '24 hours'
      ORDER BY em.captured_at DESC LIMIT 1) AS tevo_tix_24h_ago
  FROM tevo_now n
),
sg_w AS (
  SELECT
    sgm.tevo_event_id AS event_id,
    sgm.captured_at AS sg_now_at,
    sgm.cost_min AS sg_getin_now,
    sgm.cost_median AS sg_median_now,
    sgm.tickets_count AS sg_tix_now,
    (SELECT cost_min FROM seatgeek_event_metrics x
      WHERE x.tevo_event_id = sgm.tevo_event_id AND x.captured_at <= sgm.captured_at - interval '1 hour'
      ORDER BY x.captured_at DESC LIMIT 1) AS sg_getin_1h_ago,
    (SELECT cost_min FROM seatgeek_event_metrics x
      WHERE x.tevo_event_id = sgm.tevo_event_id AND x.captured_at <= sgm.captured_at - interval '6 hours'
      ORDER BY x.captured_at DESC LIMIT 1) AS sg_getin_6h_ago,
    (SELECT cost_min FROM seatgeek_event_metrics x
      WHERE x.tevo_event_id = sgm.tevo_event_id AND x.captured_at <= sgm.captured_at - interval '24 hours'
      ORDER BY x.captured_at DESC LIMIT 1) AS sg_getin_24h_ago
  FROM (SELECT DISTINCT ON (tevo_event_id) * FROM seatgeek_event_metrics
        WHERE tevo_event_id IS NOT NULL ORDER BY tevo_event_id, captured_at DESC) sgm
)
SELECT
  e.id AS tevo_event_id, e.name, e.occurs_at_local, e.venue_name,
  -- TEvo
  t.tevo_now_at, t.tevo_getin_now, t.tevo_median_now, t.tevo_tix_now,
  (t.tevo_getin_now - t.tevo_getin_1h_ago)  AS tevo_getin_d1h,
  (t.tevo_getin_now - t.tevo_getin_6h_ago)  AS tevo_getin_d6h,
  (t.tevo_getin_now - t.tevo_getin_24h_ago) AS tevo_getin_d24h,
  (t.tevo_tix_now   - t.tevo_tix_1h_ago)    AS tevo_tix_d1h,
  (t.tevo_tix_now   - t.tevo_tix_24h_ago)   AS tevo_tix_d24h,
  CASE WHEN t.tevo_getin_1h_ago > 0
    THEN round(((t.tevo_getin_now - t.tevo_getin_1h_ago)::numeric / t.tevo_getin_1h_ago) * 100, 2)
    END AS tevo_getin_d1h_pct,
  CASE WHEN t.tevo_getin_24h_ago > 0
    THEN round(((t.tevo_getin_now - t.tevo_getin_24h_ago)::numeric / t.tevo_getin_24h_ago) * 100, 2)
    END AS tevo_getin_d24h_pct,
  -- SG
  s.sg_now_at, s.sg_getin_now, s.sg_median_now, s.sg_tix_now,
  (s.sg_getin_now - s.sg_getin_1h_ago)  AS sg_getin_d1h,
  (s.sg_getin_now - s.sg_getin_24h_ago) AS sg_getin_d24h
FROM events e
LEFT JOIN tevo_w t ON t.event_id = e.id
LEFT JOIN sg_w   s ON s.event_id = e.id
WHERE t.event_id IS NOT NULL OR s.event_id IS NOT NULL;

COMMENT ON VIEW v_event_velocity_windows IS
  'Multi-window velocity per event across TEvo + SG. Windows: 1h, 6h, 24h. '
  'Read tevo_getin_d1h_pct < -10 to find "get-in dropped >10% in last hour". '
  'NULL fields mean we do not have a snapshot in that window yet.';

-- ============================================================================
-- (2) Arbitrage opportunities (section-level TEvo↔SG)
-- ============================================================================

CREATE OR REPLACE VIEW v_arbitrage_opportunities AS
SELECT
  tevo_event_id,
  section,
  tevo_retail_median,
  sg_retail_median,
  sg_seller_cost_median,
  -- TEvo retail vs SG retail (consumer-side gap)
  (sg_retail_median - tevo_retail_median) AS sg_minus_tevo,
  CASE WHEN tevo_retail_median > 0
    THEN round(((sg_retail_median - tevo_retail_median) / tevo_retail_median * 100)::numeric, 2)
    END AS sg_vs_tevo_gap_pct,
  -- Buy-on-SG-sell-on-TEvo arb (rough; ignores fees this calc, see fee schedule)
  CASE WHEN sg_seller_cost_median > 0 AND tevo_retail_median > 0
    THEN round(((tevo_retail_median - sg_seller_cost_median) / sg_seller_cost_median * 100)::numeric, 2)
    END AS our_cost_vs_tevo_retail_pct,
  tevo_listings, sg_listings, sg_seller_listings,
  GREATEST(tevo_latest, sg_latest) AS data_freshness
FROM v_pricing_cross_source
WHERE tevo_retail_median IS NOT NULL
  AND sg_retail_median   IS NOT NULL
  AND tevo_listings >= 2 AND sg_listings >= 2;     -- need depth on both sides

COMMENT ON VIEW v_arbitrage_opportunities IS
  'Section-level pricing gaps between TEvo and SG. Filtered to sections with '
  '>=2 listings on each side for noise reduction. sg_vs_tevo_gap_pct positive '
  '= SG more expensive (sell on SG, buy on TEvo). Negative = inverse. '
  'our_cost_vs_tevo_retail_pct is a simple buy-on-SG-cost / sell-on-TEvo '
  'spread — apply order_fee_schedule before treating as net profit.';
