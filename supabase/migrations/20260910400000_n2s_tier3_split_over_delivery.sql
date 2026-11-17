-- ============================================================================
-- Migration 20260910400000 — tier 3: split-permitted over-delivery from a
--                            LARGER lot, capped at one spare seat and at cost
--
-- Lane:     D7 (n2s obligation-covering) over A1's DB plane
-- Level:    data-collection — one function body change, same signature.
-- Touches:  n2s_cover_candidates() (new matching arm + tier/buy_qty/ranking)
-- Pre-reqs: 20260910310000 (the live definition this is built on — NOTE the
--           on-disk 20260910270000 is NOT current; the buy-URL migrations
--           20260910300000/310000 changed the l CTE. This body was diffed
--           against pg_get_functiondef, per PROJECT_BIBLE §3.)
--
-- Upstream: no API call at all. RULE 2 untouched.
--
-- Operator direction 2026-09-10: "if you incorporate splits you can use splits
-- to find more qty's" -> then, on being shown the cost profile: "limit spare
-- seat to one. and keep cap to cost or profit only."
--
-- ── THE GAP THIS CLOSES ────────────────────────────────────────────────────
-- Splits were already honoured, but only in two shapes:
--   tier 1b  buy EXACTLY what we owe from a bigger lot   (quantity ∈ splits)
--   tier 2   buy a WHOLE lot that is exactly one larger  (q = quantity + 1)
--
-- Nothing considered buying a permitted split k where quantity < k < lot size.
-- Live example that was invisible (n2s_id 97, SeatGeek): we owe 3, the lot has
-- 6 seats and splits [2,4,6]. Tier 1b fails — 3 is not a permitted split. Tier
-- 2 fails — the lot is 6, not 4. But the seller WILL sell 4. That is a
-- one-spare-seat cover the matcher could not see.
--
-- ── ⚠ WHY BOTH CAPS ARE LOAD-BEARING ───────────────────────────────────────
-- Generalising "use splits to find more quantities" without limits is actively
-- dangerous, and the measurement said so before this was written. Allowing any
-- permitted split ≥ quantity reached 11 orders, of which TEN were worse than
-- the cover that order already had, and the single genuinely new cover was a
-- $2,022 LOSS. The failure mode is uniform: restrictive singleton splits like
-- [4] on a 4-lot mean "buy all four or nothing", so covering 2 seats costs 4,
-- and one case (owe 1, lot 6, splits [6]) would have bought SIX seats to cover
-- ONE — a $4,244 cover cost against an $862 alternative.
--
--   CAP 1 — ONE SPARE SEAT. buy_qty is fixed at quantity + 1, never a larger
--   permitted split. This is the same waste bound tier 2 already respects; it
--   is the whole reason tier 2 was written as `quantity + 1` and not "any
--   bigger lot". Do not widen it to `min(k) where k >= quantity` — that is
--   precisely the unbounded version measured above.
--
--   CAP 2 — AT COST OR BETTER. A tier-3 row is admitted only when
--   ea*(quantity+1) <= sold_ea*quantity, i.e. cover_cost <= 0. Tiers 1 and 2
--   are NOT gated this way and must not become so: for an obligation we are
--   contractually bound to fill, a loss-making cover still beats a failed
--   delivery, so the panel must keep showing them. Tier 3 is different in kind
--   — it is us CHOOSING to buy a spare seat off a lot we were not otherwise
--   going to touch, so it earns its place only when it costs nothing.
--
-- Note this makes tier 3 the only arm whose admission depends on price. A NULL
-- sold_ea makes the comparison NULL, so the row is excluded — fail-closed.
--
-- ── RANKING: TIER 3 CAN NEVER DISPLACE A CHEAPER COVER ─────────────────────
-- tier is the FIRST sort key, so a tier-1 or tier-2 cover always outranks a
-- tier-3 one even when tier 3 is nominally cheaper. That is deliberate: buying
-- exactly what we owe is worth more than a marginal saving that leaves us
-- holding a seat.
--
-- A row matching BOTH tier 1b and tier 3 (lot 6, splits [2,3,4], owe 3 — both
-- 3 and 4 are permitted) is assigned tier 1 by CASE order, so we buy 3, not 4.
--
-- ⚠ buy_qty is now computed in `mm` rather than `m`. It has to be: the window
-- function in `m` sorts on cost, cost depends on buy_qty, and a window cannot
-- see a CASE defined in its own SELECT list (the same constraint that put
-- `tier` in `mm` originally). The previous code sidestepped this by inlining
-- `CASE WHEN tier=1 THEN quantity ELSE q END` into the ORDER BY — which would
-- be WRONG for tier 3, where q is the whole lot and we are buying quantity+1.
-- Left uncorrected it would have overstated tier-3 cost and misordered tier-3
-- candidates against each other.
--
-- ── THE GLOBAL 200% COST CEILING (second operator instruction) ─────────────
-- "limit cover to 200% max cost". Applied to EVERY tier, not just tier 3: a
-- candidate is dropped unless ea * buy_qty <= 2 * sold_ea * quantity. It is
-- filtered in `m`, before the window function, so an over-cap candidate cannot
-- occupy one of the p_per_order slots that a cheaper cover should have had.
--
-- ⚠ THIS HIDES COVERS THAT EXIST. Measured against the live queue: 15 of 49
-- covers exceed 200%, and those 15 are the ONLY cover their obligation has, so
-- those orders will now show nothing. The worst is 880% (sold 5 seats for
-- $26.25, cover $231.05); others include 421% and 396% on ~$712 sales.
--
-- No profitable cover is affected — 0 of the 15 had cover_cost < 0 — so the
-- external feed is unchanged. The loss is panel visibility: the obligation does
-- NOT go away when its cover is hidden, and for an order we are bound to fill,
-- $231 may be the honest price of not defaulting. An operator looking at those
-- 15 orders will now see "no cover" where the truthful statement is "a cover
-- exists, above your ceiling". Distinguishing those two in no_cover_reason is a
-- follow-up, not done here.
--
-- ⚠ THE sold_ea <= 0 CARVE-OUT IS NOT SLOPPINESS. With a naive cap, an order
-- priced at 0 has a ceiling of 0, so EVERY cover fails and the obligation
-- becomes permanently uncoverable with no explanation. That is a live hazard,
-- not a hypothetical: PROJECT_BIBLE §3 records that GoTickets orders carry
-- price 0.00 in the CRM. n2s_items.price_per_ticket is a different, populated
-- field — all 127 open items today are positive, GoTickets included — but if a
-- zero ever arrives, the cap SKIPS rather than blanking the order. A spending
-- ceiling we cannot compute must not silently delete every option.
--
-- ── EXPECTED IMPACT AT AUTHORING TIME ──────────────────────────────────────
-- TIER 3: three pairs across two orders exist right now, all SeatGeek, and ALL
-- THREE fail its at-cost gate (+$1,079.28, +$57.47, +$71.43). So tier 3 adds
-- nothing today by design — reach without bad buys, firing when the market
-- offers a genuinely free spare seat.
--
-- 200% CEILING: removes 15 of 49 current covers from the panel, 0 of them
-- profitable, so n2s_profitable_cover is untouched.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.n2s_cover_candidates(
  p_n2s_ids          bigint[] DEFAULT NULL::bigint[],
  p_max_listing_age  interval DEFAULT '01:00:00'::interval,
  p_per_order        integer  DEFAULT 3,
  p_sub_sources      text[]   DEFAULT NULL::text[])
 RETURNS TABLE(n2s_id bigint, order_number text, s4k_source text, n2s_status text,
               fail_reason text, timer_expired boolean, event_name text,
               event_date date, venue text, tevo_event_id bigint, section text,
               order_row text, quantity integer, sold_ea numeric, sub_source text,
               sub_listing_id text, sub_section text, sub_row text, sub_qty integer,
               sub_avail integer, sub_ea numeric, sub_total numeric,
               cover_cost numeric, rows_closer integer, buy_url text,
               captured_at timestamp with time zone, cover_rank bigint)
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
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
           'https://core.ticketevolution.com/buy/event/' || t.event_id::text
             || '/tickets/' || t.tevo_ticket_group_id::text AS url,
           t.captured_at, t.splits
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
    -- SeatGeek stores splits as jsonb, and neither guard here is optional.
    -- jsonb_typeof stops jsonb_array_elements_text raising on a non-array; the
    -- ~ '^[0-9]+$' filter stops the ::int cast raising on a non-numeric element.
    -- This runs inside n2s_cover_queue_refresh(); one malformed splits value
    -- would abort the refresh for the ENTIRE book, so an unparseable list must
    -- degrade to strict matching, never to an error.
    SELECT 'seatgeek', sg.sglid::text, sg.tevo_event_id,
           sg.section, sg."row", sg.quantity, sg.retail_price_all_in,
           CASE WHEN COALESCE(c.sg_url, '') <> ''
                 AND COALESCE(sg.display_id, '') <> ''
                THEN c.sg_url || '#listing=' || sg.display_id
                ELSE NULL::text END,
           sg.captured_at,
           CASE WHEN jsonb_typeof(sg.splits) = 'array'
                THEN ARRAY(SELECT e::int
                             FROM jsonb_array_elements_text(sg.splits) AS e
                            WHERE e ~ '^[0-9]+$')
                ELSE NULL::int[] END
      FROM p_sg p JOIN public.seatgeek_listings_snapshots sg
        ON sg.tevo_event_id = p.eid AND sg.captured_at = p.captured_at
      LEFT JOIN public.sg_events_canonical c ON c.sg_event_id = sg.sg_event_id
     WHERE NOT sg.is_broker_owned
       AND (p_sub_sources IS NULL OR 'seatgeek' = ANY(p_sub_sources))
    UNION ALL
    -- TicketsData publishes no splits. NULL keeps this arm strict on tier 1,
    -- permits the whole-lot buy on tier 2, and excludes it from tier 3 (which
    -- needs a splits list to know a partial buy is allowed at all).
    SELECT 'ticketsdata:' || td.platform, td.td_listing_id, td.eid,
           td.section, td."row", td.quantity,
           COALESCE(td.price_with_fees, td.list_price),
           NULL::text, td.captured_at, NULL::int[]
      FROM td_cur td
     WHERE NOT COALESCE(td.is_parking, false)
       AND COALESCE(td.price_with_fees, td.list_price) IS NOT NULL
       AND (p_sub_sources IS NULL OR 'ticketsdata' = ANY(p_sub_sources))
  ),
  -- tier AND buy_qty are both assigned here so the window in `m` can sort on
  -- them; a window cannot see a CASE defined in its own SELECT list.
  mm AS (
    SELECT o.*, l.src, l.lid, l.sec, l.rw, l.q, l.ea, l.url, l.captured_at,
           CASE WHEN l.q = o.quantity
                  OR (l.q > o.quantity AND o.quantity = ANY(l.splits)) THEN 1
                WHEN l.q = o.quantity + 1                              THEN 2
                ELSE 3 END AS tier,
           CASE WHEN l.q = o.quantity
                  OR (l.q > o.quantity AND o.quantity = ANY(l.splits))
                  THEN o.quantity
                WHEN l.q = o.quantity + 1 THEN l.q
                ELSE o.quantity + 1 END AS buy_qty
      FROM o JOIN l ON l.eid = o.tevo_event_id
       AND public.seat_section_norm(l.sec) = o.sec_norm
       AND public.seat_row_kind(l.rw)      = o.ord_kind
       AND public.seat_row_rank(l.rw)     <= o.ord_rank
       AND ( -- Tier 1a: right-sized listing, bought whole.
             (l.q = o.quantity
              AND (l.splits IS NULL OR l.q = ANY(l.splits)))
             -- Tier 1b: part of a bigger listing, its splits permitting.
          OR (l.q > o.quantity AND o.quantity = ANY(l.splits))
             -- Tier 2: exactly one seat over, bought whole.
          OR (l.q = o.quantity + 1
              AND (l.splits IS NULL OR l.q = ANY(l.splits)))
             -- Tier 3: one seat over, taken from a LARGER lot whose splits
             -- permit exactly that quantity. Capped at one spare seat, and
             -- admitted only at cost or better — see the header for why both
             -- caps are load-bearing and must not be relaxed.
          OR (l.q > o.quantity + 1
              AND (o.quantity + 1) = ANY(l.splits)
              AND l.ea * (o.quantity + 1) <= o.sold_ea * o.quantity))
  ),
  m AS (
    SELECT mm.*,
           row_number() OVER (
             PARTITION BY mm.n2s_id
             ORDER BY mm.tier,
                      mm.ea * mm.buy_qty,
                      (mm.q - mm.quantity)) AS rn
      FROM mm
     -- GLOBAL 200% COST CEILING (operator, 2026-09-10): never offer a cover
     -- costing more than twice what the obligation sold for. Applied HERE, so
     -- over-cap candidates are gone before ranking and can never win a slot.
     -- The sold_ea <= 0 carve-out is deliberate — see the header.
     WHERE mm.sold_ea IS NULL OR mm.sold_ea <= 0
        OR mm.ea * mm.buy_qty <= 2 * mm.sold_ea * mm.quantity
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
$function$;

COMMENT ON FUNCTION public.n2s_cover_candidates(bigint[], interval, integer, text[]) IS
  'Ranked cover candidates per obligation. Tier 1 = buy exactly what we owe '
  '(whole lot, or part of a bigger lot its splits permit). Tier 2 = whole lot '
  'exactly one seat over. Tier 3 = one seat over taken from a LARGER lot whose '
  'splits permit that quantity — capped at ONE spare seat and admitted only at '
  'cover_cost <= 0. Tier is the first sort key, so tier 3 can never displace a '
  'tier 1/2 cover. Never widen tier 3 to any permitted split >= quantity: that '
  'was measured and bought 4 seats to cover 2, and 6 to cover 1. A GLOBAL 200% '
  'ceiling drops any candidate costing more than twice the sold value, applied '
  'before ranking so it cannot occupy a slot; it is SKIPPED when sold_ea <= 0, '
  'because a ceiling of zero would make such an obligation permanently '
  'uncoverable rather than merely capped.';
