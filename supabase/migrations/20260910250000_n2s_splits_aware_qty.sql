-- ============================================================================
-- Migration 20260910250000 — quantity stays strict, but splits count
--
-- Lane:     D0 (orders surface)
-- Touches:  n2s_cover_candidates() + n2s_covers() (DROP/CREATE — the return
--           type gains sub_avail), n2s_cover_queue (+sub_avail),
--           n2s_cover_queue_refresh(), v_n2s_orders.
-- Pre-reqs: 20260910190000, 20260910100000
--
-- READ-ONLY upstream: no API call. Pure SQL over already-ingested listings.
-- RULE 2 untouched.
--
-- Operator direction 2026-09-10: "need qty match to stay strict but use splits
-- if splits show same qty."
--
-- ── WHAT CHANGED ──────────────────────────────────────────────────────────
-- The matcher required l.q = o.quantity: a listing had to be exactly the size
-- of the obligation. But a listing's `splits` is the set of lot sizes it will
-- actually sell — a 4-seat listing with splits {1,2,3,4} sells 2 quite
-- happily. Demanding an exact-size listing threw those away.
--
-- The rule is now: the quantity DELIVERED must still equal the quantity owed —
-- that has not loosened at all — but a larger listing qualifies when its
-- splits prove the exact quantity is purchasable:
--
--     l.q = o.quantity                                   (as before)
--     OR (l.q > o.quantity AND o.quantity = ANY(l.splits))
--
-- ⚠ NULL SPLITS STAY STRICT, DELIBERATELY. `x = ANY(NULL)` is NULL, not true,
-- so a source that does not publish splits keeps the old exact-size rule. That
-- is the conservative reading of "use splits IF splits show same qty": absent
-- splits do not SHOW anything. TicketsData publishes none, so its arm is
-- unchanged. (Note this is the opposite default to core/substitutions.py's
-- splits_allow(), which permits on absent splits — that helper runs in a
-- context where quantity >= needed was already the rule, so permitting was the
-- narrowing choice there and would be the widening choice here.)
--
-- Splits coverage measured before writing this: TEvo 1,030,280 of 1,030,305
-- rows (99.998%), GoTickets 282,454 of 282,454, SeatGeek 447 of 447.
--
-- Measured effect on the live book: orders with a cover 7 -> 9, candidate
-- (order,listing) pairs 31 -> 57. The ceiling — orders with ANY section/row
-- match at any quantity — is 13, so quantity was a real blocker but not the
-- only one; section normalisation is the rest.
--
-- ⚠ sub_qty IS NOW WHAT WE BUY, NOT THE SIZE OF THE LISTING. This is the part
-- that would silently cost money if it were wrong: n2s_buy_intent_create()
-- puts c.sub_qty straight into the vendor payload's `quantity`. On a split
-- take, emitting the listing's size would tell the operator to buy 4 when the
-- obligation is 2. sub_qty is therefore o.quantity — unchanged in meaning for
-- every exact match, correct for split ones — and the listing's own size is
-- carried separately as sub_avail so a partial take is visible rather than
-- implied. sub_total and cover_cost already multiplied by the ORDER quantity,
-- so the economics were right before and are right now.
--
-- ⚠ AN EXACT MATCH OUTRANKS A SPLIT AT THE SAME PRICE. The ordering gains
-- (l.q - o.quantity) as a tiebreak after price, mirroring the "smallest
-- acceptable lot" rule already in core/substitutions.py's _row_sort_key: do
-- not break up a big block to cover a few seats when an exact lot costs the
-- same. Price still dominates.
-- ============================================================================

DROP FUNCTION IF EXISTS public.n2s_covers(bigint[],interval,integer,text[]);
DROP FUNCTION IF EXISTS public.n2s_cover_candidates(bigint[],interval,integer,text[]);

CREATE FUNCTION public.n2s_cover_candidates(
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
    -- TicketsData publishes no splits, so NULL keeps this arm exactly as
    -- strict as it was.
    SELECT 'ticketsdata:' || td.platform, td.td_listing_id, td.eid,
           td.section, td."row", td.quantity,
           COALESCE(td.price_with_fees, td.list_price),
           NULL::text, td.captured_at, NULL::int[]
      FROM td_cur td
     WHERE NOT COALESCE(td.is_parking, false)
       AND COALESCE(td.price_with_fees, td.list_price) IS NOT NULL
       AND (p_sub_sources IS NULL OR 'ticketsdata' = ANY(p_sub_sources))
  ),
  m AS (
    SELECT o.*, l.src, l.lid, l.sec, l.rw, l.q, l.ea, l.url, l.captured_at,
           row_number() OVER (PARTITION BY o.n2s_id
                              ORDER BY l.ea, (l.q - o.quantity)) AS rn
      FROM o JOIN l ON l.eid = o.tevo_event_id
       AND public.seat_section_norm(l.sec) = o.sec_norm
       AND public.seat_row_kind(l.rw)      = o.ord_kind
       AND public.seat_row_rank(l.rw)     <= o.ord_rank
       AND (l.q = o.quantity
            OR (l.q > o.quantity AND o.quantity = ANY(l.splits)))
  )
  SELECT n2s_id, order_number, s4k_source, status, fail_reason, timer_expired,
         event_name, event_date, venue, tevo_event_id, section, order_row,
         quantity, sold_ea, src, lid, sec, rw,
         quantity                                 AS sub_qty,   -- what we BUY
         q                                        AS sub_avail, -- lot size
         ea,
         round(ea * quantity, 2)                  AS sub_total,
         round((ea - sold_ea) * quantity, 2)      AS cover_cost,
         (ord_rank - public.seat_row_rank(rw))    AS rows_closer,
         url, captured_at, rn
    FROM m
   WHERE rn <= p_per_order
   ORDER BY cover_cost, n2s_id;
$$;

CREATE FUNCTION public.n2s_covers(
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
  -- n2s_id is ambiguous" the first time the function runs. The deployed
  -- definition carried something that masked this and the migration file did
  -- not — which is exactly why a function should be copied from
  -- pg_get_functiondef, not from the migration that first created it.
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
     ORDER BY x.cover_cost
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

ALTER TABLE public.n2s_cover_queue ADD COLUMN IF NOT EXISTS sub_avail integer;

COMMENT ON COLUMN public.n2s_cover_queue.sub_qty IS
  'How many tickets to BUY — always the obligation''s quantity. Feeds the '
  'vendor payload in n2s_buy_intent_create(); never the listing''s lot size.';
COMMENT ON COLUMN public.n2s_cover_queue.sub_avail IS
  'The listing''s own lot size. Greater than sub_qty means a SPLIT take: the '
  'listing is bigger than the obligation and its splits permit buying exactly '
  'sub_qty. See migration 20260910250000.';

CREATE OR REPLACE FUNCTION public.n2s_cover_queue_refresh()
RETURNS TABLE(rows_written integer, orders_covered integer, total_cover_cost numeric)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_n int := 0;
BEGIN
  DELETE FROM public.n2s_cover_queue;

  INSERT INTO public.n2s_cover_queue (
    n2s_id, order_number, s4k_source, n2s_status, fail_reason, timer_expired,
    event_name, event_date, venue, tevo_event_id, section, order_row, quantity,
    sold_ea, sub_source, sub_listing_id, sub_section, sub_row, sub_qty,
    sub_avail, sub_ea, sub_total, cover_cost, rows_closer, buy_url,
    captured_at, cover_rank, fifo_position, refreshed_at)
  SELECT c.n2s_id, c.order_number, c.s4k_source, c.n2s_status, c.fail_reason,
         c.timer_expired, c.event_name, c.event_date, c.venue, c.tevo_event_id,
         c.section, c.order_row, c.quantity, c.sold_ea, c.sub_source,
         c.sub_listing_id, c.sub_section, c.sub_row, c.sub_qty, c.sub_avail,
         c.sub_ea, c.sub_total, c.cover_cost, c.rows_closer, c.buy_url,
         c.captured_at, c.cover_rank, c.fifo_position, now()
    FROM public.n2s_covers() c;

  GET DIAGNOSTICS v_n = ROW_COUNT;

  RETURN QUERY
    SELECT v_n,
           (SELECT count(*)::int FROM public.n2s_cover_queue),
           (SELECT round(COALESCE(sum(cover_cost), 0), 2) FROM public.n2s_cover_queue);
END $function$;

REVOKE ALL ON FUNCTION public.n2s_cover_candidates(bigint[],interval,integer,text[]) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.n2s_covers(bigint[],interval,integer,text[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.n2s_cover_candidates(bigint[],interval,integer,text[]) TO service_role;
GRANT EXECUTE ON FUNCTION public.n2s_covers(bigint[],interval,integer,text[]) TO service_role;

-- ---------------------------------------------------------------------------
-- v_n2s_orders gains sub_avail.
--
-- ⚠ APPENDED AT THE END, not placed next to sub_qty where it belongs.
-- CREATE OR REPLACE VIEW can only ADD columns after the existing ones — it
-- cannot reorder them — and re-creating the view would mean dropping it while
-- /api/broker/n2s-covers reads it. Cosmetic position, correct data.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW public.v_n2s_orders AS
SELECT
  n.n2s_id, n.order_number, n.s4k_source, n.status AS n2s_status, n.status_label,
  n.fail_reason, n.timer_expired, n.alert_at, n.timer_expires_at,
  n.event_name, n.event_dt::date AS event_date, n.event_dt, n.venue,
  n.tevo_event_id, n.mapped_via, n.sources_pulled_at,
  n.section, n."row" AS order_row, n.qty AS quantity,
  n.price_per_ticket AS sold_ea, n.grand_total AS sold_total,
  c.sub_source, c.sub_listing_id, c.sub_section, c.sub_row, c.sub_qty,
  c.sub_ea, c.sub_total, c.cover_cost, c.rows_closer, c.buy_url,
  c.captured_at, c.cover_rank, c.fifo_position, c.refreshed_at,
  (c.n2s_id IS NOT NULL)  AS has_cover,
  CASE
    WHEN c.n2s_id IS NOT NULL        THEN NULL
    WHEN n.tevo_event_id IS NULL     THEN 'unmapped'
    WHEN n.sources_pulled_at IS NULL THEN 'awaiting_source_pull'
    ELSE                                  'no_match'
  END AS no_cover_reason,
  b.intent_id AS open_intent_id,
  b.requested_by AS open_intent_by,
  c.sub_avail
  FROM public.n2s_items n
  LEFT JOIN public.n2s_cover_queue c ON c.n2s_id = n.n2s_id
  LEFT JOIN public.n2s_buy_intent  b ON b.n2s_id = n.n2s_id AND b.status = 'requested'
 WHERE NOT n.is_terminal
   AND n.event_dt::date >= current_date;
