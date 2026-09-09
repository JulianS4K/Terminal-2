-- ============================================================================
-- Migration 20260909223000 — s4kcs_sub_candidates(): substitute finder for
--                            CRM orders that need replacement tickets
--
-- Lane:     D0 (CRM orders surface) reading A1's three listing snapshot tables
-- Touches:  seat_row_kind() / seat_row_rank() / s4kcs_price_per_ticket()
--           (CREATE FUNCTION, immutable helpers),
--           s4kcs_sub_candidates() (CREATE FUNCTION, read-only),
--           v_s4kcs_sub_status (CREATE VIEW — the status vocabulary)
--           seat_section_norm() / seat_section_qualifier() (CREATE FUNCTION),
--           reads s4kcs_orders + listings_snapshots (TEvo) +
--           gotickets_listings_snapshots + seatgeek_listings_snapshots
-- Pre-reqs: 20260901180000 (s4kcs_orders ingest),
--           20260909220000 (v_s4kcs_orders + price_per_ticket — read, never re-derived)
--
-- READ-ONLY: every function here is a pure SELECT. No upstream call, no write.
--
-- Finds, for EVERY CRM order across EVERY marketplace, listings from THREE
-- supply sources -- TEvo, GoTickets and SeatGeek -- that could replace it:
-- SAME SECTION, SAME ROW OR BETTER, SAME QUANTITY, and a TOTAL no higher than
-- the order sold for. Emits a buy_url where the format is documented.
--
-- ── Landmine 4: the three sources are three different schemas ───────────────
--   source     event key             listing id             price used
--   TEvo       event_id              tevo_ticket_group_id   retail_price
--   GoTickets  tevo_event_id         gt_listing_id          all_in_price
--   SeatGeek   tevo_event_id         sglid                  retail_price_all_in
-- `listings_snapshots.retail_price` and `.wholesale_price` are IDENTICAL in
-- every row sampled (15,543 across 5 events, 0 differing), so the broker/retail
-- distinction is moot in this data. TEvo retail excludes buyer fees that GT's
-- all-in includes, so the bases are not identical in theory -- measured
-- like-for-like they agree to ~1%: 904 pairs matched on section+row+quantity
-- for event 3287886 give a median GT-all-in / TEvo-retail ratio of 0.989.
-- Close enough to rank across sources; `sub_price_basis` is emitted so a
-- caller can always see which basis a row used.
--
-- ⚠ OUR OWN INVENTORY IS NOT A SUBSTITUTE. TEvo `is_owned` and SeatGeek
-- `is_broker_owned` are excluded -- buying our own ticket back replaces
-- nothing. On event 3287886 that is 1,002 of 1,944 TEvo rows, so omitting the
-- filter would fill the results with our own listings. GoTickets has no such
-- flag (it is a buy-side scrape of other sellers), so none is applied there.
-- TEvo `is_ancillary` (parking and passes) is excluded too.
--
-- ⚠ SEATGEEK LISTINGS ARE STALE. `seatgeek_listings_snapshots` last captured
-- 2026-06-26 -- 75 days before this migration -- because crons 355
-- `sg_listings_poll_owned_1min`, 236 and 64 are all INACTIVE. The SeatGeek arm
-- is therefore wired and correct but contributes ZERO rows until that poller
-- is restarted. It is included deliberately so the function is complete the
-- day it comes back; `p_max_listing_age` naturally excludes it until then.
--
-- Defaults are the "show me what I can actually replace" question: every source,
-- every status, only subs that are same-total-or-cheaper. Widen deliberately --
-- p_require_cheaper=false to see the underwater options too, p_exact_qty=false
-- to allow a larger listing (which costs more in total unless splits apply).
--
-- ── Three landmines this function exists to encode ──────────────────────────
--
-- 1. PRICE UNIT IS PER-SOURCE. s4kcs_orders.price means different things by
--    marketplace, and neither the column nor raw->>'price' says which:
--      StubHub, SeatGeek  -> ORDER TOTAL
--      Gametime, TickPick -> PER TICKET
--      GoTickets          -> CRM ships 0.00; REPAIRED from gotickets_sales
--      Vivid Seats        -> CRM ships NULL; REPAIRED from vivid_orders
--    Both repairs live in v_s4kcs_orders, which this function reads, so all six
--    marketplaces now carry a usable price.
--    Established 2026-09-09 by ratio test against live GoTickets all-in prices
--    over 11k future orders: median (price / market) vs (price/qty / market).
--    StubHub 2.12 vs 0.75; Gametime 0.72 vs 0.26. Corroborated exactly by two
--    feeds carrying the SAME seats -- StubHub order 653431804 and Gametime
--    order S22BUTV5II, both Jets@Patriots sec 130 row 16: 460.82 vs 461.00.
--    Getting this wrong inflates every StubHub margin by the quantity multiple.
--
-- 2. SECTION STRINGS DIFFER BY FEED, so everything is NORMALISED first.
--    CRM writes a bare "428", TEvo "428", GoTickets "400s Level 428" /
--    "Upper 335" / "Third Base Box 7", SeatGeek "Section 145A".
--    seat_section_norm() reduces all of them to a shared token and the match is
--    plain equality -- no per-call regex over feed data. Taking the FIRST digit
--    run would map "400s Level 428" -> "400", the wrong level, so the TRAILING
--    digit-bearing word is used. Trailing letters are kept, so "145A"/"145B"
--    stay distinct and neither equals "145"; interior whitespace is collapsed,
--    so "Promenade  311" still normalises to "311" (an end-anchored regex, the
--    earlier approach, missed exactly that case).
--    Normalisation alone is NOT sufficient: it strips the qualifier, so
--    "Club 130" and a premium box like "centennial club cr 6" both collapse
--    onto a plain section number. seat_section_qualifier() + p_exclude_qualified
--    guard that -- on BOTH sides, listing AND order (see the o CTE).
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

-- ── 1b. Section normalisers ────────────────────────────────────────────────
-- Every feed writes the same physical seat block differently: the CRM writes a
-- bare "428", TEvo "428", GoTickets "400s Level 428" / "Upper 335" /
-- "Third Base Box 7", SeatGeek "Section 145A". Normalising once, here, is what
-- lets the three supply sources and the order be compared at all.
--
-- The section TOKEN is the trailing whitespace-delimited word when it contains
-- a digit ("400s Level 428" -> "428", "Third Base Box 7" -> "7", "Field 114B"
-- -> "114B"); otherwise the whole string ("Mezzanine Center"). Never take the
-- FIRST digit run -- "400s Level 428" would become "400", the wrong level.
-- Trailing letters are KEPT, so "145A" and "145B" stay distinct blocks and
-- neither equals "145". Interior whitespace is collapsed, so a feed writing
-- "Promenade  311" with a double space still normalises to "311".
CREATE OR REPLACE FUNCTION public.seat_section_norm(p_section text)
RETURNS text LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
  WITH c AS (SELECT btrim(regexp_replace(coalesce(p_section,''), '\s+', ' ', 'g')) AS v)
  SELECT CASE
           WHEN c.v = '' THEN NULL
           WHEN split_part(c.v, ' ', array_length(string_to_array(c.v,' '),1)) ~ '[0-9]'
             THEN upper(split_part(c.v, ' ', array_length(string_to_array(c.v,' '),1)))
           ELSE upper(c.v)
         END
  FROM c;
$$;
COMMENT ON FUNCTION public.seat_section_norm(text) IS
  'Canonical section token shared by the CRM, TEvo, GoTickets and SeatGeek. '
  'Trailing digit-bearing word ("400s Level 428"->"428"), else the whole string. '
  'Keeps trailing letters so 145A != 145B != 145. NEVER take the first digit run.';

-- The words BEFORE the token. "Club 130" -> "CLUB". A premium qualifier means a
-- different physical product sharing a number, so "Club 130" is NOT section 130
-- -- normalisation alone cannot separate them, the qualifier has to.
CREATE OR REPLACE FUNCTION public.seat_section_qualifier(p_section text)
RETURNS text LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
  WITH c AS (SELECT btrim(regexp_replace(coalesce(p_section,''), '\s+', ' ', 'g')) AS v)
  SELECT CASE
           WHEN c.v = '' THEN NULL
           WHEN split_part(c.v, ' ', array_length(string_to_array(c.v,' '),1)) ~ '[0-9]'
             THEN upper(btrim(left(c.v, length(c.v)
                  - length(split_part(c.v,' ',array_length(string_to_array(c.v,' '),1))))))
           ELSE ''
         END
  FROM c;
$$;
COMMENT ON FUNCTION public.seat_section_qualifier(text) IS
  'Leading words of a section label ("400s Level 428"->"400S LEVEL", "Club 130"->'
  '"CLUB", "428"->""). Used to drop premium areas that share a plain section number.';

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
  p_sources           text[]   DEFAULT NULL,      -- NULL = every marketplace we SOLD on
  p_statuses          text[]   DEFAULT NULL,      -- NULL = every order status
  p_sub_sources       text[]   DEFAULT NULL,      -- NULL = tevo + gotickets + seatgeek
  p_require_cheaper   boolean  DEFAULT true,      -- sub total <= what it sold for
  p_exact_qty         boolean  DEFAULT true,      -- listing quantity == order quantity
  p_max_listing_age   interval DEFAULT interval '12 hours',
  p_per_order         integer  DEFAULT 3,
  p_exclude_qualified boolean  DEFAULT true,      -- drop Club/VIP/Charter/etc
  p_event_ids         bigint[] DEFAULT NULL       -- NULL = all future events
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
  sub_source      text,
  sub_price_basis text,
  sub_listing_id  bigint,
  sub_section     text,
  sub_row         text,
  sub_qty         integer,
  sub_ea          numeric,
  sub_total       numeric,
  margin_ea       numeric,
  margin_total    numeric,
  rows_closer     integer,
  buy_url         text,
  captured_at     timestamptz
)
LANGUAGE sql STABLE PARALLEL SAFE
SET search_path TO 'public','pg_temp'
AS $$
  WITH o AS (
    SELECT s.source, s.order_status, v.sub_signal, s.s4k_order_id,
           s.event_name, s.event_date, s.venue_name, s.tevo_event_id,
           s.section, s."row" AS order_row, s.quantity,
           s.price_per_ticket AS sold_ea,
           public.seat_row_kind(s."row") AS ord_kind,
           public.seat_row_rank(s."row") AS ord_rank,
           public.seat_section_norm(s.section) AS sec_norm
      -- v_s4kcs_orders, never s4kcs_orders: the view repairs the two
      -- price-less feeds from our own books and exposes price_per_ticket, so
      -- no caller re-derives the per-source unit rule (§3).
      FROM public.v_s4kcs_orders s
      LEFT JOIN public.v_s4kcs_sub_status v ON v.order_status = s.order_status
     WHERE s.event_date >= current_date
       AND s.tevo_event_id IS NOT NULL
       AND (p_sources   IS NULL OR s.source        = ANY(p_sources))
       AND (p_statuses  IS NULL OR s.order_status  = ANY(p_statuses))
       AND (p_event_ids IS NULL OR s.tevo_event_id = ANY(p_event_ids))
       AND public.seat_row_kind(s."row") IS NOT NULL
       AND s.price_per_ticket IS NOT NULL
       -- ⚠ THE ORDER SIDE NEEDS THE PREMIUM GUARD TOO. Normalising takes the
       -- trailing token, so a premium box like "centennial club cr 6" reduces to
       -- "6" and would match plain section 6 -- a different product entirely.
       -- Caught live: StubHub order 650812106 (Ohio State at Texas) sold at
       -- $5,880/ticket in "centennial club cr 6" and matched a $1,570 seat in
       -- section 6, inventing an $8,618 "gain". Guarding only the listing side
       -- misses this, because it is the ORDER whose label carries the qualifier.
       AND (NOT p_exclude_qualified
            OR public.seat_section_qualifier(s.section)
               !~ '(CLUB|VIP|OWNER|CHARTER|SUITE|STANDING ROOM|PREMIUM|LOGE BOX|BOX)')
  ),
  ev AS (SELECT DISTINCT tevo_event_id FROM o),
  -- ── One PINNED capture per event, per source ──────────────────────────────
  -- NOT `DISTINCT ON (listing_id) ORDER BY captured_at DESC` over the window:
  -- that returns the last state of every listing SEEN in the window, including
  -- ones that sold hours ago, so it offers substitutes that no longer exist.
  -- Pinning each event to its most recent capture returns the live book only.
  -- It is also far cheaper -- TEvo polls every 2 min, so a 12h window is ~360
  -- captures per event to sort through; the LATERAL picks one via
  -- idx_listings_event_time / idx_gt_ls_event_time / idx_sg_listings_event_at.
  pin_tevo AS (
    SELECT ev.tevo_event_id, x.captured_at
      FROM ev CROSS JOIN LATERAL (
        SELECT l2.captured_at FROM public.listings_snapshots l2
         WHERE l2.event_id = ev.tevo_event_id
           AND l2.captured_at >= now() - p_max_listing_age
         ORDER BY l2.captured_at DESC LIMIT 1) x
  ),
  pin_gt AS (
    SELECT ev.tevo_event_id, x.captured_at
      FROM ev CROSS JOIN LATERAL (
        SELECT g2.captured_at FROM public.gotickets_listings_snapshots g2
         WHERE g2.tevo_event_id = ev.tevo_event_id
           AND g2.captured_at >= now() - p_max_listing_age
         ORDER BY g2.captured_at DESC LIMIT 1) x
  ),
  pin_sg AS (
    SELECT ev.tevo_event_id, x.captured_at
      FROM ev CROSS JOIN LATERAL (
        SELECT s2.captured_at FROM public.seatgeek_listings_snapshots s2
         WHERE s2.tevo_event_id = ev.tevo_event_id
           AND s2.captured_at >= now() - p_max_listing_age
         ORDER BY s2.captured_at DESC LIMIT 1) x
  ),
  -- ── the three supply sources, normalised to one shape ─────────────────────
  l_tevo AS (
    SELECT 'tevo'::text AS sub_source, 'tevo_retail'::text AS sub_price_basis,
           t.tevo_ticket_group_id AS sub_listing_id, t.event_id AS tevo_event_id,
           t.section AS sub_section, t."row" AS sub_row, t.quantity AS sub_qty,
           t.retail_price AS sub_ea, NULL::text AS buy_url, t.captured_at
      FROM pin_tevo p
      JOIN public.listings_snapshots t
        ON t.event_id = p.tevo_event_id AND t.captured_at = p.captured_at
     WHERE NOT t.is_owned          -- our own inventory replaces nothing
       AND NOT t.is_ancillary      -- parking / passes are not a seat sub
  ),
  l_gt AS (
    SELECT 'gotickets'::text, 'gt_all_in'::text,
           g.gt_listing_id, g.tevo_event_id,
           g.section, g."row", g.quantity, g.all_in_price,
           -- §6b: both ids come off the snapshot; section_id IS GT's own URL
           -- section id, so this is a lookup, never hand-mapped from the label
           'https://pro.gotickets.com/tickets/' || g.gt_event_id
             || '/?sortBy=price&sortDirection=asc&sections=' || g.section_id,
           g.captured_at
      FROM pin_gt p
      JOIN public.gotickets_listings_snapshots g
        ON g.tevo_event_id = p.tevo_event_id AND g.captured_at = p.captured_at
  ),
  l_sg AS (
    SELECT 'seatgeek'::text, 'sg_retail_all_in'::text,
           sg.sglid, sg.tevo_event_id,
           sg.section, sg."row", sg.quantity, sg.retail_price_all_in,
           NULL::text, sg.captured_at
      FROM pin_sg p
      JOIN public.seatgeek_listings_snapshots sg
        ON sg.tevo_event_id = p.tevo_event_id AND sg.captured_at = p.captured_at
     WHERE NOT sg.is_broker_owned
  ),
  l AS (
    SELECT * FROM l_tevo WHERE p_sub_sources IS NULL OR 'tevo'      = ANY(p_sub_sources)
    UNION ALL
    SELECT * FROM l_gt   WHERE p_sub_sources IS NULL OR 'gotickets' = ANY(p_sub_sources)
    UNION ALL
    SELECT * FROM l_sg   WHERE p_sub_sources IS NULL OR 'seatgeek'  = ANY(p_sub_sources)
  ),
  m AS (
    SELECT o.source, o.order_status, o.sub_signal, o.s4k_order_id, o.event_name,
           o.event_date, o.venue_name, o.tevo_event_id, o.section, o.order_row,
           o.quantity, o.sold_ea,
           round(o.sold_ea * o.quantity, 2)                 AS sold_total,
           l.sub_source, l.sub_price_basis, l.sub_listing_id,
           l.sub_section, l.sub_row, l.sub_qty, l.sub_ea,
           round(l.sub_ea * o.quantity, 2)                  AS sub_total,
           round(o.sold_ea - l.sub_ea, 2)                   AS margin_ea,
           round((o.sold_ea - l.sub_ea) * o.quantity, 2)    AS margin_total,
           (o.ord_rank - public.seat_row_rank(l.sub_row))   AS rows_closer,
           l.buy_url, l.captured_at,
           row_number() OVER (PARTITION BY o.source, o.s4k_order_id
                              ORDER BY l.sub_ea) AS rn
      FROM o
      JOIN l ON l.tevo_event_id = o.tevo_event_id
       -- SECTION: normalised token equality (see seat_section_norm)
       AND public.seat_section_norm(l.sub_section) = o.sec_norm
       AND (NOT p_exclude_qualified
            OR public.seat_section_qualifier(l.sub_section)
               !~ '(CLUB|VIP|OWNER|CHARTER|SUITE|STANDING ROOM|PREMIUM|LOGE BOX|BOX)')
       -- QUANTITY
       AND (CASE WHEN p_exact_qty THEN l.sub_qty = o.quantity
                 ELSE l.sub_qty >= o.quantity END)
       -- ROW: same kind only, and same row or closer
       AND public.seat_row_kind(l.sub_row) = o.ord_kind
       AND public.seat_row_rank(l.sub_row) <= o.ord_rank
       -- TOTAL: same or cheaper than we sold it for
       AND (NOT p_require_cheaper OR l.sub_ea * o.quantity <= o.sold_ea * o.quantity)
  )
  SELECT source, order_status, sub_signal, s4k_order_id, event_name, event_date,
         venue_name, tevo_event_id, section, order_row, quantity, sold_ea, sold_total,
         sub_source, sub_price_basis, sub_listing_id, sub_section, sub_row, sub_qty,
         sub_ea, sub_total, margin_ea, margin_total, rows_closer, buy_url, captured_at
    FROM m
   WHERE rn <= p_per_order
   ORDER BY margin_total DESC NULLS LAST, s4k_order_id, sub_ea;
$$;

COMMENT ON FUNCTION public.s4kcs_sub_candidates(text[],text[],text[],boolean,boolean,interval,integer,boolean,bigint[]) IS
  'Substitute listings for CRM orders, across THREE supply sources (TEvo, '
  'GoTickets, SeatGeek) for ALL marketplaces and ALL statuses by default. '
  'Matches on SECTION (CRM number anchored to end of the listing section string, '
  'premium prefixes excluded by default), ROW (same kind, same-or-closer via '
  'seat_row_rank), QUANTITY (exact by default) and TOTAL (sub total <= sold total '
  'by default). Emits sub_source + sub_price_basis so a cross-source ranking is '
  'always auditable; TEvo retail and GT all-in measured within ~1% like-for-like. '
  'EXCLUDES our own inventory (TEvo is_owned, SG is_broker_owned) and TEvo '
  'ancillary rows. Orders from GoTickets/Vivid are skipped -- those feeds carry no '
  'usable price (§3 landmine). buy_url is emitted for GoTickets only (§6b is the '
  'one documented deep-link format). SEATGEEK CONTRIBUTES NOTHING TODAY: its '
  'listings poller (crons 355/236/64) is inactive and the table last captured '
  '2026-06-26. Read-only. Quantity is single-listing; an order needing a '
  'multi-listing fill reports as no-match. PERFORMANCE: the full-scope call spans '
  '~1.8k future events across three snapshot tables; narrow with p_event_ids / '
  'p_sub_sources / p_max_listing_age for interactive use, else run it from a cron.';

REVOKE ALL ON FUNCTION public.s4kcs_sub_candidates(text[],text[],text[],boolean,boolean,interval,integer,boolean,bigint[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.s4kcs_sub_candidates(text[],text[],text[],boolean,boolean,interval,integer,boolean,bigint[]) TO authenticated, service_role;
