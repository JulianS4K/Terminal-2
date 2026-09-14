-- ============================================================================
-- Migration 20260911160600 — v_our_purchase_deals: purchase ↔ flagged deal ↔ label
--
-- Lane:     D0 (deals surface)
-- Touches:  v_our_purchase_deals (CREATE VIEW)
--           Reads: v_our_purchases, gotickets_deals_feed, gotickets_deal_outcome
-- Pre-reqs: 20260911160400 (gotickets_deal_outcome), 20260911160500 (v_our_purchases)
--
-- Split out of mig 20260911160500 so the purchase pollers can be applied on their
-- own (operator approved 160500 first): this is the one object that needs BOTH
-- the buy-side books and the outcome label. Shows which flagged deals we
-- actually bought (same event × section number × row, flagged before the buy)
-- with the feed's prediction and, once the event has played, the label.
--
-- READ-ONLY upstream: no API call.
-- ROLLBACK: DROP VIEW public.v_our_purchase_deals;
-- ============================================================================

CREATE OR REPLACE VIEW public.v_our_purchase_deals
WITH (security_invoker = true) AS
SELECT p.source, p.purchase_id, p.tevo_event_id, p.event_name, p.event_date,
       p.section, p."row", p.quantity, p.unit_all_in, p.purchased_at,
       f.gt_listing_id, f.gt_price AS deal_price, f.first_seen_at AS deal_first_seen_at,
       f.win_prob AS deal_win_prob, f.net_profit_pct AS deal_net_profit_pct,
       f.confidence AS deal_confidence, f.regime AS deal_regime,
       o.outcome AS label_outcome, o.realized_roi_pct AS label_realized_roi_pct,
       o.match_level AS label_match_level
FROM public.v_our_purchases p
JOIN public.gotickets_deals_feed f
  ON f.tevo_event_id = p.tevo_event_id
 AND (regexp_match(f.section, '(\d{1,4})'))[1] = p.secnum
 AND upper(btrim(f."row")) = upper(btrim(p."row"))
 AND f.first_seen_at <= p.purchased_at + interval '1 day'
LEFT JOIN public.gotickets_deal_outcome o
  ON o.tevo_event_id = f.tevo_event_id AND o.gt_listing_id = f.gt_listing_id
WHERE p.tevo_event_id IS NOT NULL;
GRANT SELECT ON public.v_our_purchase_deals TO authenticated, service_role;
COMMENT ON VIEW public.v_our_purchase_deals IS
  'Purchases that match a flagged deal (same event x section number x row, flagged before we bought) with the feed prediction and, once played, the outcome label. Shows which deals we acted on and how they graded. A1 mig 20260911160500.';

