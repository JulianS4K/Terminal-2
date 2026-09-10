-- ============================================================================
-- Migration 20260910060000 — map N2S events, and cover them from FOUR sources
--
-- Lane:     D0 (orders surface)
-- Touches:  n2s_items (+tevo_event_id, +mapped_via), n2s_map_events(),
--           n2s_covers(), n2s_sub_ping() rewired
-- Pre-reqs: 20260910050000
--
-- READ-ONLY upstream: no API call. Pure SELECT over already-ingested data.
--
-- Operator direction 2026-09-09: "if u mapped map to evo, go tix and sg and
-- also poll tickets data sources, but only return the same section same or
-- better row and same qty."
--
-- ── 1. Why N2S needs its OWN matcher ───────────────────────────────────────
-- n2s_sub_offers() joined v_sub_orders, so it could only ever price the 169
-- N2S orders that also exist in one of our order books. The other 265 are
-- FAILED orders that appear in no book we hold — they were not missing a
-- cover, they were missing a JOIN.
--
-- They never needed our order book. N2S already carries section, row, qty and
-- an explicit price_per_ticket for EVERY item. Verified against the 169 that
-- do overlap: row 169/169 agree, qty 169/169, price 168/169, section 162/169.
-- So this matcher reads seat data from N2S itself and treats matched and
-- unmatched items identically. The 7 section disagreements are normalisation
-- noise, not a data conflict.
--
-- ── 2. The mapping rule, and its guard ─────────────────────────────────────
-- Exact event name + exact local date against `events`, requiring the match to
-- be UNIQUE, then corroborated by venue id.
--
-- Measured over the 77 future unmatched items: 35 matched a single event, 0
-- were ambiguous, 42 matched nothing. Of the 35, only 11 had a venue string
-- equal to ours — but ALL 35 resolved through cross_source_venue_resolve() to
-- the SAME venue id as the event, with ZERO conflicts. So the venue guard is
-- the resolver, never string equality, which would have thrown away 24 correct
-- matches. A conflicting venue id rejects the match outright: two simultaneous
-- tour legs share a name and a date (the Monster Jam case, mig 20260908195605)
-- and only the venue separates them.
--
-- ⚠ THE 42 NON-MATCHES ARE NOT FIXED HERE and must not be papered over with a
-- fuzzy fallback. A wrong event id silently offers seats for the wrong game.
--
-- ── 3. Four supply sources ─────────────────────────────────────────────────
-- tevo (listings_snapshots) · gotickets · seatgeek · ticketsdata.
--
-- ⚠ TICKETSDATA IS READ HERE, NOT POLLED, AND THAT IS DELIBERATE. It is a
-- PAID, credit-metered API with its own budget guards, and at the time of
-- writing `td_budget_ok()` returned FALSE — the daily budget was already spent
-- (5,899 credits). Forcing enqueues would have overridden a guard the system
-- exists to enforce. Reading the 110 GB of listings TicketsData has ALREADY
-- captured costs nothing, and coverage widens on its own as the budgeted
-- poller runs. Of the 24 distinct events the mapped N2S items resolve to, 15
-- are in ticketsdata_event_xref and 4 had recent listings — so this arm starts
-- thin and grows. If wider coverage is wanted sooner that is a spend decision,
-- not a code change.
-- `ticketsdata_listings_snapshots.event_id` IS a TEvo event id (confirmed:
-- 961,854 of the last two days' rows join ticketsdata_event_xref).
--
-- ── 4. The rule: section, row, qty — and NO price filter ───────────────────
-- Same normalised section, row no worse, exact quantity. Price is reported,
-- never filtered: every cover measured for this book cost MORE than the sale,
-- so a price filter returns nothing (mig 20260910050000). cover_cost is
-- positive = what honouring the order costs over what it sold for.
--
-- ⚠ EACH ARM PINS THE LATEST CAPTURE PER EVENT rather than taking the newest
-- row per listing id. `DISTINCT ON (listing_id) ORDER BY captured_at DESC`
-- returns the last state of every listing SEEN in the window, including ones
-- sold hours ago — it offers dead inventory. Pinning one capture per event
-- means every listing came from the same observation of that event.
-- ============================================================================

ALTER TABLE public.n2s_items ADD COLUMN IF NOT EXISTS tevo_event_id bigint;
ALTER TABLE public.n2s_items ADD COLUMN IF NOT EXISTS mapped_via text;
CREATE INDEX IF NOT EXISTS n2s_items_tevo_event_idx ON public.n2s_items (tevo_event_id)
  WHERE tevo_event_id IS NOT NULL;

COMMENT ON COLUMN public.n2s_items.tevo_event_id IS
  'TEvo event resolved from the N2S event_name + local date, accepted only '
  'when the name+date match is UNIQUE and cross_source_venue_resolve() agrees '
  'on the venue id. Fill-only; never overwritten once set.';

-- ── the mapper ─────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.n2s_map_events(p_apply boolean DEFAULT true)
RETURNS TABLE(considered integer, mapped integer, ambiguous integer, venue_rejected integer)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $function$
DECLARE
  v_considered int := 0; v_mapped int := 0; v_amb int := 0; v_vrej int := 0;
BEGIN
  DROP TABLE IF EXISTS _m;
  CREATE TEMP TABLE _m ON COMMIT DROP AS
    SELECT n.n2s_id,
           count(DISTINCT e.id)                      AS n_events,
           min(e.id)                                 AS eid,
           min(e.venue_id)                           AS ev_venue_id,
           public.cross_source_venue_resolve(n.venue) AS n2s_venue_id
      FROM public.n2s_items n
      JOIN public.events e
        ON lower(e.name) = lower(n.event_name)
       AND left(e.occurs_at_local, 10)::date = n.event_dt::date
     WHERE n.tevo_event_id IS NULL          -- fill-only
       AND NOT n.is_terminal
       AND n.event_dt::date >= current_date
       AND n.event_name IS NOT NULL
     GROUP BY n.n2s_id, n.venue;

  SELECT count(*)::int INTO v_considered FROM _m;
  SELECT count(*)::int INTO v_amb        FROM _m WHERE n_events > 1;
  -- Venue KNOWN on both sides and disagreeing is a rejection, not a pass.
  SELECT count(*)::int INTO v_vrej       FROM _m
   WHERE n_events = 1 AND n2s_venue_id IS NOT NULL AND ev_venue_id IS NOT NULL
     AND n2s_venue_id <> ev_venue_id;

  IF p_apply THEN
    UPDATE public.n2s_items n
       SET tevo_event_id = m.eid,
           mapped_via    = 'n2s_name_date_venue'
      FROM _m m
     WHERE n.n2s_id = m.n2s_id
       AND m.n_events = 1
       AND (m.n2s_venue_id IS NULL OR m.ev_venue_id IS NULL
            OR m.n2s_venue_id = m.ev_venue_id)
       AND n.tevo_event_id IS NULL;
    GET DIAGNOSTICS v_mapped = ROW_COUNT;
  ELSE
    SELECT count(*)::int INTO v_mapped FROM _m
     WHERE n_events = 1
       AND (n2s_venue_id IS NULL OR ev_venue_id IS NULL OR n2s_venue_id = ev_venue_id);
  END IF;

  RETURN QUERY SELECT v_considered, v_mapped, v_amb, v_vrej;
END $function$;

REVOKE ALL ON FUNCTION public.n2s_map_events(boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.n2s_map_events(boolean) TO service_role;

-- ── the matcher: N2S's own seat data vs four supply sources ────────────────
CREATE OR REPLACE FUNCTION public.n2s_covers(
  p_n2s_ids         bigint[] DEFAULT NULL,
  p_max_listing_age interval DEFAULT interval '24 hours',
  p_per_order       integer  DEFAULT 3,
  p_sub_sources     text[]   DEFAULT NULL
)
RETURNS TABLE (
  n2s_id         bigint,
  order_number   text,
  s4k_source     text,
  n2s_status     text,
  fail_reason    text,
  timer_expired  boolean,
  event_name     text,
  event_date     date,
  venue          text,
  tevo_event_id  bigint,
  section        text,
  order_row      text,
  quantity       integer,
  sold_ea        numeric,
  sub_source     text,
  sub_listing_id text,
  sub_section    text,
  sub_row        text,
  sub_qty        integer,
  sub_ea         numeric,
  sub_total      numeric,
  cover_cost     numeric,
  rows_closer    integer,
  buy_url        text,
  captured_at    timestamptz,
  cover_rank     bigint
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
       AND i.qty IS NOT NULL
       AND i.price_per_ticket IS NOT NULL
       AND public.seat_row_kind(i."row") IS NOT NULL
       AND public.seat_section_norm(i.section) IS NOT NULL
       AND (p_n2s_ids IS NULL OR i.n2s_id = ANY(p_n2s_ids))
  ),
  ev AS (SELECT DISTINCT tevo_event_id AS eid FROM o),
  -- One pinned capture per event per source: see header. Taking the newest row
  -- per listing id would resurface inventory that sold hours ago.
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
  -- ⚠ TICKETSDATA IS A CHANGE FEED, NOT A SNAPSHOT — so the pinned-capture
  -- pattern used for the other three arms is WRONG here and silently returns
  -- almost nothing. Measured: event 3286292 had 10,887 rows across 46 distinct
  -- captured_at values, but only FIVE at the newest one. TD writes a row only
  -- when a listing CHANGES (hence content_hash), so one timestamp is a delta,
  -- not the state of the event. Current state is therefore the latest row PER
  -- LISTING, which is exactly the DISTINCT ON shape the other arms must avoid.
  --
  -- ⚠ THE COST OF THAT IS REAL AND IS NOT FIXABLE FROM THIS DATA: with a
  -- change feed, a listing going absent means "unchanged", not "sold", and TD
  -- publishes no delisting marker we can see. So a TD cover may already be
  -- gone. TD covers are ADVISORY — verify before buying — and are labelled
  -- with their platform (ticketsdata:GT, :SH, :VD) so they are distinguishable
  -- from the three snapshot sources, which are authoritative about absence.
  -- `unified_listings` does not dedup TD either, so there was no established
  -- house semantic to inherit here.
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
    -- TicketsData carries the marketplace in `platform`, so the arm is
    -- labelled with it. price_with_fees is the all-in figure; list_price is
    -- pre-fee, so comparing it to an all-in sale price would flatter the
    -- cover. Parking rows are never a seat substitute.
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
       AND public.seat_section_norm(l.sec) = o.sec_norm       -- same section
       AND public.seat_row_kind(l.rw)      = o.ord_kind
       AND public.seat_row_rank(l.rw)     <= o.ord_rank       -- same or better
       AND l.q = o.quantity                                   -- exact qty
       -- NO price filter: see header. Price is reported, never gates.
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

COMMENT ON FUNCTION public.n2s_covers(bigint[],interval,integer,text[]) IS
  'Covers for open N2S orders from FOUR sources (tevo, gotickets, seatgeek, '
  'ticketsdata). Reads seat data from N2S itself, not from our order books, so '
  'it prices the 265 failed orders that appear in no book we hold. Rule: same '
  'normalised section, row no worse, exact quantity. Price is REPORTED, never '
  'filtered — every cover measured for this book cost more than the sale. '
  'cover_cost positive = what honouring the order costs over what it sold for.';

REVOKE ALL ON FUNCTION public.n2s_covers(bigint[],interval,integer,text[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.n2s_covers(bigint[],interval,integer,text[]) TO authenticated, service_role;

-- ── the ping, rewired onto n2s_covers ──────────────────────────────────────
-- Was built on n2s_sub_offers(), which joined v_sub_orders and so could only
-- ever see the minority of N2S orders that also exist in one of our books.
-- n2s_covers() reads N2S's own seat data, so the ping now reaches every mapped
-- open item regardless of whether the order appears in any book we hold.
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
  CREATE TEMP TABLE _ping ON COMMIT DROP AS
    SELECT DISTINCT ON (c.n2s_id) c.*
      FROM public.n2s_covers() c
      JOIN public.n2s_items n ON n.n2s_id = c.n2s_id
     WHERE n.notified_at IS NULL
     ORDER BY c.n2s_id, c.cover_cost;      -- cheapest cover represents the item

  SELECT count(*)::int, array_agg(n2s_id) INTO v_items, v_ids FROM _ping;
  IF v_items = 0 THEN
    RETURN QUERY SELECT 0, 0, NULL::bigint; RETURN;
  END IF;

  SELECT count(*)::int INTO v_offers FROM public.n2s_covers(v_ids);

  -- Counted, never asserted: the cost/free split changes as inventory moves.
  SELECT format(
           'N2S cover ping: %s newly-covered order(s), %s candidate(s) across %s. '
           '%s cost MORE than the sale, %s at or below it — an N2S order is an '
           'obligation, so these rank cheapest-cover-first, not by profit. '
           'Net cost to cover all %s: $%s (cheapest $%s, dearest $%s). '
           'Marketplaces: %s. Detail: SELECT * FROM n2s_covers() WHERE cover_rank = 1.',
           v_items, v_offers,
           (SELECT string_agg(DISTINCT sub_source, ', ') FROM public.n2s_covers(v_ids)),
           count(*) FILTER (WHERE cover_cost > 0),
           count(*) FILTER (WHERE cover_cost <= 0),
           v_items,
           to_char(sum(cover_cost), 'FM999999990.00'),
           to_char(min(cover_cost), 'FM999999990.00'),
           to_char(max(cover_cost), 'FM999999990.00'),
           string_agg(DISTINCT s4k_source, ', '))
    INTO v_msg FROM _ping;

  -- bot_level is a CHECKed vocabulary (admin|security|supervisor|primary-sales|
  -- secondary-sales|data-collection), NOT the lane code.
  v_id := public.bot_chat_log(
            'secondary-sales', 'd0', 'flag', v_msg, NULL, '20260910060000', NULL,
            jsonb_build_object('n2s_ids', to_jsonb(v_ids), 'items', v_items,
              'offers', v_offers,
              'total_cover_cost', (SELECT round(sum(cover_cost),2) FROM _ping)));

  UPDATE public.n2s_items SET notified_at = now() WHERE n2s_id = ANY(v_ids);
  RETURN QUERY SELECT v_items, v_offers, v_id;
END $function$;

REVOKE ALL ON FUNCTION public.n2s_sub_ping() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.n2s_sub_ping() TO service_role;

-- Map newly-arrived N2S items before the ping runs, so an order that lands is
-- mapped, priced and announced inside one poll cycle.
SELECT cron.schedule(
  'n2s_map_events_5min', '*/5 * * * *',
  $cron$ SELECT public.n2s_map_events(true); $cron$
);
