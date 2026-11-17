-- ============================================================================
-- Migration 20260910270000 — two guards the review caught, symmetrised
--
-- Lane:     D0 (orders surface)
-- Touches:  n2s_cover_candidates() (CREATE OR REPLACE — signature unchanged).
-- Pre-reqs: 20260910260000
--
-- READ-ONLY upstream: no API call. Pure SQL over already-ingested listings.
-- RULE 2 untouched.
--
-- Both are latent, not live: measured on the book at the time of writing,
-- neither changes a single current cover. They are fixed anyway because both
-- fail in the direction that costs money or silence.
--
-- ── 1. THE WHOLE-LOT GUARD WAS ON ONE ARM AND NOT THE OTHER ───────────────
-- 20260910260000 required `l.q = ANY(l.splits)` before buying a whole lot on
-- tier 2, and its own comment explained why: a listing whose splits exclude
-- its own total cannot be bought entire, and n2s_buy_intent_create() would
-- emit a `quantity` the vendor rejects. But the tier-1 exact-size arm
-- (`l.q = o.quantity`) is ALSO a whole-lot buy, and carried no such guard — so
-- the rule was enforced on the rarer path and skipped on the common one. A
-- 4-seat listing selling only in 2s could be allocated to a 4-seat obligation
-- and fail at the vendor console. Now both whole-lot arms carry the guard, and
-- the three arms are labelled so the asymmetry cannot quietly return.
-- (Live count of exact-size matches whose splits forbid the whole lot: 0 of
-- 15. Globally the shape is real — 102 of ~1.25M live listings.)
--
-- ── 2. jsonb_typeof DOES NOT PROMISE INTEGER ELEMENTS ─────────────────────
-- The SeatGeek arm guarded the CONTAINER (`jsonb_typeof = 'array'`) and then
-- cast each element with `::int`. An array containing anything non-numeric
-- still raises — and this expression is evaluated inside
-- n2s_cover_queue_refresh(), which the cron runs every minute over the whole
-- book. One malformed splits value from one listing would abort the refresh
-- for EVERY order, and the failure mode of the covers panel is silence: it
-- would keep serving the last good queue with no indication anything died.
-- Unparseable entries are now filtered out instead. If that leaves an empty
-- array, nothing matches it and the listing is simply not offered — which is
-- the strict fallback the original comment claimed but did not implement.
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
    -- SeatGeek stores splits as jsonb, and neither guard here is optional.
    -- jsonb_typeof stops jsonb_array_elements_text raising on a non-array;
    -- the ~ '^[0-9]+$' filter stops the ::int cast raising on an element that
    -- is not a number. jsonb_typeof alone does NOT imply integer elements, and
    -- this expression runs inside n2s_cover_queue_refresh() — one malformed
    -- splits value would abort the refresh for the ENTIRE book. A list we
    -- cannot parse must degrade to strict matching, never to an error, so
    -- unparseable entries are dropped; if that leaves {}, nothing matches it
    -- and the listing is simply not offered.
    SELECT 'seatgeek', sg.sglid::text, sg.tevo_event_id,
           sg.section, sg."row", sg.quantity, sg.retail_price_all_in,
           NULL::text, sg.captured_at,
           CASE WHEN jsonb_typeof(sg.splits) = 'array'
                THEN ARRAY(SELECT e::int
                             FROM jsonb_array_elements_text(sg.splits) AS e
                            WHERE e ~ '^[0-9]+$')
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
       AND ( -- Tier 1a: right-sized listing, bought whole.
             (l.q = o.quantity
              AND (l.splits IS NULL OR l.q = ANY(l.splits)))
             -- Tier 1b: part of a bigger listing, its splits permitting.
          OR (l.q > o.quantity AND o.quantity = ANY(l.splits))
             -- Tier 2: exactly one seat over, bought whole.
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

-- ── 3. THE `authenticated` GRANT IS DROPPED ON PURPOSE ────────────────────
-- 20260910100000 granted these two functions to `authenticated, service_role`.
-- 20260910250000 recreated them with DROP/CREATE (their return type changed),
-- which discards prior grants, and re-granted only `service_role` — a real
-- narrowing, but an unremarked one, which is the part worth correcting.
-- Stating it rather than restoring it: nothing calls either function as
-- `authenticated`. The panel route reads the `v_n2s_orders` VIEW through the
-- service-role client, and the cron runs the functions as `service_role`; no
-- RPC path to them exists in routers/, server.py or static/. Least privilege
-- is the right end state here, so the grant stays off deliberately.
REVOKE ALL ON FUNCTION public.n2s_cover_candidates(bigint[],interval,integer,text[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.n2s_cover_candidates(bigint[],interval,integer,text[]) TO service_role;
