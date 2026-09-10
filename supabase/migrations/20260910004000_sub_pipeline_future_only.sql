-- ============================================================================
-- Migration 20260910004000 — the sub pipeline looks at FUTURE events only
--
-- Lane:     D0 (orders surface)
-- Touches:  s4kcs_sub_candidates() + s4kcs_sub_worklist_refresh()
--           (CREATE OR REPLACE FUNCTION, filter change only)
-- Pre-reqs: 20260910003000
--
-- READ-ONLY: pure SELECT / rebuild. No upstream call.
--
-- Operator direction 2026-09-09: "only look at future events for this."
--
-- Both functions filtered `event_date >= current_date`, which INCLUDES today.
-- At the time of this change that was 779 of 26,334 queued orders, 39 of them
-- carrying a candidate worth $21,157 -- a sixth of the queue's total upside
-- sitting on events that, at 21:00 UTC (5pm ET), had largely already started
-- or finished. A cover you cannot buy in time is not an opportunity; it is
-- noise at the top of a list sorted by money.
--
-- Now `event_date > current_date`.
--
-- ⚠ THIS ALSO DROPS TONIGHT'S GENUINELY UNPLAYED EVENTS, and that is a
-- deliberate trade rather than an oversight. Deciding "has this event started?"
-- properly needs the venue's timezone: `event_date` is a bare date, and the
-- only start-time source, `events.occurs_at_local`, is local WALL CLOCK with no
-- zone attached (§3 mixed-timezone landmine). Comparing it to now() means
-- picking a zone to pretend in -- assume Eastern and western events vanish
-- three hours early; assume Pacific and eastern events linger three hours after
-- they have started. Either way the pipeline would be asserting something it
-- cannot actually know, and the failure mode of the second is worse: it offers
-- a sub for a game already in progress.
-- A whole-day boundary needs no zone and cannot be wrong in that direction.
-- If tonight's inventory is wanted back, the honest fix is to carry a real
-- start timestamptz per event, not to loosen this comparison.
-- ============================================================================

-- ── 1. matcher: future events only ──────────────────────────────────────────
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
     WHERE s.event_date > current_date          -- FUTURE ONLY (see header)
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

-- ── 2. queue refresh: same horizon, and evict today's rows ──────────────────
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
  -- An event that was future when it was queued becomes today, then past, and
  -- nothing in a scope-limited refresh would ever revisit it -- so a row could
  -- sit in the queue for a game already played. Evict on every run, cheaply.
  DELETE FROM public.s4kcs_sub_worklist WHERE event_date <= current_date;

  IF p_event_ids IS NOT NULL THEN
    v_events := p_event_ids;
  ELSIF p_since IS NULL THEN
    SELECT array_agg(DISTINCT s.tevo_event_id) INTO v_events
      FROM public.v_sub_orders s
     WHERE s.event_date > current_date AND s.tevo_event_id IS NOT NULL;
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
                  WHERE event_date > current_date AND tevo_event_id IS NOT NULL);
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
       AND s.event_date > current_date
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
