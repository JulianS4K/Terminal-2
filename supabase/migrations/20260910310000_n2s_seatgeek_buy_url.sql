-- ============================================================================
-- Migration 20260910310000 — give SeatGeek covers a buy link too
--
-- Lane:     D0 (orders surface)
-- Touches:  n2s_cover_candidates() (CREATE OR REPLACE — signature and return
--           type unchanged; only the SeatGeek arm's url expression changes).
-- Pre-reqs: 20260910300000
--
-- READ-ONLY upstream: assembles a URL string from stored columns. No API call.
-- RULE 2 untouched.
--
-- Operator supplied a live listing URL 2026-09-10:
--   https://seatgeek.com/new-york-yankees-tickets/9-11-2026-bronx-new-york-
--     yankee-stadium/mlb/17691592#listing=A6rs2KO4wGY
--
-- ── WHY THIS WAS NULL, AND WHY IT NO LONGER NEEDS TO BE ───────────────────
-- 20260910300000 gave TEvo a link and deliberately left SeatGeek NULL, on the
-- grounds that no console pattern was known and a GUESSED buy link does not
-- fail safely: it sends the operator to the wrong seats with real money. That
-- reasoning stands. What changed is that this no longer requires a guess.
--
-- Checked against the URL above rather than assumed:
--   * sg_events_canonical.sg_url for sg_event_id 17691592 is stored as
--     'https://seatgeek.com/new-york-yankees-tickets/9-11-2026-bronx-new-york-
--     yankee-stadium/mlb/17691592' — character-for-character the operator's
--     URL minus the fragment. The slug is NOT reconstructed here; it is the
--     value SeatGeek itself gave us.
--   * seatgeek_listings_snapshots.display_id holds the '#listing=' token.
--     It is an 11-char base62 string ('05VT8YqkO5r', '2v0czM2orlq'), the same
--     shape as A6rs2KO4wGY, and is a DIFFERENT identifier from the numeric
--     sglid we key listings on and emit as sub_listing_id. Using sglid in the
--     fragment would produce a URL that loads the event and silently
--     highlights nothing.
--
-- So the link is concatenation of two stored values, with no inference.
--
-- ⚠ BOTH PARTS OR NEITHER. Measured over the last 2h of live listings: 8,992
-- rows, 8,992 with a display_id (100%), 7,945 with an sg_url (88.4%), 0 with
-- an unexpected URL shape. The ~1,000 without a canonical URL emit NULL and
-- fall back to the panel printing ids, exactly as today. Half a URL — an event
-- page with no fragment, or a bare fragment — is worse than none, because it
-- looks like a working link.
--
-- ⚠ LEFT JOIN, NOT JOIN. sg_events_canonical is joined only to read sg_url.
-- An inner join would silently DROP every SeatGeek listing whose event has no
-- canonical row, converting a cosmetic missing link into lost covers. That is
-- the failure this migration could plausibly have introduced.
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
    -- Both ids come straight off this row, so the link is exact, not inferred.
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
    -- jsonb_typeof stops jsonb_array_elements_text raising on a non-array;
    -- the ~ '^[0-9]+$' filter stops the ::int cast raising on an element that
    -- is not a number. A list we cannot parse must degrade to strict matching,
    -- never to an error.
    --
    -- The buy URL is assembled from two stored values, not inferred: the
    -- event's own canonical consumer URL and the listing's display_id, which
    -- IS the #listing= fragment (an 11-char base62 token, distinct from the
    -- numeric sglid we key on). Both must be present or the link is NULL and
    -- the panel falls back to printing ids — 100% of live listings carry a
    -- display_id but only ~88% of their events carry an sg_url, and half a URL
    -- is worse than none.
    --
    -- ⚠ LEFT JOIN, NOT JOIN. An inner join here would silently DROP every
    -- SeatGeek listing whose event has no canonical row, turning a cosmetic
    -- missing link into lost covers.
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
    SELECT 'ticketsdata:' || td.platform, td.td_listing_id, td.eid,
           td.section, td."row", td.quantity,
           COALESCE(td.price_with_fees, td.list_price),
           NULL::text, td.captured_at, NULL::int[]
      FROM td_cur td
     WHERE NOT COALESCE(td.is_parking, false)
       AND COALESCE(td.price_with_fees, td.list_price) IS NOT NULL
       AND (p_sub_sources IS NULL OR 'ticketsdata' = ANY(p_sub_sources))
  ),
  mm AS (
    SELECT o.*, l.src, l.lid, l.sec, l.rw, l.q, l.ea, l.url, l.captured_at,
           CASE WHEN l.q = o.quantity
                  OR (l.q > o.quantity AND o.quantity = ANY(l.splits))
                THEN 1 ELSE 2 END AS tier
      FROM o JOIN l ON l.eid = o.tevo_event_id
       AND public.seat_section_norm(l.sec) = o.sec_norm
       AND public.seat_row_kind(l.rw)      = o.ord_kind
       AND public.seat_row_rank(l.rw)     <= o.ord_rank
       AND ( (l.q = o.quantity
              AND (l.splits IS NULL OR l.q = ANY(l.splits)))
          OR (l.q > o.quantity AND o.quantity = ANY(l.splits))
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
         buy_qty                                  AS sub_qty,
         q                                        AS sub_avail,
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
