-- ============================================================================
-- Migration 20260910020000 — the sub pipeline looks at OPEN orders only
--
-- Lane:     D0 (orders surface) over A1's order books
-- Touches:  order_status_xref (INSERT — 7 reference rows, fills real gaps)
--           v_sub_orders (CREATE OR REPLACE VIEW — two APPENDED columns)
--           s4kcs_sub_candidates() + s4kcs_sub_worklist_refresh()
-- Pre-reqs: 20260910010000
--
-- READ-ONLY upstream: pure SELECT / rebuild. No upstream call.
--
-- Operator direction 2026-09-09: "only look at unfulfilled or pending orders
-- for this system, we dont care about anything fulfilled."
--
-- ── The classifier already existed; the pipeline just wasn't using it ───────
-- `order_status_xref` (mig 20260513230000) already normalises every source's
-- private status vocabulary to a canonical_status + is_terminal + a
-- is_sale_succeeded flag. The sub pipeline was filtering on nothing at all, so
-- it queued fulfilled, rejected and cancelled orders alongside live ones.
-- This wires the pipeline to that xref rather than hard-coding a second,
-- competing status vocabulary inside the matcher (§6 one-fact-one-home).
--
-- ⚠ THE CRM FEED CONTAINS NO FULFILLED ORDERS AT ALL — measured, not assumed.
-- Every status the six CRM marketplaces publish to us is an open state:
-- GoTickets is 100% PENDING_FULFILLMENT, Vivid 100% PENDING_SHIPMENT,
-- SeatGeek 100% confirmed, TickPick 100% CONFIRMED bar 6 REJECTED, StubHub is
-- entirely seller-action prompts, Gametime is unfulfilled/unconfirmed. So this
-- filter is nearly a no-op on the CRM side and does almost all of its work on
-- EVO, whose own book DOES carry terminal orders: 1,621 `completed`, 229
-- `rejected`, 40 cancelled. Anyone reading a small row-count delta should not
-- conclude the filter is broken.
--
-- ── The ambiguous middle is settled by existing convention, not by me ───────
-- StubHub's dispatched-but-undelivered states ("On the Way", "Print Shipping
-- Label", "Wait for Courier Pickup", "Wait for Delivery") were ALREADY mapped
-- to canonical `accepted` — i.e. still open — by the original xref author. The
-- three unmapped siblings found here ("Processing Transfer", "Tickets on the
-- way", plus "Under Review") are therefore classified the same way, for
-- consistency rather than on a fresh judgement of my own. A transfer in flight
-- is not a delivery confirmed, and the seller can still be asked for a sub.
--
-- ── Seven statuses were live in the feed and absent from the xref ──────────
-- An unmapped status is the dangerous case: it resolves to NULL and would slip
-- through any filter silently. All seven are seeded here so that today the
-- feed has ZERO unmapped statuses, and the fail-open branch below is a genuine
-- safety net rather than load-bearing logic.
--
-- ⚠ THE FILTER FAILS OPEN, DELIBERATELY. `is_open` is
-- `NOT COALESCE(is_terminal, false)`, so a status that appears in the feed
-- later and is never added to the xref stays VISIBLE in the queue. The
-- alternative — dropping what we cannot classify — hides live orders that need
-- a sub, and hides them silently. A stray fulfilled row costs a glance; a
-- vanished unfulfilled row costs a fill. If unmapped statuses start appearing,
-- the fix is an xref row, not a tighter default.
-- ============================================================================

-- ── 1. close the seven xref gaps ───────────────────────────────────────────
INSERT INTO public.order_status_xref
  (source, source_status, source_status_kind, canonical_status, is_terminal, is_sale_succeeded, notes)
VALUES
  -- Gametime: sale not yet confirmed by the seller. The single highest
  -- sub-risk state in the whole feed — emphatically open.
  ('s4kcs', 'unconfirmed',         'state', 'pending',  false, false, 'Gametime: awaiting seller confirmation'),
  -- StubHub: marketplace is reviewing the order. Not delivered, not dead.
  ('s4kcs', 'Under Review',        'state', 'pending',  false, false, 'StubHub: order under marketplace review'),
  -- StubHub: transfer initiated, delivery not confirmed. Matches the existing
  -- treatment of "On the Way" / "Wait for Courier Pickup" as accepted.
  ('s4kcs', 'Processing Transfer', 'state', 'accepted', false, false, 'StubHub: transfer in flight, delivery unconfirmed'),
  ('s4kcs', 'Tickets on the way',  'state', 'accepted', false, false, 'StubHub: alias of "On the Way"'),
  -- StubHub: bare problem state. Its verbose sibling "Issue reported:
  -- replacement tickets offered" is already canonical `substitution`; this one
  -- names no resolution, so it stays open rather than being called a sub.
  ('s4kcs', 'Issue',               'state', 'pending',  false, false, 'StubHub: unresolved issue, no resolution named'),
  -- EVO: both cancellation spellings are terminal and did not succeed.
  ('evo',   'canceled',                  'state', 'cancelled', true, false, 'EVO: cancelled'),
  ('evo',   'canceled_post_acceptance',  'state', 'cancelled', true, false, 'EVO: cancelled after acceptance')
ON CONFLICT DO NOTHING;

-- ── 2. v_sub_orders carries the canonical status ───────────────────────────
-- ⚠ canonical_status and is_open are APPENDED. CREATE OR REPLACE VIEW can only
-- ADD columns at the END — inserting or reordering one fails with "cannot
-- change name of view column" (§3 landmine, hit for real in commit 6d3bed8).
CREATE OR REPLACE VIEW public.v_sub_orders AS
  SELECT s.source,
         s.s4k_order_id                AS order_id,
         s.order_status,
         s.price_source                AS book,
         s.event_name,
         s.event_date,
         'crm_event_date'::text        AS date_source,
         s.venue_name,
         s.tevo_event_id,
         s.section,
         s."row",
         s.quantity,
         s.price_per_ticket,
         round(s.price_per_ticket * s.quantity, 2) AS order_total,
         s.purchase_date,
         s.inhand_date,
         x.canonical_status,
         NOT COALESCE(x.is_terminal, false) AS is_open   -- fails OPEN (header)
    FROM public.v_s4kcs_orders s
    LEFT JOIN public.order_status_xref x
      ON x.source = 's4kcs' AND x.source_status = s.order_status
  UNION ALL
  SELECT 'EVO'::text,
         i.evo_order_id::text,
         o.state,
         'evo_orders'::text,
         i.event_name,
         COALESCE(left(e.occurs_at_local, 10)::date, (i.occurs_at)::date),
         CASE WHEN e.occurs_at_local IS NOT NULL
              THEN 'events.occurs_at_local'::text
              ELSE 'evo_occurs_at_utc'::text
         END,
         i.venue_name,
         i.event_id,
         i.ticket_group_section,
         i.ticket_group_row,
         i.quantity,
         i.price,
         round(i.price * i.quantity, 2),
         o.evo_created_at::date,
         NULL::date,
         xe.canonical_status,
         NOT COALESCE(xe.is_terminal, false)
    FROM public.evo_order_items i
    JOIN public.evo_orders o ON o.evo_order_id = i.evo_order_id
    LEFT JOIN public.events e ON e.id = i.event_id
    LEFT JOIN public.order_status_xref xe
      ON xe.source = 'evo' AND xe.source_status = o.state
   WHERE i.event_id IS NOT NULL;

COMMENT ON VIEW public.v_sub_orders IS
  'One order feed for the substitution pipeline: our own book wherever we have '
  'a usable one (Vivid, GoTickets, EVO), the S4K CRM only for marketplaces we '
  'do not (StubHub, Gametime — plus SeatGeek and TickPick, whose own books are '
  'unusable: seatgeek_orders is live but 400 rows with ZERO mapped to an event, '
  'tickpick_orders is well-mapped but its ingest died 2026-05-31). EVO is '
  'unioned in because the CRM does not carry it at all. price_per_ticket is '
  'normalised for every source; `book` says which book supplied the price and '
  '`date_source` which clock supplied event_date. canonical_status normalises '
  'each marketplace''s private status vocabulary via order_status_xref, and '
  'is_open is NOT is_terminal — fulfilled, rejected and cancelled orders are '
  'false. is_open FAILS OPEN: a status missing from the xref reads as open, so '
  'an unclassified live order is never silently dropped.';

REVOKE ALL ON public.v_sub_orders FROM PUBLIC, anon;
GRANT SELECT ON public.v_sub_orders TO authenticated, service_role;
-- ── 3. matcher: open orders only ───────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.s4kcs_sub_candidates(
  p_sources           text[]   DEFAULT NULL,
  p_statuses          text[]   DEFAULT NULL,
  p_sub_sources       text[]   DEFAULT NULL,
  p_require_cheaper   boolean  DEFAULT true,
  p_exact_qty         boolean  DEFAULT true,
  p_max_listing_age   interval DEFAULT interval '12 hours',
  p_per_order         integer  DEFAULT 3,
  p_exclude_qualified boolean  DEFAULT true,
  p_event_ids         bigint[] DEFAULT NULL
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
    SELECT s.source, s.order_status, v.sub_signal, s.order_id AS s4k_order_id,
           s.event_name, s.event_date, s.venue_name, s.tevo_event_id,
           s.section, s."row" AS order_row, s.quantity,
           s.price_per_ticket AS sold_ea,
           public.seat_row_kind(s."row") AS ord_kind,
           public.seat_row_rank(s."row") AS ord_rank,
           public.seat_section_norm(s.section) AS sec_norm
      FROM public.v_sub_orders s
      LEFT JOIN public.v_s4kcs_sub_status v ON v.order_status = s.order_status
     WHERE s.event_date >= current_date         -- TODAY + FUTURE
       AND s.is_open                           -- OPEN ONLY (see header)
       AND s.tevo_event_id IS NOT NULL
       AND (p_sources   IS NULL OR s.source        = ANY(p_sources))
       AND (p_statuses  IS NULL OR s.order_status  = ANY(p_statuses))
       AND (p_event_ids IS NULL OR s.tevo_event_id = ANY(p_event_ids))
       AND public.seat_row_kind(s."row") IS NOT NULL
       AND s.price_per_ticket IS NOT NULL
       AND (NOT p_exclude_qualified
            OR public.seat_section_qualifier(s.section)
               !~ '(CLUB|VIP|OWNER|CHARTER|SUITE|STANDING ROOM|PREMIUM|LOGE BOX|BOX)')
  ),
  ev AS (SELECT DISTINCT tevo_event_id FROM o),
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
  l_tevo AS (
    SELECT 'tevo'::text AS sub_source, 'tevo_retail'::text AS sub_price_basis,
           t.tevo_ticket_group_id AS sub_listing_id, t.event_id AS tevo_event_id,
           t.section AS sub_section, t."row" AS sub_row, t.quantity AS sub_qty,
           t.retail_price AS sub_ea, NULL::text AS buy_url, t.captured_at
      FROM pin_tevo p
      JOIN public.listings_snapshots t
        ON t.event_id = p.tevo_event_id AND t.captured_at = p.captured_at
     WHERE NOT t.is_owned AND NOT t.is_ancillary
  ),
  l_gt AS (
    SELECT 'gotickets'::text, 'gt_all_in'::text,
           g.gt_listing_id, g.tevo_event_id,
           g.section, g."row", g.quantity, g.all_in_price,
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
       AND public.seat_section_norm(l.sub_section) = o.sec_norm
       AND (NOT p_exclude_qualified
            OR public.seat_section_qualifier(l.sub_section)
               !~ '(CLUB|VIP|OWNER|CHARTER|SUITE|STANDING ROOM|PREMIUM|LOGE BOX|BOX)')
       AND (CASE WHEN p_exact_qty THEN l.sub_qty = o.quantity
                 ELSE l.sub_qty >= o.quantity END)
       AND public.seat_row_kind(l.sub_row) = o.ord_kind
       AND public.seat_row_rank(l.sub_row) <= o.ord_rank
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

-- ── 4. queue refresh: same filter, and evict rows that have since closed ───
CREATE OR REPLACE FUNCTION public.s4kcs_sub_worklist_refresh(
  p_since      interval DEFAULT interval '12 minutes',
  p_statuses   text[]   DEFAULT NULL,
  p_event_ids  bigint[] DEFAULT NULL
)
RETURNS TABLE(events_refreshed integer, orders_written integer, with_candidate integer)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $function$
DECLARE
  v_events bigint[];
  v_orders int := 0;
  v_hits   int := 0;
BEGIN
  -- An event that was in scope when it was queued eventually goes past, and
  -- nothing in a scope-limited refresh would ever revisit it -- so a row could
  -- sit in the queue for a game already played. Evict on every run, cheaply.
  DELETE FROM public.s4kcs_sub_worklist WHERE event_date < current_date;

  -- Symmetrically: an order that was OPEN when it was queued can later be
  -- fulfilled, rejected or cancelled. Only a re-scoped event would notice, and
  -- a scope-limited refresh may not revisit that event for days -- so sweep
  -- closed orders unconditionally too. Driven off the small closed-order set
  -- rather than a correlated NOT EXISTS per queued row: the queue is ~26k rows
  -- and the view has no index to probe, so the anti-join shape matters.
  DELETE FROM public.s4kcs_sub_worklist w
   USING (SELECT source, order_id
            FROM public.v_sub_orders
           WHERE NOT is_open) closed
   WHERE w.source = closed.source
     AND w.s4k_order_id = closed.order_id;

  IF p_event_ids IS NOT NULL THEN
    v_events := p_event_ids;
  ELSIF p_since IS NULL THEN
    SELECT array_agg(DISTINCT s.tevo_event_id) INTO v_events
      FROM public.v_sub_orders s
     WHERE s.event_date >= current_date AND s.tevo_event_id IS NOT NULL
       AND s.is_open;
  ELSE
    SELECT array_agg(DISTINCT e) INTO v_events FROM (
      SELECT es.event_id AS e
        FROM public.evo_listings_poll_state es
       WHERE es.last_polled_listings_at >= now() - p_since
      UNION
      SELECT ge.tevo_event_id
        FROM public.gt_listings_poll_state gs
        JOIN public.gotickets_event ge ON ge.gt_event_id = gs.gt_event_id
       WHERE gs.last_polled_listings_at >= now() - p_since
         AND ge.tevo_event_id IS NOT NULL
    ) polled
     WHERE e IN (SELECT DISTINCT tevo_event_id FROM public.v_sub_orders
                  WHERE event_date >= current_date AND tevo_event_id IS NOT NULL
                    AND is_open);
  END IF;

  IF v_events IS NULL OR cardinality(v_events) = 0 THEN
    RETURN QUERY SELECT 0, 0, 0; RETURN;
  END IF;

  DELETE FROM public.s4kcs_sub_worklist w
   WHERE w.tevo_event_id = ANY(v_events);

  WITH scope AS (
    SELECT s.source, s.order_id AS s4k_order_id, s.tevo_event_id, s.event_name, s.event_date,
           s.venue_name, s.order_status, s.section, s."row" AS order_row, s.quantity,
           s.price_per_ticket AS sold_ea
      FROM public.v_sub_orders s
     WHERE s.tevo_event_id = ANY(v_events)
       AND s.event_date >= current_date
       AND s.is_open
       AND (p_statuses IS NULL OR s.order_status = ANY(p_statuses))
       AND s.price_per_ticket IS NOT NULL
  ),
  best AS (
    SELECT DISTINCT ON (c.source, c.s4k_order_id) c.*
      FROM public.s4kcs_sub_candidates(
             p_statuses  => p_statuses,
             p_per_order => 1,
             p_event_ids => v_events) c
     ORDER BY c.source, c.s4k_order_id, c.sub_ea
  ),
  cnt AS (
    SELECT c.source, c.s4k_order_id, count(*)::int AS n
      FROM public.s4kcs_sub_candidates(
             p_statuses  => p_statuses,
             p_per_order => 2147483647,
             p_event_ids => v_events) c
     GROUP BY 1, 2
  ),
  ins AS (
    INSERT INTO public.s4kcs_sub_worklist (
      source, s4k_order_id, tevo_event_id, event_name, event_date, venue_name,
      order_status, sub_signal, section, order_row, quantity, sold_ea, sold_total,
      candidates, best_sub_source, best_price_basis, best_listing_id, best_section,
      best_row, best_qty, best_ea, best_total, margin_ea, margin_total,
      rows_closer, buy_url, listing_captured_at, refreshed_at)
    SELECT sc.source, sc.s4k_order_id, sc.tevo_event_id, sc.event_name, sc.event_date,
           sc.venue_name, sc.order_status, b.sub_signal, sc.section, sc.order_row,
           sc.quantity, round(sc.sold_ea, 2), round(sc.sold_ea * sc.quantity, 2),
           COALESCE(n.n, 0), b.sub_source, b.sub_price_basis, b.sub_listing_id,
           b.sub_section, b.sub_row, b.sub_qty, b.sub_ea, b.sub_total,
           b.margin_ea, b.margin_total, b.rows_closer, b.buy_url, b.captured_at, now()
      FROM scope sc
      LEFT JOIN best b ON b.source = sc.source AND b.s4k_order_id = sc.s4k_order_id
      LEFT JOIN cnt  n ON n.source = sc.source AND n.s4k_order_id = sc.s4k_order_id
    RETURNING (best_listing_id IS NOT NULL) AS had_sub
  )
  SELECT count(*)::int, count(*) FILTER (WHERE had_sub)::int INTO v_orders, v_hits FROM ins;

  RETURN QUERY SELECT cardinality(v_events), v_orders, v_hits;
END $function$;

REVOKE ALL ON FUNCTION public.s4kcs_sub_worklist_refresh(interval,text[],bigint[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.s4kcs_sub_worklist_refresh(interval,text[],bigint[]) TO service_role;
REVOKE ALL ON FUNCTION public.s4kcs_sub_candidates(text[],text[],text[],boolean,boolean,interval,integer,boolean,bigint[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.s4kcs_sub_candidates(text[],text[],text[],boolean,boolean,interval,integer,boolean,bigint[]) TO authenticated, service_role;
