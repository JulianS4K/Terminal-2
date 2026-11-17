-- ============================================================================
-- Migration 20260910150000 — verify a cover is still good to buy
--
-- Lane:     D0 (orders surface)
-- Touches:  n2s_cover_verify() (new). Reads only; writes nothing.
-- Pre-reqs: 20260910140000
--
-- READ-ONLY: pure SELECT over already-ingested data. No API call, no write.
--
-- Operator direction 2026-09-09: "first we verify if the orders are good to
-- buy." See docs/evo_buy_side.md for the buy-side flow this gates.
--
-- ── Why a cover needs re-checking at all ───────────────────────────────────
-- A cover is TWO claims that were true at different moments:
--   * the listing was live when its snapshot was captured — up to an hour ago
--     under the 1-hour freshness rule;
--   * the order was open when the cover queue last refreshed — up to 2 min ago.
-- Both can go stale before anyone acts, and a stale cover costs money in a way
-- a stale read never does: buying a listing that is gone, or covering an order
-- that has already been resolved or allocated elsewhere.
--
-- ⚠ THIS IS NOT A FRESH UPSTREAM PULL AND MUST NOT BE MISTAKEN FOR ONE. It
-- re-checks against the NEWEST DATA WE HOLD. If nothing has been captured for
-- that event recently it returns `stale_data` — "we cannot tell" — rather than
-- `ok`. The distinction matters: a silent `ok` on stale data is exactly the
-- false confidence a pre-purchase gate exists to prevent. Force a real refresh
-- with n2s_pull_all_sources() first if certainty is needed.
--
-- ⚠ `gone` AND `order_closed` ARE HARD BLOCKS. `price_up` is a judgement call
-- and is reported WITH the delta rather than silently dropped or re-ranked —
-- a cover $3 dearer may still be the right buy on an obligation, and that is
-- the operator's call, not this function's.
--
-- ⚠ THE TEVO ARM RE-CHECKS THE PINNED CAPTURE, NOT ANY ROW EVER SEEN. Asking
-- "does this listing_id appear anywhere recently" would answer yes for
-- inventory that sold hours ago (§ the dead-inventory lesson in
-- 20260910060000). The question is "is it in the most recent observation of
-- this event", which is what absence-from-a-snapshot actually means.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.n2s_cover_verify(
  p_n2s_ids   bigint[] DEFAULT NULL,
  p_freshness interval DEFAULT interval '1 hour'
)
RETURNS TABLE (
  n2s_id         bigint,
  order_number   text,
  s4k_source     text,
  sub_source     text,
  sub_listing_id text,
  quoted_ea      numeric,
  price_now      numeric,
  price_delta_ea numeric,
  verdict        text,
  buyable        boolean,
  checked_at     timestamptz
)
LANGUAGE sql STABLE
SET search_path TO 'public','pg_temp'
AS $$
  WITH q AS (
    SELECT c.* FROM public.n2s_cover_queue c
     WHERE p_n2s_ids IS NULL OR c.n2s_id = ANY(p_n2s_ids)
  ),
  -- Newest capture per event per source. Absence from THIS is what "gone"
  -- means; absence from "anywhere recent" would resurface sold inventory.
  pin AS (
    SELECT q.tevo_event_id AS eid,
           (SELECT max(l.captured_at) FROM public.listings_snapshots l
             WHERE l.event_id = q.tevo_event_id
               AND l.captured_at >= now() - p_freshness) AS tevo_cap,
           (SELECT max(g.captured_at) FROM public.gotickets_listings_snapshots g
             WHERE g.tevo_event_id = q.tevo_event_id
               AND g.captured_at >= now() - p_freshness) AS gt_cap,
           (SELECT max(s.captured_at) FROM public.seatgeek_listings_snapshots s
             WHERE s.tevo_event_id = q.tevo_event_id
               AND s.captured_at >= now() - p_freshness) AS sg_cap
      FROM q GROUP BY q.tevo_event_id
  ),
  live AS (
    SELECT q.n2s_id,
           CASE q.sub_source
             WHEN 'tevo' THEN
               (SELECT min(t.retail_price) FROM public.listings_snapshots t
                 JOIN pin p ON p.eid = q.tevo_event_id
                WHERE t.event_id = q.tevo_event_id
                  AND t.captured_at = p.tevo_cap
                  AND t.tevo_ticket_group_id::text = q.sub_listing_id
                  AND NOT t.is_owned AND NOT t.is_ancillary)
             WHEN 'gotickets' THEN
               (SELECT min(g.all_in_price) FROM public.gotickets_listings_snapshots g
                 JOIN pin p ON p.eid = q.tevo_event_id
                WHERE g.tevo_event_id = q.tevo_event_id
                  AND g.captured_at = p.gt_cap
                  AND g.gt_listing_id::text = q.sub_listing_id)
             WHEN 'seatgeek' THEN
               (SELECT min(s.retail_price_all_in) FROM public.seatgeek_listings_snapshots s
                 JOIN pin p ON p.eid = q.tevo_event_id
                WHERE s.tevo_event_id = q.tevo_event_id
                  AND s.captured_at = p.sg_cap
                  AND s.sglid::text = q.sub_listing_id
                  AND NOT s.is_broker_owned)
             ELSE NULL          -- ticketsdata: a change feed, cannot assert absence
           END AS price_now,
           CASE q.sub_source
             WHEN 'tevo'      THEN (SELECT tevo_cap FROM pin p WHERE p.eid = q.tevo_event_id)
             WHEN 'gotickets' THEN (SELECT gt_cap   FROM pin p WHERE p.eid = q.tevo_event_id)
             WHEN 'seatgeek'  THEN (SELECT sg_cap   FROM pin p WHERE p.eid = q.tevo_event_id)
             ELSE NULL
           END AS have_snapshot,
           (SELECT NOT i.is_terminal FROM public.n2s_items i WHERE i.n2s_id = q.n2s_id) AS order_open
      FROM q
  )
  SELECT q.n2s_id, q.order_number, q.s4k_source, q.sub_source, q.sub_listing_id,
         q.sub_ea AS quoted_ea,
         l.price_now,
         CASE WHEN l.price_now IS NULL THEN NULL
              ELSE round(l.price_now - q.sub_ea, 2) END AS price_delta_ea,
         CASE
           WHEN NOT COALESCE(l.order_open, false)      THEN 'order_closed'
           WHEN q.sub_source LIKE 'ticketsdata%'       THEN 'stale_data'
           WHEN l.have_snapshot IS NULL                THEN 'stale_data'
           WHEN l.price_now IS NULL                    THEN 'gone'
           WHEN l.price_now > q.sub_ea                 THEN 'price_up'
           ELSE 'ok'
         END AS verdict,
         -- Only `ok` and `price_up` are buyable; the operator decides on the
         -- latter with the delta in hand. `stale_data` is NOT buyable: it means
         -- we cannot tell, which is not the same as fine.
         (COALESCE(l.order_open, false)
          AND l.price_now IS NOT NULL
          AND l.have_snapshot IS NOT NULL) AS buyable,
         now() AS checked_at
    FROM q JOIN live l ON l.n2s_id = q.n2s_id
   ORDER BY q.cover_cost;
$$;

COMMENT ON FUNCTION public.n2s_cover_verify(bigint[], interval) IS
  'Pre-purchase gate for N2S covers: re-checks each queued cover against the '
  'NEWEST DATA WE HOLD (not a fresh upstream pull) and reports ok / price_up / '
  'gone / order_closed / stale_data. gone and order_closed are hard blocks; '
  'price_up is reported with the delta because a dearer cover may still be the '
  'right buy on an obligation. stale_data means "cannot tell" and is NOT '
  'buyable — run n2s_pull_all_sources() first if certainty is needed. '
  'TicketsData always reads stale_data: it is a change feed, so absence there '
  'means unchanged, not sold. See docs/evo_buy_side.md.';

REVOKE ALL ON FUNCTION public.n2s_cover_verify(bigint[], interval) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.n2s_cover_verify(bigint[], interval) TO authenticated, service_role;
