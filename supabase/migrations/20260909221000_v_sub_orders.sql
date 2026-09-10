-- ============================================================================
-- Migration 20260909221000 — v_sub_orders: one order feed for the sub pipeline,
--                            our own books first, CRM only where we have none
--
-- Lane:     D0 (orders surface) over A1's order books
-- Touches:  v_sub_orders (CREATE VIEW)
--           reads v_s4kcs_orders, evo_orders, evo_order_items, events
-- Pre-reqs: 20260909220000 (v_s4kcs_orders price repair + price_per_ticket)
--
-- READ-ONLY: pure SELECT, no upstream call, no write.
--
-- Operator direction 2026-09-09: "only use crm feed to cover sources we don't
-- have and check for other sources evo and sg." This is the audit and its
-- result.
--
-- ── Which book wins, and why ────────────────────────────────────────────────
--   marketplace  own book             state (measured 2026-09-09 20:26 UTC)
--   Vivid Seats  vivid_orders         8,297 rows, LIVE, 6,646 mapped   -> OURS
--   GoTickets    gotickets_sales      NEW (mig 20260909220000)         -> OURS
--   EVO / TEvo   evo_orders + items   3,311 rows, LIVE, 3,192 mapped   -> OURS
--   SeatGeek     seatgeek_orders      400 rows, live, ZERO mapped      -> CRM
--   TickPick     tickpick_orders      2,578 rows, LAST PULL 2026-05-31 -> CRM
--   StubHub      (none)                                                -> CRM
--   Gametime     (none)                                                -> CRM
--
-- ⚠ TWO OWN BOOKS EXIST BUT CANNOT BE USED, and both look usable at a glance:
--   * `seatgeek_orders` is LIVE (pulled 20:13 today) yet holds only 400 rows
--     against 4,206 future SeatGeek orders in the CRM, and **zero** of them
--     carry a tevo_event_id — so it cannot reach an event at all, which is the
--     one thing the sub pipeline needs. Freshness is not coverage.
--   * `tickpick_orders` has 2,578 rows and 2,117 of them mapped, which reads as
--     healthy until you check the clock: its newest `pulled_at` is 2026-05-31,
--     over three months stale. This is the pipeline `mapping_health_check()`
--     already flags as dead. A table with good historical data and no ingest is
--     WORSE than no table — it answers confidently and wrongly.
-- Both therefore stay on the CRM feed. Revisit if either ingest is restored:
-- SeatGeek needs its orders mapped, TickPick needs its poller back.
--
-- ⚠ EVO IS NOT IN THE CRM AT ALL. The S4K CRM covers six marketplaces
-- (StubHub, Gametime, SeatGeek, TickPick, Vivid, GoTickets). Our EVO/TEvo
-- exchange sales are in none of them, so every EVO order was invisible to the
-- whole substitution pipeline — 754 future orders. They are unioned in here.
--
-- ⚠ EVO DATES MUST NOT COME FROM `evo_order_items.occurs_at`. That column is
-- `timestamp with time zone` (UTC), so `::date` walks straight into the §3
-- mixed-timezone landmine: a 19:30 local game in the US lands on the NEXT day
-- in UTC and would bind the wrong date. `events.occurs_at_local` is TEXT and
-- LOCAL — the same frame as every other order's event_date — so the date comes
-- from there wherever the item joins the mirror, and only falls back to the UTC
-- cast otherwise. That fallback is NOT rare: 118 of 813 future EVO orders take
-- it, so `date_source` is emitted per row rather than assumed.
-- Blast radius is bounded on purpose: event_date is used ONLY as the
-- `>= current_date` horizon filter — the matcher joins listings on
-- tevo_event_id, never on the date — so a fallback row that is off by one can
-- shift in or out of the horizon at the boundary but can never match against
-- the wrong day's inventory.
--
-- ⚠ EVO price is PER TICKET: `evo_order_items.price` equals
-- `ticket_group_retail_price` in all 754 future items. Do not divide by
-- quantity — that is the StubHub/SeatGeek rule, not this one (§3).
-- ============================================================================

CREATE OR REPLACE VIEW public.v_sub_orders AS
  -- the six CRM marketplaces, with Vivid and GoTickets already repaired from
  -- our own books inside v_s4kcs_orders
  SELECT s.source,
         s.s4k_order_id                AS order_id,
         s.order_status,
         s.price_source                AS book,
         s.event_name,
         s.event_date,
         'crm_event_date'::text        AS date_source,
         s.venue_name,
         s.tevo_event_id,
         s.section,
         s."row",
         s.quantity,
         s.price_per_ticket,
         round(s.price_per_ticket * s.quantity, 2) AS order_total,
         s.purchase_date,
         s.inhand_date
    FROM public.v_s4kcs_orders s
  UNION ALL
  -- EVO / TEvo exchange — absent from the CRM entirely, so purely additive
  SELECT 'EVO'::text,
         i.evo_order_id::text,
         o.state,
         'evo_orders'::text,
         i.event_name,
         COALESCE(left(e.occurs_at_local, 10)::date, (i.occurs_at)::date),
         CASE WHEN e.occurs_at_local IS NOT NULL
              THEN 'events.occurs_at_local'::text     -- local, correct
              ELSE 'evo_occurs_at_utc'::text          -- UTC cast, may be off by a day
         END,
         i.venue_name,
         i.event_id,
         i.ticket_group_section,
         i.ticket_group_row,
         i.quantity,
         i.price,                                     -- PER TICKET (verified)
         round(i.price * i.quantity, 2),
         o.evo_created_at::date,
         NULL::date
    FROM public.evo_order_items i
    JOIN public.evo_orders o ON o.evo_order_id = i.evo_order_id
    LEFT JOIN public.events e ON e.id = i.event_id
   WHERE i.event_id IS NOT NULL;

COMMENT ON VIEW public.v_sub_orders IS
  'One order feed for the substitution pipeline: our own book wherever we have '
  'a usable one (Vivid, GoTickets, EVO), the S4K CRM only for marketplaces we '
  'do not (StubHub, Gametime — plus SeatGeek and TickPick, whose own books are '
  'unusable: seatgeek_orders is live but 400 rows with ZERO mapped to an event, '
  'tickpick_orders is well-mapped but its ingest died 2026-05-31). EVO is '
  'unioned in because the CRM does not carry it at all. price_per_ticket is '
  'normalised for every source; `book` says which book supplied the price and '
  '`date_source` which clock supplied event_date.';

REVOKE ALL ON public.v_sub_orders FROM PUBLIC, anon;
GRANT SELECT ON public.v_sub_orders TO authenticated, service_role;
