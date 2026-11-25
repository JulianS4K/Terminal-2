-- Migration 20261125200000 · level:data-collection · lane:a1 (box-office poll feed) · writes:v_primary_poll_listings_feed · reads:primary_poll_listing,primary_poll_event,primary_poll_source,primary_poll_listing_piece,primary_poll_config
--
-- ============================================================================
-- Migration 20261125200000 — FIX: the ADA filter dropped every listing whose
--   ticket_type is NULL, which took the whole Timberwolves feed dark
--
-- Lane:     a1 (box-office poll feed)
-- Touches:  v_primary_poll_listings_feed (REPLACE). Same 33 columns, same order.
-- Pre-reqs: 20261125180000 (the ADA withholding this corrects)
--
-- REGRESSION INTRODUCED BY 20261125180000, applied to prod 2026-11-25 17:51Z.
-- Found 2026-11-25 ~19:50Z while tracing the AXS catalogue-to-API pipeline for
-- the operator.
--
-- ── The bug ────────────────────────────────────────────────────────────────
-- 20261125180000 added to the feed's WHERE:
--
--   AND (send_ada OR NOT (coalesce(l.ada, false) OR l.ticket_type = 'ACCESSIBLE'))
--
-- With ticket_type NULL the inner comparison is NULL, not false:
--
--   coalesce(ada,false) OR NULL   ->  false OR NULL  ->  NULL
--   NOT NULL                      ->  NULL
--   send_ada(false) OR NULL       ->  NULL           ->  row filtered out
--
-- So the filter withheld not only accessible seats but EVERY listing that
-- carries no ticket_type at all. Three-valued logic, the oldest trap in SQL,
-- and the ADA test was the one place in that WHERE clause comparing a
-- nullable text column to a literal.
--
-- ── What it cost, measured on prod before this fix ─────────────────────────
--   timberwolves   15,137 of 15,137 stored listings dropped  (100%) — the
--                  Jump reader fills no ticket_type at all, so the entire
--                  Timberwolves box-office feed served ZERO listings from
--                  17:51Z. The events feed still listed the games, so the
--                  API looked alive while every game read as having no seats.
--   axs               154 of 117,207 dropped (0.1%), and with them 3 events
--                  entirely: 1686901 UFC BJJ 14, 1695051 Kai Wachi,
--                  1657003 HOL! — all polling 'ok', all with priced,
--                  unobstructed, non-ADA inventory.
--   sitickets           0 (it always sets ticket_type).
--
-- ── The fix ────────────────────────────────────────────────────────────────
-- coalesce the comparison so a missing ticket_type reads as "not accessible",
-- which is what the rule meant: withhold a seat we KNOW is accessible, never
-- one we know nothing about.
--
-- Verified on a local Postgres 16, all four cases:
--   send_ada=false, ada=false, ticket_type NULL         -> kept    (was dropped)
--   send_ada=false, ticket_type='ACCESSIBLE'            -> withheld
--   send_ada=false, ada=true                            -> withheld
--   send_ada=true                                       -> everything sent
--
-- The operator's rule (2026-11-25, "also dont send out ADA seats too") is
-- unchanged: accessible seats are still stored and still not sent.
--
-- NOT APPLIED TO PROD as of this commit. The Timberwolves feed serves zero
-- listings until it is. Awaiting the operator's word (CLAUDE.md Rule 1).
-- ============================================================================

BEGIN;

CREATE OR REPLACE VIEW public.v_primary_poll_listings_feed AS
 SELECT l.source,
    l.source_event_id AS event_id,
    t.name AS event_name,
    t.tevo_event_id,
    t.event_date,
    t.start_local_time,
        CASE
            WHEN p.part IS NOT NULL THEN (l.listing_id || '-'::text) || p.part
            ELSE l.listing_id
        END AS listing_id,
    l.market,
    l.area,
    l.section,
    l.seat_row,
        CASE
            WHEN p.part IS NOT NULL THEN p.seat_low
            ELSE l.seat_low
        END AS seat_low,
        CASE
            WHEN p.part IS NOT NULL THEN p.seat_high
            ELSE l.seat_high
        END AS seat_high,
        CASE
            WHEN p.part IS NOT NULL THEN p.seats
            ELSE l.seats
        END AS seats,
        CASE
            WHEN p.part IS NOT NULL THEN p.quantity
            ELSE l.quantity
        END AS quantity,
        CASE
            WHEN p.part IS NOT NULL AND jsonb_typeof(l.allowed_quantities) = 'array'::text THEN ( SELECT jsonb_agg(q.v ORDER BY q.i) AS jsonb_agg
               FROM jsonb_array_elements(l.allowed_quantities) WITH ORDINALITY q(v, i)
              WHERE jsonb_typeof(q.v) = 'number'::text AND ((q.v #>> '{}'::text[])::numeric) <= LEAST(l.order_limit, p.quantity)::numeric)
            ELSE l.allowed_quantities
        END AS allowed_quantities,
        CASE
            WHEN p.part IS NOT NULL THEN LEAST(l.order_limit, p.quantity)
            WHEN l.order_limit IS NOT NULL THEN LEAST(l.order_limit, l.quantity)
            ELSE l.max_per_order
        END AS max_per_order,
    t.order_min,
    t.order_max,
    l.price,
    l.fee,
    l.all_in_price,
    l.price_includes_tax,
    t.currency,
    l.ticket_type,
    l.delivery,
    l.ada,
    l.aisle,
    l.general_admission,
    t.poll_ok_at AS as_of,
    l.tax,
    l.order_fee,
    l.price_estimated
   FROM primary_poll_listing l
     JOIN primary_poll_event t ON t.source = l.source AND t.source_event_id = l.source_event_id
     JOIN primary_poll_source s ON s.source = t.source AND s.current_run = t.last_run
     LEFT JOIN primary_poll_listing_piece p ON p.source = l.source AND p.source_event_id = l.source_event_id AND p.listing_id = l.listing_id AND ( SELECT c.split_over_limit
           FROM primary_poll_config c)
  WHERE t.poll_status = 'ok'::text
    AND NOT primary_poll_ended(t.start_utc, t.event_date)
    AND now() < GREATEST(t.poll_ok_at + (( SELECT c.listing_max_age FROM primary_poll_config c)),
                         t.next_poll_at + (( SELECT c.listing_grace FROM primary_poll_config c)))
    AND NOT l.obstructed
    -- coalesce: a listing with NO ticket_type is not an accessible seat. Without it the
    -- comparison is NULL, the whole conjunct is NULL and the row is filtered out — which
    -- dropped all 15,137 Timberwolves listings (mig 20261125200000).
    AND (( SELECT c.send_ada FROM primary_poll_config c)
         OR NOT (COALESCE(l.ada, false) OR COALESCE(l.ticket_type, ''::text) = 'ACCESSIBLE'::text))
    AND (t.event_date IS NULL OR t.event_date >= (CURRENT_DATE - 1));

COMMIT;
