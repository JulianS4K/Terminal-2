-- ============================================================================
-- Migration 20260910260000 — one seat over, only when nothing fits
--
-- Lane:     D0 (orders surface)
-- Touches:  n2s_cover_candidates() (CREATE OR REPLACE — return type unchanged),
--           n2s_covers() (allocator tiebreak).
-- Pre-reqs: 20260910250000
--
-- READ-ONLY upstream: no API call. Pure SQL over already-ingested listings.
-- RULE 2 untouched.
--
-- Operator direction 2026-09-10: "if still no results, look at next qty up so
-- 4 tickets for a 3 pack, and if 4 tickets in same section and same row, or
-- better, is cheaper than 3 include it."
--
-- ── WHAT CHANGED ──────────────────────────────────────────────────────────
-- 20260910250000 let us take PART of a bigger listing when the seller's splits
-- allowed it. That still leaves the all-or-nothing lot stranded: a 3-seat
-- listing with splits {3} cannot cover a 2-seat obligation, because you cannot
-- buy 2 of it. The only way to use it is to buy the whole thing and eat the
-- spare seat.
--
-- So the matcher now has two tiers:
--
--   TIER 1 (unchanged) — deliver EXACTLY what is owed. Either the listing is
--     the right size, or its splits permit buying the owed quantity out of a
--     bigger one. Nothing here has loosened.
--
--   TIER 2 (new) — over-deliver by exactly one seat. A listing of
--     quantity + 1, same section, same-or-better row, bought WHOLE. We pay for
--     a seat we do not owe; the obligation is still settled.
--
-- ⚠ TIER 2 IS A FALLBACK, NOT AN ALTERNATIVE. "If still no results" is the
-- operative clause: an order that has any tier-1 candidate never gets covered
-- by a tier-2 one, EVEN IF THE TIER-2 TOTAL IS LOWER. Two places enforce that,
-- and both are needed:
--   1. the candidate rank orders by tier first, so p_per_order truncation can
--      never drop a tier-1 row in favour of a cheaper tier-2 one; and
--   2. n2s_covers()'s allocator — which picks by cover_cost, NOT by
--      cover_rank — gains (sub_qty > quantity) as its leading sort key.
-- Fixing only the rank would leave the allocator free to buy the spare seat.
-- Measured on the live book before writing this: the number of orders where a
-- tier-2 outlay would undercut a tier-1 outlay is 0, so this ordering costs
-- nothing today; it is here so the rule holds when prices move.
--
-- ⚠ WHY +1 AND NOT "ANY BIGGER LOT". "Next qty up" is the instruction, and the
-- book shows why it is the right bound. Of the three uncovered orders with a
-- larger same-section/same-or-better-row lot available, the unbounded reading
-- would buy a 6-seat lot at $1,223.42/ea to settle a ONE-seat obligation that
-- sold for $1,347.14 — a $7,340 outlay carrying five spare seats. Surplus is
-- capped at one seat because the second spare seat is never incidental.
--
-- ⚠ THE WHOLE LOT MUST ITSELF BE PURCHASABLE. Tier 2 buys every seat in the
-- listing, so the lot size has to be one the seller actually sells: splits
-- must contain q. Almost always true (102 of ~1.25M live listings fail it),
-- but a 4-seat listing with splits {2} sells only in pairs and would have us
-- send a buy for a quantity the vendor will reject. NULL splits (TicketsData
-- publishes none) are treated as "buy it as listed" — the whole lot is the
-- listing, so there is nothing for splits to forbid. Note this is the opposite
-- NULL handling to tier 1, deliberately: tier 1 needs splits to PROVE a
-- partial take is allowed, tier 2 needs them only to DISPROVE a whole one.
--
-- ⚠ sub_qty IS WHAT WE PAY FOR, AND ON TIER 2 THAT EXCEEDS WHAT WE OWE. It
-- feeds the vendor payload's `quantity` in n2s_buy_intent_create(), so on a
-- tier-2 cover it is the listing's size — buy 3 to settle 2. `quantity` stays
-- the obligation. The panel reads (sub_qty > quantity) as "over-delivery" and
-- says so; sub_avail > sub_qty stays "split take". The two are exclusive: a
-- tier-2 cover takes the whole lot, so sub_avail = sub_qty there.
--
-- ⚠ THE ECONOMICS NOW MULTIPLY BY WHAT WE BUY, NOT BY WHAT WE SOLD. sub_total
-- and cover_cost previously used the order quantity, which was the same number
-- on every tier-1 cover. Written out:
--     sub_total  = ea * sub_qty                    (outlay)
--     cover_cost = ea * sub_qty - sold_ea * quantity  (outlay less revenue)
-- On tier 1 sub_qty = quantity, so this is algebraically identical to the old
-- (ea - sold_ea) * quantity and every existing cover keeps its number. On
-- tier 2 it charges the spare seat to the cover, which is the only honest
-- reading of "what will this obligation cost to settle" — that spare seat is
-- money out with no sale against it.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.n2s_cover_candidates(
  p_n2s_ids         bigint[] DEFAULT NULL,
  p_max_listing_age interval DEFAULT interval '1 hour',
  p_per_order       integer  DEFAULT 3,
  p_sub_sources     text[]   DEFAULT NULL
)
RETURNS TABLE (
  n2s_id bigint, order_number text, s4k_source text, n2s_status text,
  fail_reason text, timer_expired boolean, event_name text, event_date date,
  venue text, tevo_event_id bigint, section text, order_row text,
  quantity integer, sold_ea numeric, sub_source text, sub_listing_id text,
  sub_section text, sub_row text, sub_qty integer, sub_avail integer,
  sub_ea numeric, sub_total numeric, cover_cost numeric, rows_closer integer,
  buy_url text, captured_at timestamptz, cover_rank bigint
)
LANGUAGE sql STABLE
SET search_path TO 'public','pg_temp'
AS $$
  WITH o AS (
    SELECT i.n2s_id, i.order_number, i.s4k_source, i.status, i.fail_reason,
           i.timer_expired, i.event_name, i.event_dt::date AS event_date,
           i.venue, i.tevo_event_id, i.section, i."row" AS order_row,
           i.qty AS quantity, i.price_per_ticket AS sold_ea,
           public.seat_row_kind(i."row")    AS ord_kind,
           public.seat_row_rank(i."row")    AS ord_rank,
           public.seat_section_norm(i.section) AS sec_norm
      FROM public.n2s_items i
     WHERE NOT i.is_terminal
       AND i.tevo_event_id IS NOT NULL
       AND i.event_dt::date >= current_date
       AND (p_n2s_ids IS NULL OR i.n2s_id = ANY(p_n2s_ids))
  ),
  ev AS (SELECT DISTINCT tevo_event_id AS eid FROM o),
  p_tevo AS (
    SELECT ev.eid, x.captured_at FROM ev
    CROSS JOIN LATERAL (
      SELECT s.captured_at FROM public.listings_snapshots s
       WHERE s.event_id = ev.eid AND s.captured_at >= now() - p_max_listing_age
       ORDER BY s.captured_at DESC LIMIT 1) x
  ),
  p_gt AS (
    SELECT ev.eid, x.captured_at FROM ev
    CROSS JOIN LATERAL (
      SELECT s.captured_at FROM public.gotickets_listings_snapshots s
       WHERE s.tevo_event_id = ev.eid AND s.captured_at >= now() - p_max_listing_age
       ORDER BY s.captured_at DESC LIMIT 1) x
  ),
  p_sg AS (
    SELECT ev.eid, x.captured_at FROM ev
    CROSS JOIN LATERAL (
      SELECT s.captured_at FROM public.seatgeek_listings_snapshots s
       WHERE s.tevo_event_id = ev.eid AND s.captured_at >= now() - p_max_listing_age
       ORDER BY s.captured_at DESC LIMIT 1) x
  ),
  td_cur AS (
    SELECT DISTINCT ON (t.event_id, t.platform, t.td_listing_id)
           t.event_id AS eid, t.platform, t.td_listing_id, t.section, t."row",
           t.quantity, t.price_with_fees, t.list_price, t.is_parking, t.captured_at
      FROM public.ticketsdata_listings_snapshots t
     WHERE t.event_id IN (SELECT eid FROM ev)
       AND t.captured_at >= now() - p_max_listing_age
     ORDER BY t.event_id, t.platform, t.td_listing_id, t.captured_at DESC
  ),
  l AS (
    SELECT 'tevo'::text AS src, t.tevo_ticket_group_id::text AS lid, t.event_id AS eid,
           t.section AS sec, t."row" AS rw, t.quantity AS q, t.retail_price AS ea,
           NULL::text AS url, t.captured_at, t.splits
      FROM p_tevo p JOIN public.listings_snapshots t
        ON t.event_id = p.eid AND t.captured_at = p.captured_at
     WHERE NOT t.is_owned AND NOT t.is_ancillary
       AND (p_sub_sources IS NULL OR 'tevo' = ANY(p_sub_sources))
    UNION ALL
    SELECT 'gotickets', g.gt_listing_id::text, g.tevo_event_id,
           g.section, g."row", g.quantity, g.all_in_price,
           'https://pro.gotickets.com/tickets/' || g.gt_event_id
             || '/?sortBy=price&sortDirection=asc&sections=' || g.section_id,
           g.captured_at, g.splits
      FROM p_gt p JOIN public.gotickets_listings_snapshots g
        ON g.tevo_event_id = p.eid AND g.captured_at = p.captured_at
     WHERE (p_sub_sources IS NULL OR 'gotickets' = ANY(p_sub_sources))
    UNION ALL
    -- SeatGeek stores splits as jsonb. Guard on jsonb_typeof: a non-array
    -- (or SQL NULL) would make jsonb_array_elements_text raise, and an
    -- unparseable splits list must fall back to STRICT, not to an error.
    SELECT 'seatgeek', sg.sglid::text, sg.tevo_event_id,
           sg.section, sg."row", sg.quantity, sg.retail_price_all_in,
           NULL::text, sg.captured_at,
           CASE WHEN jsonb_typeof(sg.splits) = 'array'
                THEN ARRAY(SELECT jsonb_array_elements_text(sg.splits)::int)
                ELSE NULL::int[] END
      FROM p_sg p JOIN public.seatgeek_listings_snapshots sg
        ON sg.tevo_event_id = p.eid AND sg.captured_at = p.captured_at
     WHERE NOT sg.is_broker_owned
       AND (p_sub_sources IS NULL OR 'seatgeek' = ANY(p_sub_sources))
    UNION ALL
    -- TicketsData publishes no splits. NULL therefore keeps this arm as strict
    -- as ever on tier 1, and permits the whole-lot buy on tier 2.
    SELECT 'ticketsdata:' || td.platform, td.td_listing_id, td.eid,
           td.section, td."row", td.quantity,
           COALESCE(td.price_with_fees, td.list_price),
           NULL::text, td.captured_at, NULL::int[]
      FROM td_cur td
     WHERE NOT COALESCE(td.is_parking, false)
       AND COALESCE(td.price_with_fees, td.list_price) IS NOT NULL
       AND (p_sub_sources IS NULL OR 'ticketsdata' = ANY(p_sub_sources))
  ),
  -- Tier is assigned here so the window function below can sort on it; a
  -- window cannot see a CASE defined in its own SELECT list.
  mm AS (
    SELECT o.*, l.src, l.lid, l.sec, l.rw, l.q, l.ea, l.url, l.captured_at,
           CASE WHEN l.q = o.quantity
                  OR (l.q > o.quantity AND o.quantity = ANY(l.splits))
                THEN 1 ELSE 2 END AS tier
      FROM o JOIN l ON l.eid = o.tevo_event_id
       AND public.seat_section_norm(l.sec) = o.sec_norm
       AND public.seat_row_kind(l.rw)      = o.ord_kind
       AND public.seat_row_rank(l.rw)     <= o.ord_rank
       AND (l.q = o.quantity
            OR (l.q > o.quantity AND o.quantity = ANY(l.splits))
            -- Tier 2: exactly one seat over, and the whole lot must be a
            -- quantity the seller actually sells.
            OR (l.q = o.quantity + 1
                AND (l.splits IS NULL OR l.q = ANY(l.splits))))
  ),
  m AS (
    SELECT mm.*,
           CASE WHEN mm.tier = 1 THEN mm.quantity ELSE mm.q END AS buy_qty,
           row_number() OVER (
             PARTITION BY mm.n2s_id
             ORDER BY mm.tier,
                      mm.ea * CASE WHEN mm.tier = 1 THEN mm.quantity ELSE mm.q END,
                      (mm.q - mm.quantity)) AS rn
      FROM mm
  )
  SELECT n2s_id, order_number, s4k_source, status, fail_reason, timer_expired,
         event_name, event_date, venue, tevo_event_id, section, order_row,
         quantity, sold_ea, src, lid, sec, rw,
         buy_qty                                  AS sub_qty,   -- what we PAY FOR
         q                                        AS sub_avail, -- lot size
         ea,
         round(ea * buy_qty, 2)                   AS sub_total,
         round(ea * buy_qty - sold_ea * quantity, 2) AS cover_cost,
         (ord_rank - public.seat_row_rank(rw))    AS rows_closer,
         url, captured_at, rn
    FROM m
   WHERE rn <= p_per_order
   ORDER BY cover_cost, n2s_id;
$$;

REVOKE ALL ON FUNCTION public.n2s_cover_candidates(bigint[],interval,integer,text[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.n2s_cover_candidates(bigint[],interval,integer,text[]) TO service_role;

COMMENT ON COLUMN public.n2s_cover_queue.sub_qty IS
  'How many tickets to BUY, which is not always how many we owe. Equals '
  'quantity on a tier-1 cover; equals the whole lot (quantity + 1) on a '
  'tier-2 over-delivery cover. Feeds the vendor payload in '
  'n2s_buy_intent_create(). See migration 20260910260000.';
COMMENT ON COLUMN public.n2s_cover_queue.sub_avail IS
  'The listing''s own lot size. Greater than sub_qty means a SPLIT take: the '
  'listing is bigger than the obligation and its splits permit buying exactly '
  'sub_qty. Equal to sub_qty on a whole-lot buy. See migration 20260910250000.';

-- ── n2s_covers(): the allocator must respect the tier too ──────────────────
-- It picks the surviving candidate by cover_cost alone, so without this the
-- fallback would outrank an exact match whenever the spare seat happened to
-- be cheap. (sub_qty > quantity) is false on every tier-1 row and sorts first
-- in ASC, so exact/split covers are exhausted before a single spare seat is
-- bought. Byte-identical to the deployed definition otherwise.
CREATE OR REPLACE FUNCTION public.n2s_covers(
  p_n2s_ids         bigint[] DEFAULT NULL,
  p_max_listing_age interval DEFAULT interval '1 hour',
  p_per_order       integer  DEFAULT 20,
  p_sub_sources     text[]   DEFAULT NULL
)
RETURNS TABLE (
  n2s_id bigint, order_number text, s4k_source text, n2s_status text,
  fail_reason text, timer_expired boolean, event_name text, event_date date,
  venue text, tevo_event_id bigint, section text, order_row text,
  quantity integer, sold_ea numeric, sub_source text, sub_listing_id text,
  sub_section text, sub_row text, sub_qty integer, sub_avail integer,
  sub_ea numeric, sub_total numeric, cover_cost numeric, rows_closer integer,
  buy_url text, captured_at timestamptz, cover_rank bigint, fifo_position bigint
)
LANGUAGE plpgsql VOLATILE
SET search_path TO 'public','pg_temp'
AS $function$
DECLARE
  o RECORD;
  v_src text;
  v_lid text;
  v_pos bigint := 0;
BEGIN
  DROP TABLE IF EXISTS _cand;
  DROP TABLE IF EXISTS _claimed;
  DROP TABLE IF EXISTS _out;

  CREATE TEMP TABLE _cand ON COMMIT DROP AS
    SELECT c.*, COALESCE(i.alert_at, i.n2s_created_at) AS fifo_at
      FROM public.n2s_cover_candidates(
             p_n2s_ids, p_max_listing_age, p_per_order, p_sub_sources) c
      JOIN public.n2s_items i ON i.n2s_id = c.n2s_id;

  CREATE TEMP TABLE _claimed(sub_source text, sub_listing_id text) ON COMMIT DROP;
  CREATE TEMP TABLE _out (LIKE _cand) ON COMMIT DROP;
  ALTER TABLE _out ADD COLUMN fifo_position bigint;

  -- ⚠ QUALIFY WITH AN ALIAS. n2s_id is also an OUT parameter of this function's
  -- RETURNS TABLE, so an unqualified reference here raises "column reference
  -- n2s_id is ambiguous" the first time the function runs.
  FOR o IN
    SELECT DISTINCT k.n2s_id, k.fifo_at FROM _cand k ORDER BY k.fifo_at, k.n2s_id
  LOOP
    v_pos := v_pos + 1;

    SELECT x.sub_source, x.sub_listing_id INTO v_src, v_lid
      FROM _cand x
     WHERE x.n2s_id = o.n2s_id
       AND NOT EXISTS (SELECT 1 FROM _claimed k
                        WHERE k.sub_source = x.sub_source
                          AND k.sub_listing_id = x.sub_listing_id)
     ORDER BY (x.sub_qty > x.quantity), x.cover_cost
     LIMIT 1;

    IF FOUND THEN
      INSERT INTO _claimed VALUES (v_src, v_lid);
      INSERT INTO _out
        SELECT x.*, v_pos FROM _cand x
         WHERE x.n2s_id = o.n2s_id
           AND x.sub_source = v_src AND x.sub_listing_id = v_lid;
    END IF;
  END LOOP;

  RETURN QUERY
    SELECT _out.n2s_id, _out.order_number, _out.s4k_source, _out.n2s_status,
           _out.fail_reason, _out.timer_expired, _out.event_name, _out.event_date,
           _out.venue, _out.tevo_event_id, _out.section, _out.order_row,
           _out.quantity, _out.sold_ea, _out.sub_source, _out.sub_listing_id,
           _out.sub_section, _out.sub_row, _out.sub_qty, _out.sub_avail,
           _out.sub_ea, _out.sub_total, _out.cover_cost, _out.rows_closer,
           _out.buy_url, _out.captured_at, _out.cover_rank, _out.fifo_position
      FROM _out ORDER BY _out.cover_cost, _out.n2s_id;
END $function$;

REVOKE ALL ON FUNCTION public.n2s_covers(bigint[],interval,integer,text[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.n2s_covers(bigint[],interval,integer,text[]) TO service_role;
