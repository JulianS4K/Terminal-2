-- ============================================================================
-- Migration 20260910100000 — one listing, one order: FIFO-exclusive covers
--
-- Lane:     D0 (orders surface)
-- Touches:  n2s_cover_candidates() (new — the raw matcher, unchanged logic),
--           n2s_covers() (now a FIFO allocator over those candidates),
--           n2s_sub_ping() (counts candidates, not allocations)
-- Pre-reqs: 20260910090000
--
-- READ-ONLY upstream: no API call. Pure SELECT plus the ping's bot_chat row.
--
-- Operator direction 2026-09-09: "in cases of duplicate listings ... fifo."
--
-- ── The defect this fixes, found in the live queue ─────────────────────────
-- n2s_covers() priced every order INDEPENDENTLY, so the same listing could be
-- offered as the best cover to several orders at once. Live example:
-- GoTickets listing 7167764492 — Section 116, row 8, TWO seats — was the
-- rank-1 cover for BOTH order 7051804 and order 7074814, each needing two.
-- Buying it fills exactly one of them. Acting on that queue would have meant
-- paying $333.90 believing two obligations were covered when only one was.
--
-- Quantity is matched EXACTLY (l.q = o.quantity), so a listing can satisfy at
-- most one order. Exclusivity is therefore a clean one-to-one claim, with no
-- partial-fill arithmetic to get wrong.
--
-- ── FIFO, and what "first" means ───────────────────────────────────────────
-- The earliest order in the queue claims the contested listing; later orders
-- fall through to their next-cheapest UNCLAIMED candidate, or to nothing.
--
-- The FIFO key is `alert_at` — the moment the marketplace told us the order
-- failed, i.e. when it actually entered the N2S queue. Measured before
-- choosing it: populated on all 156 open future items, and never later than
-- n2s_created_at (which is merely when our CRM wrote the row, and would rank
-- by ingest luck rather than by who has been waiting longest). n2s_id breaks
-- ties deterministically so the allocation is stable across runs.
--
-- ── Why a greedy loop rather than one clever query ─────────────────────────
-- Allocation is sequential by nature: whether order N can have a listing
-- depends on what orders 1..N-1 took. A window function cannot express that
-- without iterating. The candidate set is tens of rows, so a plpgsql loop is
-- both exact and cheap, and it reads the way the rule is stated.
--
-- ⚠ cover_rank NOW MEANS SOMETHING DIFFERENT, AND THAT IS THE POINT. It is no
-- longer "row number by price"; it is WHICH of that order's own candidates it
-- actually got. 1 = its cheapest. 2 = its cheapest was claimed by an earlier
-- order and it took the next one. Anything >1 is a visible sign of contention,
-- which is exactly what the old shape hid. Because of that, callers must NOT
-- filter on cover_rank = 1 to mean "the best cover" — n2s_covers() already
-- returns exactly one allocated row per order. The ping is updated below for
-- precisely this reason.
-- ============================================================================

-- ── 1. the raw matcher, renamed, logic untouched ───────────────────────────
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
  sub_section text, sub_row text, sub_qty integer, sub_ea numeric,
  sub_total numeric, cover_cost numeric, rows_closer integer, buy_url text,
  captured_at timestamptz, cover_rank bigint
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
     WHERE NOT i.is_terminal AND i.tevo_event_id IS NOT NULL
       AND i.event_dt::date >= current_date
       AND i.qty IS NOT NULL AND i.price_per_ticket IS NOT NULL
       AND public.seat_row_kind(i."row") IS NOT NULL
       AND public.seat_section_norm(i.section) IS NOT NULL
       AND (p_n2s_ids IS NULL OR i.n2s_id = ANY(p_n2s_ids))
  ),
  ev AS (SELECT DISTINCT tevo_event_id AS eid FROM o),
  p_tevo AS (
    SELECT ev.eid, x.captured_at FROM ev CROSS JOIN LATERAL (
      SELECT l.captured_at FROM public.listings_snapshots l
       WHERE l.event_id = ev.eid AND l.captured_at >= now() - p_max_listing_age
       ORDER BY l.captured_at DESC LIMIT 1) x
  ),
  p_gt AS (
    SELECT ev.eid, x.captured_at FROM ev CROSS JOIN LATERAL (
      SELECT g.captured_at FROM public.gotickets_listings_snapshots g
       WHERE g.tevo_event_id = ev.eid AND g.captured_at >= now() - p_max_listing_age
       ORDER BY g.captured_at DESC LIMIT 1) x
  ),
  p_sg AS (
    SELECT ev.eid, x.captured_at FROM ev CROSS JOIN LATERAL (
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
           NULL::text AS url, t.captured_at
      FROM p_tevo p JOIN public.listings_snapshots t
        ON t.event_id = p.eid AND t.captured_at = p.captured_at
     WHERE NOT t.is_owned AND NOT t.is_ancillary
       AND (p_sub_sources IS NULL OR 'tevo' = ANY(p_sub_sources))
    UNION ALL
    SELECT 'gotickets', g.gt_listing_id::text, g.tevo_event_id,
           g.section, g."row", g.quantity, g.all_in_price,
           'https://pro.gotickets.com/tickets/' || g.gt_event_id
             || '/?sortBy=price&sortDirection=asc&sections=' || g.section_id,
           g.captured_at
      FROM p_gt p JOIN public.gotickets_listings_snapshots g
        ON g.tevo_event_id = p.eid AND g.captured_at = p.captured_at
     WHERE (p_sub_sources IS NULL OR 'gotickets' = ANY(p_sub_sources))
    UNION ALL
    SELECT 'seatgeek', sg.sglid::text, sg.tevo_event_id,
           sg.section, sg."row", sg.quantity, sg.retail_price_all_in,
           NULL::text, sg.captured_at
      FROM p_sg p JOIN public.seatgeek_listings_snapshots sg
        ON sg.tevo_event_id = p.eid AND sg.captured_at = p.captured_at
     WHERE NOT sg.is_broker_owned
       AND (p_sub_sources IS NULL OR 'seatgeek' = ANY(p_sub_sources))
    UNION ALL
    SELECT 'ticketsdata:' || td.platform, td.td_listing_id, td.eid,
           td.section, td."row", td.quantity,
           COALESCE(td.price_with_fees, td.list_price),
           NULL::text, td.captured_at
      FROM td_cur td
     WHERE NOT COALESCE(td.is_parking, false)
       AND COALESCE(td.price_with_fees, td.list_price) IS NOT NULL
       AND (p_sub_sources IS NULL OR 'ticketsdata' = ANY(p_sub_sources))
  ),
  m AS (
    SELECT o.*, l.src, l.lid, l.sec, l.rw, l.q, l.ea, l.url, l.captured_at,
           row_number() OVER (PARTITION BY o.n2s_id ORDER BY l.ea) AS rn
      FROM o JOIN l ON l.eid = o.tevo_event_id
       AND public.seat_section_norm(l.sec) = o.sec_norm
       AND public.seat_row_kind(l.rw)      = o.ord_kind
       AND public.seat_row_rank(l.rw)     <= o.ord_rank
       AND l.q = o.quantity
  )
  SELECT n2s_id, order_number, s4k_source, status, fail_reason, timer_expired,
         event_name, event_date, venue, tevo_event_id, section, order_row,
         quantity, sold_ea, src, lid, sec, rw, q, ea,
         round(ea * quantity, 2)                  AS sub_total,
         round((ea - sold_ea) * quantity, 2)      AS cover_cost,
         (ord_rank - public.seat_row_rank(rw))    AS rows_closer,
         url, captured_at, rn
    FROM m
   WHERE rn <= p_per_order
   ORDER BY cover_cost, n2s_id;
$$;

COMMENT ON FUNCTION public.n2s_cover_candidates(bigint[],interval,integer,text[]) IS
  'RAW covers: every listing that could cover each open N2S order, with no '
  'exclusivity. A listing may appear against several orders here. Use '
  'n2s_covers() for the allocated, one-listing-one-order answer; use this to '
  'ask what COULD have covered an order.';

REVOKE ALL ON FUNCTION public.n2s_cover_candidates(bigint[],interval,integer,text[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.n2s_cover_candidates(bigint[],interval,integer,text[]) TO authenticated, service_role;

-- ── 2. n2s_covers becomes the FIFO allocator ───────────────────────────────
DROP FUNCTION IF EXISTS public.n2s_covers(bigint[], interval, integer, text[]);

CREATE OR REPLACE FUNCTION public.n2s_covers(
  p_n2s_ids         bigint[] DEFAULT NULL,
  p_max_listing_age interval DEFAULT interval '1 hour',
  p_per_order       integer  DEFAULT 20,   -- depth to search, not rows returned
  p_sub_sources     text[]   DEFAULT NULL
)
RETURNS TABLE (
  n2s_id bigint, order_number text, s4k_source text, n2s_status text,
  fail_reason text, timer_expired boolean, event_name text, event_date date,
  venue text, tevo_event_id bigint, section text, order_row text,
  quantity integer, sold_ea numeric, sub_source text, sub_listing_id text,
  sub_section text, sub_row text, sub_qty integer, sub_ea numeric,
  sub_total numeric, cover_cost numeric, rows_closer integer, buy_url text,
  captured_at timestamptz, cover_rank bigint, fifo_position bigint
)
-- ⚠ VOLATILE, NOT STABLE, AND IT MUST BE. This builds temp tables and drops
-- them defensively, and Postgres rejects DROP TABLE inside a non-volatile
-- function ("DROP TABLE is not allowed in a non-volatile function"). The drops
-- are not optional either: n2s_sub_ping() calls this twice in ONE transaction,
-- so without them the second call collides with the first call's temp tables.
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

  -- ⚠ p_per_order is SEARCH DEPTH here, not output size. Each order still
  -- returns at most ONE allocated cover; a bigger depth just means an order
  -- whose cheaper options were all claimed can still reach a later one.
  -- Default 20 rather than 3 so contention degrades into "a dearer cover"
  -- instead of "no cover".
  CREATE TEMP TABLE _cand ON COMMIT DROP AS
    SELECT c.*, COALESCE(i.alert_at, i.n2s_created_at) AS fifo_at
      FROM public.n2s_cover_candidates(
             p_n2s_ids, p_max_listing_age, p_per_order, p_sub_sources) c
      JOIN public.n2s_items i ON i.n2s_id = c.n2s_id;

  CREATE TEMP TABLE _claimed(sub_source text, sub_listing_id text) ON COMMIT DROP;
  CREATE TEMP TABLE _out (LIKE _cand) ON COMMIT DROP;
  ALTER TABLE _out ADD COLUMN fifo_position bigint;

  -- Oldest alert first: the order that has been waiting longest gets first
  -- refusal on a contested listing.
  FOR o IN
    SELECT DISTINCT n2s_id, fifo_at FROM _cand ORDER BY fifo_at, n2s_id
  LOOP
    v_pos := v_pos + 1;

    -- ⚠ CAPTURE THE WINNER'S KEY, NOT THE WHOLE ROW. `SELECT * INTO c` gives a
    -- RECORD whose type is not registered, and `INSERT ... SELECT c.*` then
    -- fails with "record type has not been registered". Selecting the row back
    -- out of the typed temp table by key sidesteps that entirely.
    SELECT x.sub_source, x.sub_listing_id INTO v_src, v_lid
      FROM _cand x
     WHERE x.n2s_id = o.n2s_id
       AND NOT EXISTS (SELECT 1 FROM _claimed k
                        WHERE k.sub_source = x.sub_source
                          AND k.sub_listing_id = x.sub_listing_id)
     ORDER BY x.cover_cost      -- cheapest still-unclaimed cover
     LIMIT 1;

    IF FOUND THEN
      INSERT INTO _claimed VALUES (v_src, v_lid);
      INSERT INTO _out
        SELECT x.*, v_pos FROM _cand x
         WHERE x.n2s_id = o.n2s_id
           AND x.sub_source = v_src AND x.sub_listing_id = v_lid;
    END IF;
    -- No row when every candidate is already claimed: that order genuinely has
    -- no cover left, and must not be shown one that someone else is buying.
  END LOOP;

  RETURN QUERY
    SELECT _out.n2s_id, _out.order_number, _out.s4k_source, _out.n2s_status,
           _out.fail_reason, _out.timer_expired, _out.event_name, _out.event_date,
           _out.venue, _out.tevo_event_id, _out.section, _out.order_row,
           _out.quantity, _out.sold_ea, _out.sub_source, _out.sub_listing_id,
           _out.sub_section, _out.sub_row, _out.sub_qty, _out.sub_ea,
           _out.sub_total, _out.cover_cost, _out.rows_closer, _out.buy_url,
           _out.captured_at, _out.cover_rank, _out.fifo_position
      FROM _out ORDER BY _out.cover_cost, _out.n2s_id;
END $function$;

COMMENT ON FUNCTION public.n2s_covers(bigint[],interval,integer,text[]) IS
  'ALLOCATED covers: exactly one listing per open N2S order, and each listing '
  'to at most one order. Contested listings go to the earliest alert_at (FIFO) '
  'and later orders fall through to their next-cheapest unclaimed option. '
  'cover_rank is WHICH of that order''s own candidates it got (1 = cheapest, '
  '>1 = an earlier order took the cheaper one), so do NOT filter on '
  'cover_rank = 1 — one row per order is already the answer.';

REVOKE ALL ON FUNCTION public.n2s_covers(bigint[],interval,integer,text[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.n2s_covers(bigint[],interval,integer,text[]) TO authenticated, service_role;

-- ── 3. the ping, corrected for allocated semantics ─────────────────────────
CREATE OR REPLACE FUNCTION public.n2s_sub_ping()
RETURNS TABLE(items_pinged integer, offers integer, bot_chat_id bigint)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $function$
DECLARE
  v_ids bigint[]; v_items int := 0; v_offers int := 0; v_msg text; v_id bigint;
BEGIN
  DROP TABLE IF EXISTS _ping;
  -- n2s_covers() is now ALLOCATED: exactly one row per order, each listing to
  -- at most one order. So no DISTINCT ON and NO cover_rank = 1 filter — under
  -- FIFO, cover_rank > 1 means "an earlier order took the cheaper listing",
  -- and filtering it out would silently drop exactly the displaced orders that
  -- most need announcing.
  CREATE TEMP TABLE _ping ON COMMIT DROP AS
    SELECT c.*
      FROM public.n2s_covers() c
      JOIN public.n2s_items n ON n.n2s_id = c.n2s_id
     WHERE n.notified_at IS NULL;

  SELECT count(*)::int, array_agg(n2s_id) INTO v_items, v_ids FROM _ping;
  IF v_items = 0 THEN
    RETURN QUERY SELECT 0, 0, NULL::bigint; RETURN;
  END IF;

  -- Candidates, not allocations: "how many listings COULD have covered these".
  SELECT count(*)::int INTO v_offers
    FROM public.n2s_cover_candidates(v_ids, interval '1 hour', 20);

  SELECT format(
           'N2S cover ping: %s newly-covered order(s) allocated FIFO from %s '
           'candidate listing(s) across %s. %s cost MORE than the sale, %s at '
           'or below it. %s order(s) took a dearer cover because an earlier '
           'order claimed the cheaper listing. An N2S order is an obligation, '
           'so these rank cheapest-cover-first, not by profit. Net cost to '
           'cover all %s: $%s (cheapest $%s, dearest $%s). Marketplaces: %s. '
           'Detail: SELECT * FROM n2s_covers();',
           v_items, v_offers,
           (SELECT string_agg(DISTINCT sub_source, ', ') FROM _ping),
           count(*) FILTER (WHERE cover_cost > 0),
           count(*) FILTER (WHERE cover_cost <= 0),
           count(*) FILTER (WHERE cover_rank > 1),
           v_items,
           to_char(sum(cover_cost), 'FM999999990.00'),
           to_char(min(cover_cost), 'FM999999990.00'),
           to_char(max(cover_cost), 'FM999999990.00'),
           string_agg(DISTINCT s4k_source, ', '))
    INTO v_msg FROM _ping;

  v_id := public.bot_chat_log(
            'secondary-sales', 'd0', 'flag', v_msg, NULL, '20260910100000', NULL,
            jsonb_build_object('n2s_ids', to_jsonb(v_ids), 'items', v_items,
              'candidates', v_offers,
              'displaced', (SELECT count(*) FROM _ping WHERE cover_rank > 1),
              'total_cover_cost', (SELECT round(sum(cover_cost),2) FROM _ping)));

  UPDATE public.n2s_items SET notified_at = now() WHERE n2s_id = ANY(v_ids);
  RETURN QUERY SELECT v_items, v_offers, v_id;
END $function$;

REVOKE ALL ON FUNCTION public.n2s_sub_ping() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.n2s_sub_ping() TO service_role;
