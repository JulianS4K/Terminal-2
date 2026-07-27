-- ============================================================================
-- Migration 20260509370000 — Data fixes + AI context + net-amount modeling
--
-- Acts on directives from the suggestions review:
--   "first we fix the data, do 1-2, drop rivalries for now,
--    add later for context, do 4 ... 8 keep gross and net"
--
-- This migration covers:
--   (A) DROP wiki_rivalries (no consumer; can re-add later for AI context)
--   (B) WIRE seatgeek_event_metrics into v_event_full (event-level rollup
--       was being computed but never JOINed from the canonical view)
--   (C) WIRE event_sentiment into v_event_full (18 rows, never queried)
--   (D) GET_EVENT_CONTEXT(event_id) — single JSON for AI/RAG consumers
--       bundling TEvo + SG + ESPN + Wikipedia + weather + competitors
--   (E) ORDER_FEE_SCHEDULE + net_amount on our_orders — keep gross AND
--       net so trader can read either side without doing math live
--
-- SD note: SeatData pull pipeline is genuinely missing (not just silent)
-- — no pull function exists in plpgsql. Documented as blocker in
-- docs/seatdata-blocker-2026-05-09.md. Not fixing here without API spec.
-- ============================================================================

-- ============================================================================
-- (A) Drop wiki_rivalries
-- ============================================================================
DROP TABLE IF EXISTS wiki_rivalries;

-- ============================================================================
-- (B+C) Extend v_event_full to surface SG event metrics + sentiment
--
-- Strategy: don't rewrite v_event_full (it's complex and used elsewhere).
-- Build a thin v_event_full_v2 that LEFT JOINs the orphan tables. Existing
-- v_event_full callers keep working; new callers can opt into v_event_full_v2.
-- ============================================================================

CREATE OR REPLACE VIEW v_event_full_v2 AS
SELECT
  ef.*,
  -- SG event-level metrics (latest snapshot per event)
  sgm.captured_at         AS sg_metrics_captured_at,
  sgm.listings_count      AS sg_metrics_listings,
  sgm.tickets_count       AS sg_metrics_tickets,
  sgm.cost_min            AS sg_metrics_cost_min,
  sgm.cost_median         AS sg_metrics_cost_median,
  sgm.cost_p90            AS sg_metrics_cost_p90,
  sgm.orders_open         AS sg_metrics_orders_open,
  sgm.orders_fulfilled    AS sg_metrics_orders_fulfilled,
  sgm.sold_quantity       AS sg_metrics_sold_qty,
  sgm.sold_gross          AS sg_metrics_sold_gross,
  sgm.fill_rate           AS sg_metrics_fill_rate,
  -- event sentiment (latest)
  es.captured_at          AS sentiment_captured_at,
  es.sentiment_index,
  es.tix_per_hour,
  es.getin_per_hour,
  es.owned_share_change,
  es.pairs_change_per_hour
FROM v_event_full ef
LEFT JOIN LATERAL (
  SELECT * FROM seatgeek_event_metrics WHERE tevo_event_id = ef.tevo_event_id
  ORDER BY captured_at DESC LIMIT 1
) sgm ON true
LEFT JOIN LATERAL (
  SELECT * FROM event_sentiment WHERE event_id = ef.tevo_event_id
  ORDER BY captured_at DESC LIMIT 1
) es ON true;

COMMENT ON VIEW v_event_full_v2 IS
  'v_event_full extended with SG event-level metrics + latest sentiment row. '
  'Use this when you want every aggregate signal we have on an event.';

-- ============================================================================
-- (D) get_event_context(p_event_id) — AI/RAG consumer interface
--
-- Single function that bundles everything we know about an event into one
-- JSON. Future AI connectors call this at prompt time to enrich context
-- without having to know our schema. Designed for RAG over a single event.
-- ============================================================================

CREATE OR REPLACE FUNCTION get_event_context(p_event_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
  v_event       jsonb;
  v_pricing     jsonb;
  v_espn        jsonb;
  v_performer   jsonb;
  v_weather     jsonb;
  v_competitors jsonb;
  v_orders      jsonb;
BEGIN
  -- Event basics
  SELECT to_jsonb(e) - 'performer_ids'
    INTO v_event FROM events e WHERE id = p_event_id;
  IF v_event IS NULL THEN
    RETURN jsonb_build_object('error', 'event_not_found', 'tevo_event_id', p_event_id);
  END IF;

  -- Pricing rollup from v_event_full_v2 (which now includes SG + sentiment)
  SELECT to_jsonb(ef) INTO v_pricing
    FROM v_event_full_v2 ef WHERE ef.tevo_event_id = p_event_id;

  -- ESPN context (if sports + xref'd)
  SELECT jsonb_build_object(
    'espn_event_id', x.espn_event_id,
    'latest_state',  (SELECT state FROM espn_event_snapshots ee
                       WHERE ee.espn_event_id = x.espn_event_id
                       ORDER BY captured_at DESC LIMIT 1),
    'latest_status', (SELECT status_short FROM espn_event_snapshots ee
                       WHERE ee.espn_event_id = x.espn_event_id
                       ORDER BY captured_at DESC LIMIT 1),
    'latest_score',  (SELECT home_score::text || '-' || away_score::text
                       FROM espn_event_snapshots ee
                       WHERE ee.espn_event_id = x.espn_event_id
                       ORDER BY captured_at DESC LIMIT 1)
  ) INTO v_espn
  FROM event_xref x WHERE x.tevo_event_id = p_event_id LIMIT 1;

  -- Wikipedia context for primary performer
  SELECT jsonb_build_object(
    'tevo_performer_id', pw.tevo_performer_id,
    'wiki_title', pw.wiki_title,
    'wiki_url', pw.wiki_url,
    'description', pw.description,
    'extract', pw.extract,
    'image_url', pw.image_url
  ) INTO v_performer
  FROM performer_wikipedia pw
  JOIN events e ON e.primary_performer_id = pw.tevo_performer_id
  WHERE e.id = p_event_id AND NOT pw.is_rejected
  LIMIT 1;

  -- Weather (if event ≤16d out and venue geocoded)
  SELECT to_jsonb(w) INTO v_weather
  FROM v_event_weather_with_fallback w WHERE w.tevo_event_id = p_event_id;

  -- Competing events (from snapshot)
  SELECT competitors INTO v_competitors
  FROM event_competitors_snapshot WHERE tevo_event_id = p_event_id;

  -- Our orders for this event
  SELECT to_jsonb(o) INTO v_orders
  FROM our_orders_by_event o WHERE o.tevo_event_id = p_event_id;

  RETURN jsonb_build_object(
    'tevo_event_id', p_event_id,
    'event', v_event,
    'pricing', COALESCE(v_pricing, '{}'::jsonb),
    'espn', COALESCE(v_espn, jsonb_build_object('present', false)),
    'performer', COALESCE(v_performer, jsonb_build_object('present', false)),
    'weather', COALESCE(v_weather, jsonb_build_object('present', false)),
    'competitors', COALESCE(v_competitors, '[]'::jsonb),
    'our_orders', COALESCE(v_orders, jsonb_build_object('present', false)),
    'generated_at', now()
  );
END;
$$;

COMMENT ON FUNCTION get_event_context IS
  'Single-call event-context bundle for AI/RAG consumers. Returns one JSON '
  'with TEvo basics + pricing rollup + ESPN status + Wikipedia text + '
  'weather + competing events + our orders. Designed for prompt-time '
  'enrichment; no schema knowledge required by the caller.';

-- ============================================================================
-- (E) Net-amount modeling: keep gross AND net side-by-side
--
-- order_fee_schedule — per-source fee structure. Default rates are best-guess
-- placeholders; update per actual contract terms.
-- our_orders_with_net — wraps our_orders adding net_amount = gross * (1 - fee)
-- ============================================================================

CREATE TABLE IF NOT EXISTS order_fee_schedule (
  source             text PRIMARY KEY,
  buyer_fee_pct      numeric(5,4) DEFAULT 0,    -- buyer-side markup
  seller_fee_pct     numeric(5,4) DEFAULT 0,    -- seller-side commission
  fixed_fee_per_order numeric(8,2) DEFAULT 0,
  notes              text,
  effective_from     date DEFAULT current_date
);

COMMENT ON TABLE order_fee_schedule IS
  'Fee structure per sales channel. Used to compute net_amount alongside '
  'gross_amount in our_orders_with_net. Update entries to reflect actual '
  'contract terms — defaults are placeholders.';

INSERT INTO order_fee_schedule(source, buyer_fee_pct, seller_fee_pct, fixed_fee_per_order, notes)
VALUES
  ('tevo',      0.00, 0.06, 0,    'TEvo: ~6% seller commission (placeholder; verify)'),
  ('sg_seller', 0.00, 0.10, 0,    'SeatGeek sellerdirect: ~10% seller fee (placeholder; verify)'),
  ('seatdata',  0.00, 0.00, 0,    'SD is observation-only, not our sale')
ON CONFLICT (source) DO NOTHING;

CREATE OR REPLACE VIEW our_orders_with_net AS
SELECT
  o.*,
  ofs.seller_fee_pct,
  ofs.fixed_fee_per_order,
  ROUND(
    (o.gross_amount * (1 - COALESCE(ofs.seller_fee_pct, 0)) - COALESCE(ofs.fixed_fee_per_order, 0))::numeric,
    2
  ) AS net_amount
FROM our_orders o
LEFT JOIN order_fee_schedule ofs ON ofs.source = o.source;

COMMENT ON VIEW our_orders_with_net IS
  'our_orders + computed net_amount per order_fee_schedule. Keeps gross and '
  'net side-by-side so traders can read either without re-deriving.';

CREATE OR REPLACE VIEW our_orders_by_event_with_net AS
SELECT
  tevo_event_id,
  count(*)                                   AS our_orders_total,
  count(*) FILTER (WHERE source='tevo')       AS tevo_orders,
  count(*) FILTER (WHERE source='sg_seller')  AS sg_seller_orders,
  sum(gross_amount) FILTER (WHERE canonical_status='fulfilled') AS gross_fulfilled,
  sum(net_amount)   FILTER (WHERE canonical_status='fulfilled') AS net_fulfilled,
  count(*) FILTER (WHERE canonical_status='fulfilled') AS count_fulfilled,
  count(*) FILTER (WHERE canonical_status='pending')   AS count_pending,
  count(*) FILTER (WHERE canonical_status='accepted')  AS count_accepted,
  count(*) FILTER (WHERE canonical_status='cancelled') AS count_cancelled,
  count(*) FILTER (WHERE canonical_status='rejected')  AS count_rejected,
  max(source_updated_at) AS latest_activity
FROM our_orders_with_net
GROUP BY tevo_event_id;

COMMENT ON VIEW our_orders_by_event_with_net IS
  'Per-event rollup with both gross_fulfilled and net_fulfilled. Replaces '
  'our_orders_by_event for surfaces that care about take-home vs face value.';
