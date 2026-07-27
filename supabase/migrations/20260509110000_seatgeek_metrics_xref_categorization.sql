-- SeatGeek metrics, performer/venue xref re-introduction (now driven by
-- inline metadata from seller_listings + orders, not by manual matching),
-- listings categorization view, cascade-friendly backfill function.
-- Applied to prod 2026-05-09 ~03:30 UTC.
--
-- Why: with /listings + /orders dropping rich event/performer/venue
-- metadata on every row, we can derive xrefs and metrics WITHOUT calling
-- any extra SG endpoints. This migration adds:
--
--   1. seatgeek_performer_xref / seatgeek_venue_xref (lighter than the v13
--      versions — just enough fields to bridge to TEvo and ESPN)
--   2. seatgeek_event_metrics — parallel to event_metrics (TEvo) and
--      seatdata_event_stats. Aggregates over our SG seller listings +
--      orders per (tevo_event_id, captured_at).
--   3. seatgeek_categorized_listings VIEW — flattens active listings by
--      (sg_performer_name, sg_venue) so we can render "all events for
--      Performer X at Venue Y" without joining a dozen tables.
--   4. Functions:
--      - auto_xref_sg_performers_from_listings() — extract distinct
--        performer names from seller_listings, fuzzy-match to TEvo
--        primary_performer_name, upsert seatgeek_performer_xref.
--      - auto_xref_sg_venues_from_listings() — same for venues.
--      - compute_seatgeek_event_metrics(tevo_event_id) — one tevo event,
--        one metric row.
--      - backfill_seatgeek_event_metrics(max_events) — cron-friendly
--        batched recompute. Returns updated_count.
--
-- READ-ONLY enforcement (RULE 2): SeatGeek + SeatData + TEvo external
-- writes are forbidden. We never POST/PUT/DELETE to api.ticketevolution.com,
-- brokerdata.seatgeek.com, sellerdirect-api.seatgeek.com, or any partner
-- API. The clients hardcode a method allowlist; this is also documented
-- in SCHEMA.md as RULE 2.
--
-- Wall reminder: SG seller-direct data (listings + orders) is broker-only.
-- Order tickets contain barcodes — strict broker scope.

BEGIN;

-- ============================================================
-- A. SeatGeek performer + venue xref (lighter, re-introduced)
-- ============================================================

CREATE TABLE IF NOT EXISTS seatgeek_performer_xref (
  tevo_performer_id  bigint PRIMARY KEY,
  sg_performer_name  text NOT NULL,
  -- ESPN is a hub but we let TEvo be primary; ESPN id is reachable via
  -- performer_external_ids(performer_id, source='espn').
  match_method       text NOT NULL DEFAULT 'auto_listing',  -- auto_listing | manual
  match_confidence   numeric,
  matched_at         timestamptz NOT NULL DEFAULT NOW(),
  meta               jsonb DEFAULT '{}'::jsonb
);
CREATE INDEX IF NOT EXISTS idx_sg_perfxref_name ON seatgeek_performer_xref(sg_performer_name);

CREATE TABLE IF NOT EXISTS seatgeek_venue_xref (
  tevo_venue_id      bigint PRIMARY KEY,
  sg_venue_name      text NOT NULL,
  match_method       text NOT NULL DEFAULT 'auto_listing',
  match_confidence   numeric,
  matched_at         timestamptz NOT NULL DEFAULT NOW(),
  meta               jsonb DEFAULT '{}'::jsonb
);
CREATE INDEX IF NOT EXISTS idx_sg_venuexref_name ON seatgeek_venue_xref(sg_venue_name);

-- ============================================================
-- B. SeatGeek event metrics (parallel to event_metrics, seatdata_event_stats)
-- ============================================================

CREATE TABLE IF NOT EXISTS seatgeek_event_metrics (
  id                bigserial PRIMARY KEY,
  tevo_event_id     bigint NOT NULL,
  sg_event_id       bigint,                  -- denormalized for convenience
  captured_at       timestamptz NOT NULL DEFAULT NOW(),
  -- Listings-side aggregates (from seatgeek_seller_listings)
  listings_count        int,
  tickets_count         int,                 -- sum(quantity) across listings
  cost_min              numeric,             -- our wholesale cost
  cost_p25              numeric,
  cost_median           numeric,
  cost_mean             numeric,
  cost_p75              numeric,
  cost_p90              numeric,
  cost_max              numeric,
  cost_sum              numeric,
  -- Orders-side aggregates (from seatgeek_orders)
  orders_open           int,
  orders_pending        int,
  orders_confirmed      int,
  orders_fulfilled      int,
  orders_delivered      int,
  orders_cancelled      int,
  -- Sold metrics (states confirmed/fulfilled/delivered)
  sold_quantity         int,
  sold_gross            numeric,
  sold_price_min        numeric,
  sold_price_median     numeric,
  sold_price_mean       numeric,
  sold_price_max        numeric,
  -- Mix
  edelivery_share       numeric,             -- pct of listings with is_edelivery=true
  instant_share         numeric,             -- pct of listings with is_instant=true
  unique_sections       int,                 -- count distinct sections in listings
  unique_rows           int,
  -- Fill rate (sold / total ever listed) — proxy: sold_qty / (sold_qty + active_qty)
  fill_rate             numeric,
  CONSTRAINT seatgeek_event_metrics_dedup UNIQUE (tevo_event_id, captured_at)
);
CREATE INDEX IF NOT EXISTS idx_sg_em_event ON seatgeek_event_metrics(tevo_event_id, captured_at DESC);

-- ============================================================
-- C. Categorization view — listings rolled up by performer + venue
-- ============================================================
-- For "show me all our SG inventory for Performer X at Venue Y" without
-- writing JOIN-laden queries every time. Built on the LATEST snapshot
-- per event so we don't double-count across snapshots.

CREATE OR REPLACE VIEW public.seatgeek_categorized_listings AS
WITH latest_per_event AS (
  SELECT DISTINCT ON (sg_event_id) sg_event_id, pulled_at
  FROM seatgeek_seller_listings
  ORDER BY sg_event_id, pulled_at DESC
),
latest_listings AS (
  SELECT sl.*
  FROM seatgeek_seller_listings sl
  JOIN latest_per_event lpe
    ON lpe.sg_event_id = sl.sg_event_id
   AND lpe.pulled_at  = sl.pulled_at
)
SELECT
  ll.sg_event_name,                       -- often "Performer A at Performer B" for sports
  ll.sg_venue,
  ll.sg_event_date,
  ll.sg_event_id,
  ll.tevo_event_id,
  COUNT(*)                              AS listings,
  SUM(ll.quantity)                      AS tickets,
  ROUND(AVG(ll.cost)::numeric, 2)       AS avg_cost,
  ROUND(MIN(ll.cost)::numeric, 2)       AS min_cost,
  ROUND(MAX(ll.cost)::numeric, 2)       AS max_cost,
  COUNT(DISTINCT ll.section)            AS unique_sections,
  ARRAY_AGG(DISTINCT ll.section ORDER BY ll.section)
                                        AS section_set,
  MAX(ll.pulled_at)                     AS latest_pull_at
FROM latest_listings ll
GROUP BY 1, 2, 3, 4, 5
ORDER BY tickets DESC NULLS LAST;

GRANT SELECT ON public.seatgeek_categorized_listings TO authenticated, service_role;

-- ============================================================
-- D. Auto-extract performer + venue xref from existing data
-- ============================================================
-- These functions read from seatgeek_seller_listings (which carries
-- sg_event_name + sg_venue + sg_event_date) and look up matching TEvo
-- entities. No external API calls — pure SQL on data already in our DB.

-- For sports events the SG event_name is "Away at Home" — we extract
-- the home half and use it as a performer candidate, plus the away half
-- as a secondary candidate. For concerts the name is the performer
-- directly.
CREATE OR REPLACE FUNCTION public.auto_xref_sg_performers_from_listings()
RETURNS TABLE(linked_count int, attempted_count int)
LANGUAGE plpgsql AS $$
DECLARE
  v_linked int := 0;
  v_attempted int := 0;
  r RECORD;
  v_perf_id bigint;
  v_candidate text;
BEGIN
  FOR r IN (
    SELECT DISTINCT sg_event_name FROM seatgeek_seller_listings
    WHERE sg_event_name IS NOT NULL
    UNION
    SELECT DISTINCT sg_event_name FROM seatgeek_orders
    WHERE sg_event_name IS NOT NULL
  ) LOOP
    -- Sports: split on " at ". Concerts: full name = performer.
    -- Try both "home" (after at) and "away" (before at) candidates.
    FOR v_candidate IN
      SELECT DISTINCT trim(c) FROM (
        SELECT split_part(r.sg_event_name, ' at ', 2) AS c    -- "home" team
        UNION
        SELECT split_part(r.sg_event_name, ' at ', 1)         -- "away" team / concert name
        UNION
        SELECT r.sg_event_name                                -- full string
      ) t
      WHERE c IS NOT NULL AND length(trim(c)) > 2
    LOOP
      v_attempted := v_attempted + 1;
      -- Match against TEvo events.primary_performer_name
      SELECT e.primary_performer_id INTO v_perf_id
      FROM events e
      WHERE e.primary_performer_id IS NOT NULL
        AND lower(trim(e.primary_performer_name)) = lower(trim(v_candidate))
      LIMIT 1;
      IF v_perf_id IS NOT NULL THEN
        INSERT INTO seatgeek_performer_xref (tevo_performer_id, sg_performer_name, match_method, match_confidence)
        VALUES (v_perf_id, v_candidate, 'auto_listing', 0.85)
        ON CONFLICT (tevo_performer_id) DO UPDATE
          SET sg_performer_name = EXCLUDED.sg_performer_name,
              matched_at        = NOW();
        v_linked := v_linked + 1;
      END IF;
    END LOOP;
  END LOOP;
  linked_count := v_linked;
  attempted_count := v_attempted;
  RETURN NEXT;
END $$;

GRANT EXECUTE ON FUNCTION public.auto_xref_sg_performers_from_listings() TO service_role;

CREATE OR REPLACE FUNCTION public.auto_xref_sg_venues_from_listings()
RETURNS TABLE(linked_count int, attempted_count int)
LANGUAGE plpgsql AS $$
DECLARE
  v_linked int := 0;
  v_attempted int := 0;
  r RECORD;
  v_venue_id bigint;
BEGIN
  FOR r IN (
    SELECT DISTINCT sg_venue FROM seatgeek_seller_listings WHERE sg_venue IS NOT NULL
    UNION
    SELECT DISTINCT sg_venue FROM seatgeek_orders WHERE sg_venue IS NOT NULL
  ) LOOP
    v_attempted := v_attempted + 1;
    SELECT e.venue_id INTO v_venue_id
    FROM events e
    WHERE e.venue_id IS NOT NULL
      AND lower(trim(e.venue_name)) = lower(trim(r.sg_venue))
    LIMIT 1;
    IF v_venue_id IS NOT NULL THEN
      INSERT INTO seatgeek_venue_xref (tevo_venue_id, sg_venue_name, match_method, match_confidence)
      VALUES (v_venue_id, r.sg_venue, 'auto_listing', 0.9)
      ON CONFLICT (tevo_venue_id) DO UPDATE
        SET sg_venue_name = EXCLUDED.sg_venue_name,
            matched_at    = NOW();
      v_linked := v_linked + 1;
    END IF;
  END LOOP;
  linked_count := v_linked;
  attempted_count := v_attempted;
  RETURN NEXT;
END $$;

GRANT EXECUTE ON FUNCTION public.auto_xref_sg_venues_from_listings() TO service_role;

-- ============================================================
-- E. SeatGeek event metrics computation
-- ============================================================

CREATE OR REPLACE FUNCTION public.compute_seatgeek_event_metrics(p_tevo_event_id bigint)
RETURNS bigint  -- returns rowid of inserted metrics row, or NULL if no data
LANGUAGE plpgsql AS $$
DECLARE
  v_id bigint;
  v_sg_event_id bigint;
  v_now timestamptz := NOW();
  -- listings aggregates
  v_listings_count int; v_tickets_count int;
  v_cost_min numeric; v_cost_p25 numeric; v_cost_median numeric;
  v_cost_mean numeric; v_cost_p75 numeric; v_cost_p90 numeric;
  v_cost_max numeric; v_cost_sum numeric;
  v_unique_sections int; v_unique_rows int;
  v_edelivery_share numeric; v_instant_share numeric;
  -- orders aggregates
  v_o_open int; v_o_pending int; v_o_confirmed int;
  v_o_fulfilled int; v_o_delivered int; v_o_cancelled int;
  v_sold_qty int; v_sold_gross numeric;
  v_sold_min numeric; v_sold_med numeric; v_sold_mean numeric; v_sold_max numeric;
  v_fill numeric;
BEGIN
  -- Resolve sg_event_id (use most recent xref or listings row)
  SELECT MAX(sg_event_id) INTO v_sg_event_id
  FROM seatgeek_seller_listings WHERE tevo_event_id = p_tevo_event_id;

  -- LISTINGS aggregates: latest pull only
  WITH latest_pull AS (
    SELECT MAX(pulled_at) AS pa FROM seatgeek_seller_listings WHERE tevo_event_id = p_tevo_event_id
  ),
  active AS (
    SELECT * FROM seatgeek_seller_listings sl, latest_pull lp
    WHERE sl.tevo_event_id = p_tevo_event_id AND sl.pulled_at = lp.pa
  )
  SELECT
    COUNT(*),
    COALESCE(SUM(quantity), 0),
    MIN(cost),
    percentile_cont(0.25) WITHIN GROUP (ORDER BY cost),
    percentile_cont(0.5)  WITHIN GROUP (ORDER BY cost),
    AVG(cost),
    percentile_cont(0.75) WITHIN GROUP (ORDER BY cost),
    percentile_cont(0.9)  WITHIN GROUP (ORDER BY cost),
    MAX(cost),
    SUM(cost),
    COUNT(DISTINCT section),
    COUNT(DISTINCT row),
    CASE WHEN COUNT(*) > 0 THEN ROUND((COUNT(*) FILTER (WHERE is_edelivery)::numeric / COUNT(*))::numeric, 4) ELSE NULL END,
    CASE WHEN COUNT(*) > 0 THEN ROUND((COUNT(*) FILTER (WHERE is_instant)::numeric   / COUNT(*))::numeric, 4) ELSE NULL END
  INTO v_listings_count, v_tickets_count, v_cost_min, v_cost_p25, v_cost_median,
       v_cost_mean, v_cost_p75, v_cost_p90, v_cost_max, v_cost_sum,
       v_unique_sections, v_unique_rows, v_edelivery_share, v_instant_share
  FROM active;

  -- ORDERS aggregates: lifetime per event (orders are immutable history)
  SELECT
    COUNT(*) FILTER (WHERE status = 'open'),
    COUNT(*) FILTER (WHERE status = 'pending'),
    COUNT(*) FILTER (WHERE status = 'confirmed'),
    COUNT(*) FILTER (WHERE status = 'fulfilled'),
    COUNT(*) FILTER (WHERE status = 'delivered'),
    COUNT(*) FILTER (WHERE status = 'cancelled'),
    COALESCE(SUM(sale_quantity) FILTER (WHERE status IN ('confirmed','fulfilled','delivered')), 0),
    COALESCE(SUM(sale_price * sale_quantity) FILTER (WHERE status IN ('confirmed','fulfilled','delivered')), 0),
    MIN(sale_price)    FILTER (WHERE status IN ('confirmed','fulfilled','delivered')),
    percentile_cont(0.5) WITHIN GROUP (ORDER BY sale_price)
                       FILTER (WHERE status IN ('confirmed','fulfilled','delivered')),
    AVG(sale_price)    FILTER (WHERE status IN ('confirmed','fulfilled','delivered')),
    MAX(sale_price)    FILTER (WHERE status IN ('confirmed','fulfilled','delivered'))
  INTO v_o_open, v_o_pending, v_o_confirmed, v_o_fulfilled, v_o_delivered, v_o_cancelled,
       v_sold_qty, v_sold_gross, v_sold_min, v_sold_med, v_sold_mean, v_sold_max
  FROM seatgeek_orders WHERE tevo_event_id = p_tevo_event_id;

  -- Fill-rate proxy
  IF (COALESCE(v_sold_qty, 0) + COALESCE(v_tickets_count, 0)) > 0 THEN
    v_fill := ROUND((COALESCE(v_sold_qty, 0)::numeric /
              (COALESCE(v_sold_qty, 0) + COALESCE(v_tickets_count, 0))::numeric)::numeric, 4);
  ELSE
    v_fill := NULL;
  END IF;

  -- If both listings + orders aggregates are completely empty, skip insert.
  IF v_listings_count IS NULL AND v_sold_qty = 0 AND v_o_confirmed = 0 THEN
    RETURN NULL;
  END IF;

  INSERT INTO seatgeek_event_metrics (
    tevo_event_id, sg_event_id, captured_at,
    listings_count, tickets_count,
    cost_min, cost_p25, cost_median, cost_mean, cost_p75, cost_p90, cost_max, cost_sum,
    orders_open, orders_pending, orders_confirmed, orders_fulfilled, orders_delivered, orders_cancelled,
    sold_quantity, sold_gross, sold_price_min, sold_price_median, sold_price_mean, sold_price_max,
    edelivery_share, instant_share, unique_sections, unique_rows, fill_rate
  ) VALUES (
    p_tevo_event_id, v_sg_event_id, v_now,
    v_listings_count, v_tickets_count,
    ROUND(v_cost_min::numeric, 2), ROUND(v_cost_p25::numeric, 2), ROUND(v_cost_median::numeric, 2),
    ROUND(v_cost_mean::numeric, 2), ROUND(v_cost_p75::numeric, 2), ROUND(v_cost_p90::numeric, 2),
    ROUND(v_cost_max::numeric, 2), ROUND(v_cost_sum::numeric, 2),
    v_o_open, v_o_pending, v_o_confirmed, v_o_fulfilled, v_o_delivered, v_o_cancelled,
    v_sold_qty, ROUND(v_sold_gross::numeric, 2),
    ROUND(v_sold_min::numeric, 2), ROUND(v_sold_med::numeric, 2),
    ROUND(v_sold_mean::numeric, 2), ROUND(v_sold_max::numeric, 2),
    v_edelivery_share, v_instant_share, v_unique_sections, v_unique_rows, v_fill
  )
  ON CONFLICT (tevo_event_id, captured_at) DO UPDATE SET
    sg_event_id      = EXCLUDED.sg_event_id,
    listings_count   = EXCLUDED.listings_count,
    tickets_count    = EXCLUDED.tickets_count,
    cost_median      = EXCLUDED.cost_median,
    fill_rate        = EXCLUDED.fill_rate,
    sold_quantity    = EXCLUDED.sold_quantity,
    sold_gross       = EXCLUDED.sold_gross
  RETURNING id INTO v_id;
  RETURN v_id;
END $$;

GRANT EXECUTE ON FUNCTION public.compute_seatgeek_event_metrics(bigint) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.backfill_seatgeek_event_metrics(p_max_events int DEFAULT 100)
RETURNS TABLE(updated_count int) LANGUAGE plpgsql AS $$
DECLARE
  r RECORD; n int := 0;
BEGIN
  FOR r IN (
    -- Tevo events that have either listings or orders linked, prioritized by
    -- recency of activity. Cap so the cron tick stays under budget.
    SELECT DISTINCT tevo_event_id
    FROM (
      SELECT tevo_event_id, MAX(pulled_at) AS last_at FROM seatgeek_seller_listings
      WHERE tevo_event_id IS NOT NULL GROUP BY tevo_event_id
      UNION
      SELECT tevo_event_id, MAX(last_status_at) FROM seatgeek_orders
      WHERE tevo_event_id IS NOT NULL GROUP BY tevo_event_id
    ) u
    ORDER BY MAX(last_at) DESC
    LIMIT p_max_events
  ) LOOP
    BEGIN
      PERFORM compute_seatgeek_event_metrics(r.tevo_event_id);
      n := n + 1;
    EXCEPTION WHEN OTHERS THEN
      RAISE NOTICE 'compute_seatgeek_event_metrics failed for %: %', r.tevo_event_id, SQLERRM;
    END;
  END LOOP;
  updated_count := n; RETURN NEXT;
END $$;

GRANT EXECUTE ON FUNCTION public.backfill_seatgeek_event_metrics(int) TO service_role;

-- ============================================================
-- F. Cross-source event audit view (for the random-event report)
-- ============================================================
CREATE OR REPLACE VIEW public.cross_source_event_audit AS
SELECT
  e.id AS tevo_event_id,
  e.name, e.occurs_at_local::date AS event_date, e.venue_name, e.event_type,
  e.primary_performer_name,
  -- TEvo metrics (latest)
  (SELECT em.tickets_count FROM event_metrics em WHERE em.event_id = e.id
   ORDER BY captured_at DESC LIMIT 1)             AS tevo_tickets_count,
  (SELECT em.retail_median FROM event_metrics em WHERE em.event_id = e.id
   ORDER BY captured_at DESC LIMIT 1)             AS tevo_retail_median,
  (SELECT em.owned_tickets_count FROM event_metrics em WHERE em.event_id = e.id
   ORDER BY captured_at DESC LIMIT 1)             AS tevo_owned_tix,
  -- ESPN xref
  (SELECT espn_event_id FROM event_xref WHERE tevo_event_id = e.id LIMIT 1) AS espn_event_id,
  (SELECT espn_league   FROM event_xref WHERE tevo_event_id = e.id LIMIT 1) AS espn_league,
  -- SeatData
  (SELECT sd_event_id FROM seatdata_event_xref WHERE tevo_event_id = e.id LIMIT 1) AS sd_event_id,
  (SELECT COUNT(*) FROM seatdata_sales_snapshots WHERE tevo_event_id = e.id)       AS sd_sales_count,
  -- SeatGeek (broker host)
  (SELECT sg_event_id FROM seatgeek_event_xref WHERE tevo_event_id = e.id LIMIT 1) AS sg_event_id,
  -- SeatGeek (seller-direct host)
  (SELECT COUNT(*) FROM seatgeek_seller_listings WHERE tevo_event_id = e.id)       AS sg_seller_listings,
  (SELECT SUM(quantity) FROM seatgeek_seller_listings WHERE tevo_event_id = e.id
     AND pulled_at = (SELECT MAX(pulled_at) FROM seatgeek_seller_listings sl2 WHERE sl2.tevo_event_id = e.id))
                                                                                   AS sg_seller_active_tickets,
  (SELECT COUNT(*) FROM seatgeek_orders WHERE tevo_event_id = e.id)                AS sg_orders_total,
  -- TEvo orders
  (SELECT COUNT(DISTINCT evo_order_id) FROM evo_order_items WHERE event_id = e.id) AS evo_orders_total,
  -- Lifecycle
  (SELECT status FROM event_lifecycle WHERE event_id = e.id LIMIT 1)               AS lifecycle_status
FROM events e;

GRANT SELECT ON public.cross_source_event_audit TO authenticated, service_role;

-- Lock down GRANT permissions: external-mirrored data tables are
-- service-role-write-only. authenticated only reads.
REVOKE INSERT, UPDATE, DELETE ON seatgeek_seller_listings  FROM authenticated;
REVOKE INSERT, UPDATE, DELETE ON seatgeek_orders           FROM authenticated;
REVOKE INSERT, UPDATE, DELETE ON seatgeek_order_tickets    FROM authenticated;
REVOKE INSERT, UPDATE, DELETE ON seatgeek_seller_pull_log  FROM authenticated;
REVOKE INSERT, UPDATE, DELETE ON seatgeek_event_metrics    FROM authenticated;
REVOKE INSERT, UPDATE, DELETE ON seatgeek_performer_xref   FROM authenticated;
REVOKE INSERT, UPDATE, DELETE ON seatgeek_venue_xref       FROM authenticated;

GRANT  SELECT ON seatgeek_event_metrics    TO authenticated;
GRANT  SELECT ON seatgeek_performer_xref   TO authenticated;
GRANT  SELECT ON seatgeek_venue_xref       TO authenticated;
GRANT  SELECT, INSERT, UPDATE ON seatgeek_event_metrics    TO service_role;
GRANT  SELECT, INSERT, UPDATE ON seatgeek_performer_xref   TO service_role;
GRANT  SELECT, INSERT, UPDATE ON seatgeek_venue_xref       TO service_role;

COMMIT;
