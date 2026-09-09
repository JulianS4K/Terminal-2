-- ============================================================================
-- Migration 20260909223000 — s4kcs_sub_candidates(): substitute finder for
--                            CRM orders that need replacement tickets
--
-- Lane:     D0 (CRM orders surface) reading A1's GoTickets listings
-- Touches:  seat_row_kind() / seat_row_rank() / s4kcs_price_per_ticket()
--           (CREATE FUNCTION, immutable helpers),
--           s4kcs_sub_candidates() (CREATE FUNCTION, read-only),
--           v_s4kcs_sub_status (CREATE VIEW — the status vocabulary)
--           reads s4kcs_orders, aq_event_map, gotickets_listings_snapshots
-- Pre-reqs: 20260901180000 (s4kcs_orders ingest)
--
-- READ-ONLY: every function here is a pure SELECT. No upstream call, no write.
--
-- Finds, for a CRM order that needs substituting, GoTickets listings that are
-- SAME SECTION, SAME ROW OR BETTER, and cover the ORDER QUANTITY -- reported
-- with both per-ticket and TOTAL economics.
--
-- ── Three landmines this function exists to encode ──────────────────────────
--
-- 1. PRICE UNIT IS PER-SOURCE. s4kcs_orders.price means different things by
--    marketplace, and neither the column nor raw->>'price' says which:
--      StubHub, SeatGeek  -> ORDER TOTAL
--      Gametime, TickPick -> PER TICKET
--      GoTickets          -> always 0.00 (feed gap; NOT null, so COALESCE
--                            cannot catch it -- see RESOURCES_BIBLE §1)
--      Vivid Seats        -> always NULL (feed gap)
--    Established 2026-09-09 by ratio test against live GoTickets all-in prices
--    over 11k future orders: median (price / market) vs (price/qty / market).
--    StubHub 2.12 vs 0.75; Gametime 0.72 vs 0.26. Corroborated exactly by two
--    feeds carrying the SAME seats -- StubHub order 653431804 and Gametime
--    order S22BUTV5II, both Jets@Patriots sec 130 row 16: 460.82 vs 461.00.
--    Getting this wrong inflates every StubHub margin by the quantity multiple.
--
-- 2. SECTION STRINGS DIFFER BY FEED. CRM writes a bare number ("428"); GT
--    writes "400s Level 428", "Upper 335", "Lower 130", "Section 145A".
--    Taking the FIRST digit run maps "400s Level 428" -> "400" (wrong level).
--    We anchor the CRM section to the END of the GT string, which also
--    correctly rejects "Section 145A"/"145B" for section 145 and "Club 325C"
--    for 325. Same-number-different-place pairs survive that anchor, though
--    ("Club 130" vs "VIP 130"), so p_exclude_qualified defaults true and drops
--    premium-area prefixes -- a Club seat is not the plain section.
--    The section value is regex-escaped: it is feed data, not a literal.
--
-- 3. ROWS COMPARE WITHIN THEIR OWN KIND. Numeric rows rank by value; letter
--    rows rank A..Z = 1..26 and continue past Z for two-letter rows, so a
--    double letter always sorts behind any single letter. That ordering holds
--    under both real conventions (AA/BB/CC doubling and AA/AB/AC). A numeric
--    order row is NEVER compared against a letter listing row or vice versa --
--    there is no defensible ordering between them, so those are dropped rather
--    than guessed. CAVEAT: a venue that letters AA/BB in FRONT of row A would
--    invert; that is not modelled.
-- ============================================================================

-- ── 1. Row ordering helpers ─────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.seat_row_kind(p_row text)
RETURNS text LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
  SELECT CASE
           WHEN p_row ~ '^[0-9]+$'        THEN 'n'
           WHEN p_row ~ '^[A-Za-z]{1,2}$' THEN 'a'
         END;
$$;
COMMENT ON FUNCTION public.seat_row_kind(text) IS
  'Row comparison class: n = numeric, a = 1-2 letters, NULL = uncomparable. '
  'Rows of different kinds must never be ordered against each other.';

CREATE OR REPLACE FUNCTION public.seat_row_rank(p_row text)
RETURNS integer LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
  SELECT CASE
           WHEN p_row ~ '^[0-9]+$'      THEN p_row::integer
           WHEN p_row ~ '^[A-Za-z]$'    THEN ascii(upper(p_row)) - 64
           WHEN p_row ~ '^[A-Za-z]{2}$' THEN (ascii(upper(left(p_row,1))) - 64) * 26
                                           + (ascii(upper(right(p_row,1))) - 64)
         END;
$$;
COMMENT ON FUNCTION public.seat_row_rank(text) IS
  'Lower = closer to the field/stage. A..Z = 1..26; two-letter rows continue '
  'past Z (AA=27, BB=54, JJ=270) so doubles always sort behind singles -- true '
  'under both the AA/BB/CC and AA/AB/AC conventions. Compare only within the '
  'same seat_row_kind().';

-- ── 2. Per-source price unit (landmine 1) ───────────────────────────────────
CREATE OR REPLACE FUNCTION public.s4kcs_price_per_ticket(
  p_source text, p_price numeric, p_quantity integer)
RETURNS numeric LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
  SELECT CASE
           -- feed gaps: no usable price at all
           WHEN p_price IS NULL OR p_price = 0 THEN NULL
           -- these two ship the ORDER TOTAL
           WHEN p_source IN ('StubHub','SeatGeek')
             THEN p_price / NULLIF(p_quantity, 0)
           -- Gametime / TickPick (and anything new) ship PER TICKET
           ELSE p_price
         END;
$$;
COMMENT ON FUNCTION public.s4kcs_price_per_ticket(text,numeric,integer) IS
  'Normalises s4kcs_orders.price to PER TICKET. StubHub/SeatGeek store the '
  'order total; Gametime/TickPick store per-ticket; GoTickets is always 0.00 '
  'and Vivid always NULL (feed gaps) -> NULL. Never compare a raw .price '
  'across sources without this.';

-- ── 3. The status vocabulary that means "this order needs replacing" ────────
CREATE OR REPLACE VIEW public.v_s4kcs_sub_status AS
  SELECT * FROM (VALUES
    ('Issue reported: replacement tickets offered', 'explicit'),
    ('Re-Transfer Ticket',                          'explicit'),
    ('REJECTED',                                    'explicit'),
    ('Issue',                                       'explicit'),
    ('Under Review',                                'probable'),
    ('Re-enter Barcodes',                           'probable'),
    ('unconfirmed',                                 'at_risk')
  ) AS t(order_status, sub_signal);
COMMENT ON VIEW public.v_s4kcs_sub_status IS
  'CRM order_status values that indicate a substitute may be needed. The CRM '
  'has no literal "need to sub" status -- its N2S book is a separate API '
  'surface (crm.s4kcs.com/api/v1/n2s/*) that is NOT ingested. These are the '
  'in-database proxies.';

-- ── 4. The finder ───────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.s4kcs_sub_candidates(
  p_statuses          text[]   DEFAULT NULL,      -- NULL = all sub-signal statuses
  p_max_listing_age   interval DEFAULT interval '12 hours',
  p_per_order         integer  DEFAULT 3,
  p_exclude_qualified boolean  DEFAULT true       -- drop Club/VIP/Charter/etc
)
RETURNS TABLE (
  source          text,
  order_status    text,
  sub_signal      text,
  s4k_order_id    text,
  event_name      text,
  event_date      date,
  venue_name      text,
  tevo_event_id   bigint,
  section         text,
  order_row       text,
  quantity        integer,
  sold_ea         numeric,
  sold_total      numeric,
  gt_listing_id   bigint,
  gt_section      text,
  sub_row         text,
  sub_qty         integer,
  sub_ea          numeric,
  sub_total       numeric,
  margin_ea       numeric,
  margin_total    numeric,
  rows_closer     integer,
  captured_at     timestamptz
)
LANGUAGE sql STABLE PARALLEL SAFE
SET search_path TO 'public','pg_temp'
AS $$
  WITH o AS (
    SELECT s.source, s.order_status, v.sub_signal, s.s4k_order_id,
           s.event_name, s.event_date, s.venue_name, s.tevo_event_id,
           s.section, s."row" AS order_row, s.quantity,
           public.s4kcs_price_per_ticket(s.source, s.price, s.quantity) AS sold_ea,
           public.seat_row_kind(s."row") AS ord_kind,
           public.seat_row_rank(s."row") AS ord_rank,
           -- landmine 2: section is feed data, escape it before regex use
           regexp_replace(s.section, '([.^$*+?()\[\]{}|\\-])', '\\\1', 'g') AS sec_re
      FROM public.s4kcs_orders s
      JOIN public.v_s4kcs_sub_status v ON v.order_status = s.order_status
     WHERE s.event_date >= current_date
       AND s.tevo_event_id IS NOT NULL
       AND (p_statuses IS NULL OR s.order_status = ANY(p_statuses))
       AND public.seat_row_kind(s."row") IS NOT NULL
  ),
  l AS (  -- latest snapshot per GoTickets listing, only the events we need
    SELECT DISTINCT ON (g.gt_listing_id)
           g.gt_listing_id, g.tevo_event_id, g.section AS gt_section,
           g."row" AS sub_row, g.quantity AS sub_qty, g.all_in_price, g.captured_at
      FROM public.gotickets_listings_snapshots g
     WHERE g.tevo_event_id IN (SELECT DISTINCT tevo_event_id FROM o)
       AND g.captured_at >= now() - p_max_listing_age
     ORDER BY g.gt_listing_id, g.captured_at DESC
  ),
  m AS (
    SELECT o.source, o.order_status, o.sub_signal, o.s4k_order_id, o.event_name,
           o.event_date, o.venue_name, o.tevo_event_id, o.section, o.order_row,
           o.quantity, o.sold_ea,
           round(o.sold_ea * o.quantity, 2)                       AS sold_total,
           l.gt_listing_id, l.gt_section, l.sub_row, l.sub_qty,
           l.all_in_price                                         AS sub_ea,
           round(l.all_in_price * o.quantity, 2)                  AS sub_total,
           round(o.sold_ea - l.all_in_price, 2)                   AS margin_ea,
           round((o.sold_ea - l.all_in_price) * o.quantity, 2)    AS margin_total,
           (o.ord_rank - public.seat_row_rank(l.sub_row))         AS rows_closer,
           l.captured_at,
           row_number() OVER (PARTITION BY o.source, o.s4k_order_id
                              ORDER BY l.all_in_price) AS rn
      FROM o
      JOIN l ON l.tevo_event_id = o.tevo_event_id
       -- SECTION: CRM number anchored to the END of the GT section string
       AND l.gt_section ~ ('(^|[^0-9A-Za-z])' || o.sec_re || '$')
       AND (NOT p_exclude_qualified
            OR l.gt_section !~* '^(club|vip|owner|charter|suite|standing room|premium|loge box)')
       -- QUANTITY: one listing must cover the whole order
       AND l.sub_qty >= o.quantity
       -- ROW: same kind only, and same row or closer
       AND public.seat_row_kind(l.sub_row) = o.ord_kind
       AND public.seat_row_rank(l.sub_row) <= o.ord_rank
  )
  SELECT source, order_status, sub_signal, s4k_order_id, event_name, event_date,
         venue_name, tevo_event_id, section, order_row, quantity,
         sold_ea, sold_total, gt_listing_id, gt_section, sub_row, sub_qty,
         sub_ea, sub_total, margin_ea, margin_total, rows_closer, captured_at
    FROM m
   WHERE rn <= p_per_order
   ORDER BY margin_total DESC NULLS LAST, s4k_order_id, sub_ea;
$$;

COMMENT ON FUNCTION public.s4kcs_sub_candidates(text[],interval,integer,boolean) IS
  'Substitute GoTickets listings for CRM orders needing replacement. Matches on '
  'SECTION (CRM number anchored to end of GT section string, premium prefixes '
  'excluded by default), ROW (same kind, same-or-closer via seat_row_rank), and '
  'QUANTITY (one listing covers the whole order); reports per-ticket AND total '
  'economics. Prices normalised per-source by s4kcs_price_per_ticket() -- '
  'StubHub/SeatGeek rows carry the ORDER TOTAL. Read-only. NOTE: quantity is '
  'single-listing; orders needing a multi-listing fill are reported as no-match.';

REVOKE ALL ON FUNCTION public.s4kcs_sub_candidates(text[],interval,integer,boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.s4kcs_sub_candidates(text[],interval,integer,boolean) TO authenticated, service_role;
