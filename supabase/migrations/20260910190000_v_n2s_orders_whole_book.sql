-- ============================================================================
-- Migration 20260910190000 — v_n2s_orders: the WHOLE N2S book, sub attached
--                            where one exists
--
-- Lane:     D0 (orders surface)
-- Touches:  v_n2s_orders (CREATE VIEW). Nothing else; no table is written.
-- Pre-reqs: 20260910120000 (n2s_cover_queue), 20260910180000
--
-- READ-ONLY upstream: no API call. A LEFT JOIN over two tables we already
-- hold. RULE 2 untouched.
--
-- Operator direction 2026-09-10: "rewrite this to show those orders and their
-- subs where available."
--
-- ── WHY ───────────────────────────────────────────────────────────────────
-- The covers panel read n2s_cover_queue directly, and that table only contains
-- orders a cover was FOUND for. Measured at the time of writing: 8 rows in the
-- queue against 105 open future obligations. So the screen showed 8 orders and
-- silently omitted 97 that still have to be settled — the ones most in need of
-- a human, because nothing automatic is going to happen to them.
--
-- An order with no cover is not an absence of data, it is the WORK. This view
-- is the whole open book with the cover LEFT JOINed on, mirroring how
-- s4kcs_sub_worklist already keeps its no-candidate rows ("this is the whole
-- book, not just the lucky ones").
--
-- ⚠ `no_cover_reason` IS THE POINT, NOT DECORATION. "No sub" collapses three
-- completely different situations, and they need opposite responses:
--   unmapped             — we cannot identify the event, so we never even
--                          looked. A mapping problem; more inventory will not
--                          help.
--   awaiting_source_pull — mapped, but the on-arrival pull of the four sources
--                          has not run yet. Wait ~2 minutes; it is in flight.
--   no_match             — we looked at live listings and none satisfied same
--                          section / same-or-better row / exact quantity. A
--                          real supply answer, and the only one of the three
--                          that means "go find tickets".
-- Showing a bare dash for all three would make the screen say "nothing here"
-- when the truth is "we haven't looked", which is how a mapping outage hides.
--
-- ⚠ THE COVER COLUMNS COME FROM A CACHE THAT IS FULLY REPLACED EVERY 2 MINUTES
-- (see 20260910120000). refreshed_at is therefore still load-bearing on this
-- view: a stale timestamp means "no answer", never "no covers". It is NULL for
-- an uncovered row, which is correct — nothing was computed for it.
--
-- ⚠ ORDERING IS NOT ARBITRARY. has_cover DESC first, because a row you can act
-- on outranks one you cannot; then cover_cost ASC (Postgres sorts NULLs last
-- on ASC, so uncovered rows fall through); then alert_at ASC so the oldest
-- unsettled obligation is top of the uncovered block. Consumers must apply
-- this themselves — a view cannot guarantee order.
-- ============================================================================

CREATE OR REPLACE VIEW public.v_n2s_orders AS
SELECT
  n.n2s_id,
  n.order_number,
  n.s4k_source,
  n.status                AS n2s_status,
  n.status_label,
  n.fail_reason,
  n.timer_expired,
  n.alert_at,
  n.timer_expires_at,
  n.event_name,
  n.event_dt::date        AS event_date,
  n.event_dt,
  n.venue,
  n.tevo_event_id,
  n.mapped_via,
  n.sources_pulled_at,
  n.section,
  n."row"                 AS order_row,
  n.qty                   AS quantity,
  n.price_per_ticket      AS sold_ea,
  n.grand_total           AS sold_total,
  -- the cover, where one exists
  c.sub_source,
  c.sub_listing_id,
  c.sub_section,
  c.sub_row,
  c.sub_qty,
  c.sub_ea,
  c.sub_total,
  c.cover_cost,
  c.rows_closer,
  c.buy_url,
  c.captured_at,
  c.cover_rank,
  c.fifo_position,
  c.refreshed_at,
  (c.n2s_id IS NOT NULL)  AS has_cover,
  CASE
    WHEN c.n2s_id IS NOT NULL          THEN NULL
    WHEN n.tevo_event_id IS NULL       THEN 'unmapped'
    WHEN n.sources_pulled_at IS NULL   THEN 'awaiting_source_pull'
    ELSE                                    'no_match'
  END                     AS no_cover_reason,
  -- an intent someone has already opened on this order, so two people do not
  -- pick up the same obligation. NULL when nobody has claimed it.
  b.intent_id             AS open_intent_id,
  b.requested_by          AS open_intent_by
  FROM public.n2s_items n
  LEFT JOIN public.n2s_cover_queue c ON c.n2s_id = n.n2s_id
  LEFT JOIN public.n2s_buy_intent  b ON b.n2s_id = n.n2s_id AND b.status = 'requested'
 WHERE NOT n.is_terminal;

COMMENT ON VIEW public.v_n2s_orders IS
  'Every OPEN N2S obligation with its allocated cover LEFT JOINed on. Rows '
  'without a cover are kept deliberately — they are the work, not missing '
  'data. no_cover_reason separates "we never looked" (unmapped), "in flight" '
  '(awaiting_source_pull) and "we looked and nothing matched" (no_match), '
  'which need opposite responses. Order by has_cover DESC, cover_cost ASC, '
  'alert_at ASC. See migration 20260910190000.';

REVOKE ALL ON public.v_n2s_orders FROM PUBLIC, anon;
GRANT SELECT ON public.v_n2s_orders TO authenticated, service_role;
