-- Migration 20261113060000 · level:secondary-sales · lane:D0 · writes:sub_finder_config,sub_finder_order,sub_finder_site_norm,sub_finder_lookup,sub_finder_lookup_best,sub_finder_order_verified,sub_finder_order_closed,sub_finder_submit,sub_finder_autobuy,sub_finder_buy,sub_finder_gt_offer_request,sub_finder_gt_offer_buy,sub_finder_offer_json,sub_finder_refresh · reads:gotickets_sales,gotickets_event,tickpick_orders,vivid_orders,seatgeek_orders,evo_orders,evo_order_items,order_status_xref,n2s_items,v_s4kcs_orders,events · pre:20261113040000
--
-- SUB FINDER: the marketplace's own order feed first, the CRM's books as the fallback.
--
-- Operator 2026-11-13: "Utilize marketplaces we have apis first so we can track order status
-- live and bypass crm, use CRM as fallback", then "Also use API as primary source for prices".
--
-- An order number is now looked up, in this order:
--   1. 'api'          our own pull of the marketplace's seller order feed, by its order id:
--                     GoTickets (gotickets_sales), TickPick (tickpick_orders), Vivid
--                     (vivid_orders), SeatGeek (seatgeek_orders), EVO sales (evo_orders).
--                     Seats, quantity, sale price and status come from here.
--   2. 'n2s'          our mirror of the CRM's Need-to-Sub book (n2s_items)
--   3. 'marketplace'  our mirror of the CRM's marketplace order book (v_s4kcs_orders) — the
--                     only source for StubHub and Gametime, which have no feed of their own
-- A value the top source does not carry is filled from the next one that holds the SAME seats
-- and quantity (SeatGeek's feed carries no price; some GoTickets events are not mapped yet).
--
-- Order ids are plain numbers on several marketplaces, so a number alone can match two of
-- them. A marketplace-feed row is used only when it is on the marketplace the caller named
-- or, failing that, the one the CRM's books give for that number; with neither, only when
-- exactly one feed holds the number.
--
-- Live status: "the sale is over" is now read from that same lookup (each feed by its indexed
-- order id) instead of v_sub_orders, whose EVO arm cost about 1.7 s a lookup. So the refresh
-- job checks up to feed_check_batch (20) watched orders a tick, each every feed_check_every
-- (2 minutes), where it did 3 every 15 minutes. An order from the N2S book still also closes
-- when it leaves that book (sub_finder_order.in_n2s).
--
-- Every purchase / offer check that compared the order with "our own books" now uses the same
-- lookup (sub_finder_order_verified): the marketplace feed counts as our book. The automatic
-- gate 1 buy still never takes an order that is in the N2S book.
--
-- Reads only. No upstream call, no new write path.
--
-- rollback: re-apply sub_finder_submit and sub_finder_refresh from 20261112010000, sub_finder_autobuy
--           from 20261113040000, sub_finder_buy from 20261113030000, and sub_finder_gt_offer_request /
--           sub_finder_gt_offer_buy / sub_finder_offer_json from 20261113020000; then
--           DROP FUNCTION public.sub_finder_order_closed(text, text), public.sub_finder_order_verified(public.sub_finder_order, text[], boolean),
--             public.sub_finder_lookup_best(text, text), public.sub_finder_lookup(text), public.sub_finder_site_norm(text);
--           ALTER TABLE public.sub_finder_order DROP COLUMN in_n2s;
--           ALTER TABLE public.sub_finder_config DROP COLUMN feed_check_batch, DROP COLUMN feed_check_every;

ALTER TABLE public.sub_finder_config
  ADD COLUMN IF NOT EXISTS feed_check_batch integer  NOT NULL DEFAULT 20,
  ADD COLUMN IF NOT EXISTS feed_check_every interval NOT NULL DEFAULT interval '2 minutes';
ALTER TABLE public.sub_finder_order
  ADD COLUMN IF NOT EXISTS in_n2s boolean NOT NULL DEFAULT false;   -- was in the CRM's N2S book when looked up

-- One key per marketplace, however a source spells it: 'Go Tickets' = 'GoTickets' = gotickets,
-- 'Vivid' = 'Vivid Seats' = vivid, 'EVO' = 'TEvo' = 'Ticket Evolution' = evo, 'Stubhub 2.0' = stubhub,
-- 'Gametime.Co' = gametime. An unknown name keeps its letters; NULL stays NULL.
CREATE OR REPLACE FUNCTION public.sub_finder_site_norm(p text)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
AS $$
  SELECT CASE
    WHEN k IS NULL THEN NULL
    WHEN k LIKE 'gotick%' OR k = 'gotix' THEN 'gotickets'
    WHEN k LIKE 'tickpick%' THEN 'tickpick'
    WHEN k LIKE 'vivid%' THEN 'vivid'
    WHEN k LIKE 'seatgeek%' THEN 'seatgeek'
    WHEN k IN ('evo', 'tevo') OR k LIKE 'ticketevo%' THEN 'evo'
    WHEN k LIKE 'stubhub%' THEN 'stubhub'
    WHEN k LIKE 'gametime%' THEN 'gametime'
    WHEN k LIKE 'viagogo%' THEN 'viagogo'
    WHEN k LIKE 'ticketmaster%' THEN 'ticketmaster'
    ELSE k END
  FROM (SELECT nullif(lower(regexp_replace(coalesce(p, ''), '[^A-Za-z]', '', 'g')), '') AS k) q;
$$;

-- Every row we hold for one order number, best source first (rnk 1 = the marketplace's feed).
CREATE OR REPLACE FUNCTION public.sub_finder_lookup(p_order text)
 RETURNS TABLE (rnk integer, book text, site text, tevo_event_id bigint, event_name text, event_date date,
                venue text, section text, seat_row text, qty integer, sold_ea numeric, status text,
                is_open boolean, pulled_at timestamptz)
 LANGUAGE sql
 STABLE
 SECURITY DEFINER
 SET search_path = public, pg_temp
AS $$
  WITH n AS (SELECT CASE WHEN p_order ~ '^\d{1,18}$' THEN p_order::bigint END AS num)
  SELECT 1, 'api', 'GoTickets', ge.tevo_event_id, g.event_name, g.event_time_local::date, g.venue_name,
         g.section, g.row, g.quantity,
         coalesce(g.unit_cost, round(g.total_payout / nullif(g.quantity, 0), 2)),
         s.st, s.st = 'open', g.pulled_at
  FROM n JOIN public.gotickets_sales g ON g.gt_sale_id = n.num
  LEFT JOIN public.gotickets_event ge ON ge.gt_event_id = g.gt_event_id
  CROSS JOIN LATERAL (SELECT CASE
           WHEN g.raw->>'cancelReason' IS NOT NULL THEN CASE WHEN g.raw->>'cancelReason' = 'REJECTED' THEN 'rejected' ELSE 'cancelled' END
           WHEN coalesce(g.fulfilled, false)
             OR g.seller_status IN ('COMPLETED', 'PENDING_TRANSFER_PROOF', 'PENDING_PROOF_OF_PICKUP') THEN 'fulfilled'
           ELSE 'open' END AS st) s
  UNION ALL
  SELECT 1, 'api', 'TickPick', t.tevo_event_id, t.event_name, t.event_date::date, NULL,
         t.section, t.row, t.quantity, t.total,           -- tickpick_orders.total is the per-ticket price
         CASE WHEN coalesce(x.is_terminal, false) THEN x.canonical_status ELSE 'open' END,
         NOT coalesce(x.is_terminal, false), t.pulled_at
  FROM public.tickpick_orders t
  LEFT JOIN public.order_status_xref x ON x.source = 'tickpick' AND x.source_status = lower(t.order_status)
  WHERE t.tp_order_id = p_order
  UNION ALL
  SELECT 1, 'api', 'Vivid Seats', v.tevo_event_id, v.event_name, v.event_date::date, NULL,
         v.section, v.row, v.quantity, v.total,           -- vivid_orders.total is the per-ticket price
         CASE WHEN coalesce(x.is_terminal, false) THEN x.canonical_status ELSE 'open' END,
         NOT coalesce(x.is_terminal, false), v.pulled_at
  FROM public.vivid_orders v
  LEFT JOIN public.order_status_xref x ON x.source = 'vivid' AND x.source_status = v.status
  WHERE v.vivid_order_id = p_order
  UNION ALL
  SELECT 1, 'api', 'SeatGeek', g.tevo_event_id, g.sg_event_name, g.sg_event_date, g.sg_venue,
         g.sale_section, g.sale_row, g.sale_quantity, g.sale_price,
         CASE WHEN coalesce(x.is_terminal, false) THEN x.canonical_status ELSE 'open' END,
         NOT coalesce(x.is_terminal, false), g.pulled_at
  FROM public.seatgeek_orders g
  LEFT JOIN public.order_status_xref x ON x.source = 'seatgeek' AND x.source_status = g.status
  WHERE g.sg_order_id = p_order
  UNION ALL
  SELECT 1, 'api', 'Ticket Evolution', i.event_id, i.event_name, i.occurs_at::date, i.venue_name,
         i.ticket_group_section, i.ticket_group_row, i.quantity, i.price,
         CASE WHEN coalesce(x.is_terminal, false) THEN x.canonical_status ELSE 'open' END,
         NOT coalesce(x.is_terminal, false), o.pulled_at
  FROM n JOIN public.evo_orders o ON o.evo_order_id = n.num AND o.seller_brokerage_id = 1768   -- our sales only
  JOIN public.evo_order_items i ON i.evo_order_id = o.evo_order_id
  LEFT JOIN public.order_status_xref x ON x.source = 'evo' AND x.source_status = o.state
  UNION ALL
  SELECT 2, 'n2s', i.marketplace, i.tevo_event_id, i.event_name, i.event_dt::date, i.venue,
         i.section, i.row, i.qty, i.price_per_ticket, 'open', true, i.pulled_at
  FROM public.n2s_items i
  WHERE i.order_number = p_order OR i.n2s_order_key = p_order
  UNION ALL
  SELECT 3, 'marketplace', c.source, c.tevo_event_id, c.event_name, c.event_date, c.venue_name,
         c.section, c.row, c.quantity, c.price_per_ticket,
         CASE WHEN coalesce(x.is_terminal, false) THEN x.canonical_status ELSE 'open' END,
         NOT coalesce(x.is_terminal, false), c.pulled_at
  FROM public.v_s4kcs_orders c
  LEFT JOIN public.order_status_xref x ON x.source = 's4kcs' AND x.source_status = c.order_status
  WHERE c.s4k_order_id = p_order;
$$;

-- The one answer for an order number: seats and quantity from the best usable source; event,
-- names and price from it, or from the next source that holds the same seats and quantity.
CREATE OR REPLACE FUNCTION public.sub_finder_lookup_best(p_order text, p_site text DEFAULT NULL)
 RETURNS TABLE (book text, site text, tevo_event_id bigint, event_name text, event_date date, venue text,
                section text, seat_row text, qty integer, sold_ea numeric)
 LANGUAGE sql
 STABLE
 SECURITY DEFINER
 SET search_path = public, pg_temp
AS $$
  WITH l AS MATERIALIZED (SELECT * FROM public.sub_finder_lookup(p_order)),
  hint AS (SELECT coalesce(public.sub_finder_site_norm(p_site),
                           (SELECT public.sub_finder_site_norm(x.site) FROM l x WHERE x.book <> 'api'
                             ORDER BY x.rnk, x.pulled_at DESC NULLS LAST LIMIT 1)) AS h),
  ok AS (
    -- a marketplace-feed row only on the marketplace we were told (or the CRM gives) for this
    -- number; with no such hint, only when a single feed holds the number
    SELECT l.* FROM l, hint
     WHERE l.book <> 'api'
        OR CASE WHEN hint.h IS NOT NULL THEN public.sub_finder_site_norm(l.site) = hint.h
                ELSE (SELECT count(DISTINCT y.site) FROM l y WHERE y.book = 'api') = 1 END),
  top AS (SELECT * FROM ok WHERE ok.section IS NOT NULL AND ok.seat_row IS NOT NULL AND ok.qty IS NOT NULL
           ORDER BY ok.rnk, ok.pulled_at DESC NULLS LAST LIMIT 1),
  same AS (SELECT ok.* FROM ok, top
            WHERE public.seat_section_norm(ok.section) = public.seat_section_norm(top.section)
              AND upper(btrim(ok.seat_row)) = upper(btrim(top.seat_row)) AND ok.qty = top.qty)
  SELECT top.book, top.site,
         (SELECT s.tevo_event_id FROM same s WHERE s.tevo_event_id IS NOT NULL ORDER BY s.rnk, s.pulled_at DESC NULLS LAST LIMIT 1),
         (SELECT s.event_name FROM same s WHERE s.event_name IS NOT NULL ORDER BY s.rnk, s.pulled_at DESC NULLS LAST LIMIT 1),
         (SELECT s.event_date FROM same s WHERE s.event_date IS NOT NULL ORDER BY s.rnk, s.pulled_at DESC NULLS LAST LIMIT 1),
         (SELECT s.venue FROM same s WHERE s.venue IS NOT NULL ORDER BY s.rnk, s.pulled_at DESC NULLS LAST LIMIT 1),
         top.section, top.seat_row, top.qty,
         (SELECT s.sold_ea FROM same s WHERE s.sold_ea IS NOT NULL ORDER BY s.rnk, s.pulled_at DESC NULLS LAST LIMIT 1)
  FROM top;
$$;

-- Is this order, as we hold it, the one in our own records? ONE row — the newest we hold in
-- one of p_books, on the order's own marketplace — must carry the same event, section, row and
-- quantity (and the same sale price when p_need_price). And the number must belong to a single
-- marketplace across everything we hold: a number that sits on two is never verified. What a
-- caller sent that differs from our records fails here, so it can steer a search but never a
-- purchase or an offer.
CREATE OR REPLACE FUNCTION public.sub_finder_order_verified(o public.sub_finder_order, p_books text[], p_need_price boolean)
 RETURNS boolean
 LANGUAGE sql
 STABLE
 SECURITY DEFINER
 SET search_path = public, pg_temp
AS $$
  WITH l AS MATERIALIZED (SELECT * FROM public.sub_finder_lookup(o.order_number)),
  newest AS (
    SELECT DISTINCT ON (l.book) l.* FROM l
     WHERE l.book = ANY (p_books)
       AND public.sub_finder_site_norm(l.site) = public.sub_finder_site_norm(o.site)
     ORDER BY l.book, l.pulled_at DESC NULLS LAST)
  SELECT o.tevo_event_id IS NOT NULL
     AND public.sub_finder_site_norm(o.site) IS NOT NULL
     AND (SELECT count(DISTINCT coalesce(public.sub_finder_site_norm(l.site), '?')) FROM l) = 1
     AND EXISTS (SELECT 1 FROM newest n
                  WHERE n.tevo_event_id = o.tevo_event_id
                    AND public.seat_section_norm(n.section) = public.seat_section_norm(o.section)
                    AND upper(btrim(n.seat_row)) = upper(btrim(o.seat_row)) AND n.qty = o.qty
                    AND (NOT p_need_price OR abs(n.sold_ea - o.sold_ea) <= 0.01));
$$;

-- 'fulfilled' / 'cancelled' / 'rejected' when the marketplace's feed (or, failing that, our
-- mirror of the CRM marketplace book) says the sale is over; NULL while it is live or unknown.
-- Fails closed: a finished row counts unless it is clearly another marketplace's order (both
-- marketplace names known and different).
CREATE OR REPLACE FUNCTION public.sub_finder_order_closed(p_order text, p_site text)
 RETURNS text
 LANGUAGE sql
 STABLE
 SECURITY DEFINER
 SET search_path = public, pg_temp
AS $$
  SELECT l.status FROM public.sub_finder_lookup(p_order) l
   WHERE NOT l.is_open AND l.book <> 'n2s' AND l.status IN ('fulfilled', 'cancelled', 'rejected')
     AND (public.sub_finder_site_norm(p_site) IS NULL OR public.sub_finder_site_norm(l.site) IS NULL
          OR public.sub_finder_site_norm(l.site) = public.sub_finder_site_norm(p_site))
   ORDER BY l.rnk, l.pulled_at DESC NULLS LAST LIMIT 1;
$$;

CREATE OR REPLACE FUNCTION public.sub_finder_submit(
  p_key_id bigint, p_key_label text, p_orders jsonb, p_idempotency_key text DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path = public, pg_temp
AS $$
DECLARE
  c       public.sub_finder_config;
  v_job   uuid;
  v_n     integer;
  v_evs   bigint[];
  v_miss  jsonb;
  v_idem  text := nullif(btrim(coalesce(p_idempotency_key, '')), '');
BEGIN
  SELECT * INTO c FROM public.sub_finder_config;
  IF NOT c.enabled OR NOT (p_key_id = ANY (c.key_ids)) THEN
    RETURN jsonb_build_object('error', 'forbidden', 'detail', 'this key may not use the sub finder');
  END IF;
  IF v_idem IS NOT NULL THEN
    SELECT job_id INTO v_job FROM public.sub_finder_job WHERE key_id = p_key_id AND idempotency_key = v_idem;
    IF FOUND THEN
      RETURN (SELECT jsonb_build_object('job_id', j.job_id, 'status', j.status, 'order_count', j.order_count,
                                        'created_at', j.created_at, 'replayed', true)
              FROM public.sub_finder_job j WHERE j.job_id = v_job);
    END IF;
  END IF;
  IF jsonb_typeof(p_orders) IS DISTINCT FROM 'array' OR jsonb_array_length(p_orders) = 0 THEN
    RETURN jsonb_build_object('error', 'invalid', 'detail', 'orders must be a non-empty array');
  END IF;
  IF jsonb_array_length(p_orders) > c.max_orders_per_job THEN
    RETURN jsonb_build_object('error', 'invalid',
                              'detail', format('at most %s orders per job', c.max_orders_per_job));
  END IF;

  IF to_regclass('pg_temp._sf_in') IS NOT NULL THEN DROP TABLE _sf_in; END IF;
  CREATE TEMP TABLE _sf_in ON COMMIT DROP AS
  SELECT o.ord::int AS idx, btrim(o.j->>'order_number') AS order_number,
         coalesce(nullif(btrim(o.j->>'site'), ''), m.site)                 AS site,
         coalesce(nullif(btrim(o.j->>'section'), ''), m.section)           AS section,
         coalesce(nullif(btrim(o.j->>'row'), ''), m.seat_row)              AS seat_row,
         coalesce((o.j->>'qty')::int, m.qty)                               AS qty,
         coalesce((o.j->>'sold_ea')::numeric, m.sold_ea)                   AS sold_ea,
         (o.j->>'tevo_event_id')::bigint                                   AS sent_event,
         m.tevo_event_id                                                   AS book_event,
         coalesce(nullif(btrim(o.j->>'event_name'), ''), m.event_name)     AS event_name,
         coalesce((o.j->>'event_date')::date, m.event_date)                AS event_date,
         coalesce(nullif(btrim(o.j->>'venue'), ''), m.venue)               AS venue,
         m.book
  FROM jsonb_array_elements(p_orders) WITH ORDINALITY o(j, ord)
  -- the marketplace's own order feed first, then our mirror of the CRM's books
  LEFT JOIN LATERAL public.sub_finder_lookup_best(btrim(o.j->>'order_number'), nullif(btrim(o.j->>'site'), '')) m ON true;

  SELECT jsonb_agg(order_number ORDER BY idx) INTO v_miss FROM _sf_in
   WHERE section IS NULL OR seat_row IS NULL OR qty IS NULL OR qty NOT BETWEEN 1 AND 50;
  SELECT count(*) INTO v_n FROM _sf_in
   WHERE section IS NOT NULL AND seat_row IS NOT NULL AND qty BETWEEN 1 AND 50;
  IF v_n = 0 THEN
    RETURN jsonb_build_object('error', 'not_found', 'not_found', v_miss,
      'detail', 'none of these orders is in the CRM books we mirror; send section, row, qty and the event');
  END IF;

  INSERT INTO public.sub_finder_job (key_id, key_label, idempotency_key, order_count)
  VALUES (p_key_id, p_key_label, v_idem, v_n) RETURNING job_id INTO v_job;

  INSERT INTO public.sub_finder_order (job_id, idx, key_id, order_number, site, tevo_event_id, event_name,
                                       event_date, venue, section, seat_row, qty, sold_ea, state, order_source)
  SELECT v_job, i.idx, p_key_id, i.order_number, i.site, ev.id, coalesce(ev.name, i.event_name),
         coalesce(ev.occurs_at_local::date, i.event_date), i.venue, i.section, i.seat_row, i.qty, i.sold_ea,
         CASE WHEN ev.id IS NULL THEN 'unmapped' ELSE 'pending' END,
         coalesce(i.book, 'request')
  FROM _sf_in i
  LEFT JOIN LATERAL (
    SELECT e.id, e.name, e.occurs_at_local
    FROM public.events e
    WHERE CASE WHEN i.sent_event IS NOT NULL THEN e.id = i.sent_event
               WHEN i.book_event IS NOT NULL THEN e.id = i.book_event
               ELSE lower(e.name) = lower(i.event_name) AND e.occurs_at_local::date = i.event_date
                    AND (SELECT count(*) FROM public.events e2
                         WHERE lower(e2.name) = lower(i.event_name)
                           AND e2.occurs_at_local::date = i.event_date) = 1
          END
    LIMIT 1) ev ON true
  WHERE i.section IS NOT NULL AND i.seat_row IS NOT NULL AND i.qty BETWEEN 1 AND 50;

  UPDATE public.sub_finder_order t
     SET in_n2s = true
   WHERE t.job_id = v_job AND EXISTS (SELECT 1 FROM public.n2s_items n
                                       WHERE n.order_number = t.order_number OR n.n2s_order_key = t.order_number);

  -- a new lookup of an order takes over: older lookups of it stop being refreshed
  UPDATE public.sub_finder_order o
     SET watching = false, closed_reason = 'superseded', closed_at = now()
   WHERE o.key_id = p_key_id AND o.watching AND o.job_id <> v_job
     AND o.order_number IN (SELECT n.order_number FROM public.sub_finder_order n WHERE n.job_id = v_job);
  -- nothing to refresh on an order with no event
  UPDATE public.sub_finder_order SET watching = false, closed_reason = 'unmapped', closed_at = now()
   WHERE job_id = v_job AND state = 'unmapped';

  -- Pull only the events the routine polling does not already have: one with EVO listings
  -- pulled within refresh_fresh is being polled (N2S does every open order's event, every
  -- market, about every 2 minutes), so its data is used as it stands.
  SELECT array_agg(DISTINCT o.tevo_event_id) INTO v_evs
  FROM public.sub_finder_order o
  WHERE o.job_id = v_job AND o.tevo_event_id IS NOT NULL
    AND NOT EXISTS (SELECT 1 FROM public.n2s_evo_current x
                    WHERE x.event_id = o.tevo_event_id AND x.pulled_at > now() - c.refresh_fresh);
  IF v_evs IS NOT NULL THEN
    PERFORM public.n2s_pull_events(v_evs, c.pull_refresh);
  ELSE
    -- nothing to wait for: answer now (also closes a job whose orders are all unmapped)
    UPDATE public.sub_finder_job SET pulled = false WHERE job_id = v_job;
    PERFORM public.sub_finder_settle(v_job);
  END IF;

  RETURN (SELECT jsonb_build_object('job_id', j.job_id, 'status', j.status, 'order_count', j.order_count,
                                    'created_at', j.created_at, 'replayed', false,
                                    'not_found', coalesce(v_miss, '[]'::jsonb),
                                    'unmapped', (SELECT count(*) FROM public.sub_finder_order o
                                                 WHERE o.job_id = v_job AND o.state = 'unmapped'))
          FROM public.sub_finder_job j WHERE j.job_id = v_job);
END
$$;

CREATE OR REPLACE FUNCTION public.sub_finder_autobuy(p_job_id uuid)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path = public, pg_temp
AS $$
DECLARE
  c       public.sub_finder_config;
  j       public.sub_finder_job;
  o       public.sub_finder_order;
  cv      jsonb;
  v_note  text;
  v_buy   bigint;
  v_spent numeric;
  v_n     integer := 0;
  v_today date := (now() AT TIME ZONE 'America/New_York')::date;
BEGIN
  SELECT * INTO c FROM public.sub_finder_config;
  IF c.auto_buy_enabled THEN
    PERFORM pg_advisory_xact_lock(hashtext('sub_finder_autobuy'));   -- one cap check + request at a time
  END IF;
  SELECT * INTO j FROM public.sub_finder_job WHERE job_id = p_job_id;
  FOR o IN SELECT * FROM public.sub_finder_order
            WHERE job_id = p_job_id AND watching AND buy_id IS NULL AND state = 'cover' ORDER BY idx
  LOOP
    v_buy := NULL;
    -- the cheapest EVO one-to-one: at breakeven or better, our own feed, exact quantity, clear view
    SELECT x INTO cv FROM jsonb_array_elements(o.covers) WITH ORDINALITY t(x, n)
     WHERE x->>'market' = 'evo' AND x->>'source' = 'native' AND public.sub_finder_autobuy_gate(x)
       AND (x->>'spare')::int = 0 AND x->>'view' IS DISTINCT FROM 'obstructed'
       AND (x->>'profit')::numeric >= (x->>'total')::numeric * c.auto_buy_min_profit_pct / 100.0
     ORDER BY n LIMIT 1;
    v_note := CASE
      WHEN NOT c.auto_buy_enabled THEN 'auto_buy_off'
      WHEN cv IS NOT NULL THEN NULL
      WHEN NOT EXISTS (SELECT 1 FROM jsonb_array_elements(o.covers) x
                       WHERE x->>'market' = 'evo' AND x->>'source' = 'native' AND public.sub_finder_autobuy_gate(x))
        THEN 'no_evo_one_to_one'
      WHEN NOT EXISTS (SELECT 1 FROM jsonb_array_elements(o.covers) x
                       WHERE x->>'market' = 'evo' AND public.sub_finder_autobuy_gate(x) AND (x->>'spare')::int = 0)
        THEN 'needs_spare_ticket'
      WHEN NOT EXISTS (SELECT 1 FROM jsonb_array_elements(o.covers) x
                       WHERE x->>'market' = 'evo' AND public.sub_finder_autobuy_gate(x) AND (x->>'spare')::int = 0
                         AND x->>'view' IS DISTINCT FROM 'obstructed')
        THEN 'obstructed_view'
      ELSE 'profit_too_thin' END;
    IF v_note IS NULL AND (
         EXISTS (SELECT 1 FROM public.n2s_items n
                 WHERE n.order_number = o.order_number OR n.n2s_order_key = o.order_number)
         OR EXISTS (SELECT 1 FROM public.n2s_autobuy_exec x WHERE x.order_number = o.order_number)) THEN
      v_note := 'n2s_order';                           -- anything in the N2S book is never bought here
    END IF;
    IF v_note IS NULL AND EXISTS (
         SELECT 1 FROM public.manual_sub_buy b
          WHERE b.sale_order_number = o.order_number
            AND b.state IN ('requested', 'buying', 'bought', 'unknown')) THEN
      v_note := 'already_bought_for_this_sale';        -- whatever site name the other request used
    END IF;
    IF v_note IS NULL THEN
      -- the purchase is decided on OUR copy of the order, not on what the caller sent
      -- (the marketplace's own order feed, or our mirror of the CRM marketplace book; never N2S's)
      IF NOT public.sub_finder_order_verified(o, ARRAY['api', 'marketplace'], true) THEN
        v_note := CASE WHEN (SELECT count(DISTINCT public.sub_finder_site_norm(l.site))
                               FROM public.sub_finder_lookup(o.order_number) l) = 1
                        AND EXISTS (SELECT 1 FROM public.sub_finder_lookup(o.order_number) l WHERE l.book <> 'n2s')
                       THEN 'differs_from_our_books' ELSE 'not_in_our_books' END;
      -- the sale must still be live on its marketplace
      ELSIF public.sub_finder_order_closed(o.order_number, o.site) IS NOT NULL THEN
        v_note := 'order_closed';
      END IF;
    END IF;
    IF v_note IS NULL THEN
      SELECT coalesce(sum(coalesce(b.bought_total_usd, round(b.max_price_ea * b.qty, 2))), 0) INTO v_spent
        FROM public.manual_sub_buy b
       WHERE b.requested_by LIKE 'sub finder auto%' AND b.state IN ('requested', 'buying', 'bought', 'unknown')
         AND (b.created_at AT TIME ZONE 'America/New_York')::date = v_today;
      IF v_spent + (cv->>'total')::numeric > c.auto_buy_daily_cap_usd THEN v_note := 'over_daily_cap'; END IF;
    END IF;
    IF v_note IS NULL THEN
      BEGIN
        v_buy := public.manual_sub_buy_request(
          coalesce(o.site, 'CRM'), o.order_number, o.tevo_event_id, (cv->>'listing_id')::bigint,
          (cv->>'buy_qty')::int, (cv->>'price_ea')::numeric, o.sold_ea, o.event_name,
          'sub finder auto (key ' || coalesce(j.key_label, o.key_id::text) || ')',
          'auto: gate ' || (cv->>'gate') || ', sold ' || o.section || ' row ' || o.seat_row || ' x' || o.qty
            || '; sub ' || (cv->>'section') || ' row ' || (cv->>'row') || ' x' || (cv->>'buy_qty')
            || ', quoted profit ' || (cv->>'profit'));
        v_n := v_n + 1;
      EXCEPTION WHEN unique_violation THEN
        v_note := 'already_bought_for_this_sale';
      END;
    END IF;
    UPDATE public.sub_finder_order
       SET buy_id = coalesce(v_buy, buy_id),
           action = CASE WHEN v_buy IS NOT NULL THEN 'auto_bought' ELSE action END,
           auto_buy_note = v_note,
           updated_at = CASE WHEN v_buy IS NOT NULL OR auto_buy_note IS DISTINCT FROM v_note THEN now()
                             ELSE updated_at END
     WHERE job_id = o.job_id AND idx = o.idx;
  END LOOP;
  RETURN v_n;
END
$$;

CREATE OR REPLACE FUNCTION public.sub_finder_buy(
  p_key_id bigint, p_key_label text, p_job_id uuid, p_order_number text, p_listing_id text,
  p_requested_by text DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path = public, pg_temp
AS $$
DECLARE
  o     public.sub_finder_order;
  cv    jsonb;
  v_buy bigint;
  v_n   integer;
BEGIN
  IF NOT coalesce((public.sub_finder_access(p_key_id)->>'buy')::boolean, false) THEN
    RETURN jsonb_build_object('error', 'forbidden', 'detail', 'buying is not enabled for this key');
  END IF;
  SELECT count(*) INTO v_n FROM public.sub_finder_order
   WHERE job_id = p_job_id AND key_id = p_key_id AND order_number = p_order_number;
  IF v_n = 0 THEN RETURN jsonb_build_object('error', 'not_found', 'detail', 'no such order in this job'); END IF;
  IF v_n > 1 THEN
    RETURN jsonb_build_object('error', 'conflict', 'detail', 'this order number appears more than once in the job');
  END IF;
  SELECT * INTO o FROM public.sub_finder_order
   WHERE job_id = p_job_id AND key_id = p_key_id AND order_number = p_order_number FOR UPDATE;
  IF o.buy_id IS NOT NULL THEN
    RETURN jsonb_build_object('error', 'conflict', 'detail', 'a buy was already requested for this order',
                              'buy_id', o.buy_id);
  END IF;
  SELECT x INTO cv FROM jsonb_array_elements(o.covers) x
   WHERE x->>'market' = 'evo' AND x->>'listing_id' = p_listing_id LIMIT 1;
  IF cv IS NULL THEN
    RETURN jsonb_build_object('error', 'invalid',
                              'detail', 'that listing is not an EVO cover this job quoted for this order');
  END IF;
  -- The purchase is decided on OUR copy of the order, not on what the caller sent: it must be
  -- in the N2S book or the marketplace order book with this event, these seats, this quantity
  -- and this sale price.
  IF NOT public.sub_finder_order_verified(o, ARRAY['api', 'n2s', 'marketplace'], true) THEN
    RETURN jsonb_build_object('error', 'invalid',
      'detail', 'this order is not in our copy of the order books with these seats, quantity and sale price; '
                || 'alert us with the order number only');
  END IF;
  IF EXISTS (SELECT 1 FROM public.n2s_autobuy_exec x WHERE x.order_number = o.order_number) THEN
    RETURN jsonb_build_object('error', 'conflict', 'detail', 'the Need-to-Sub auto-buy already has this order');
  END IF;
  -- the sale must still be live (about 1.7 s; last, only for a buy that would otherwise go ahead)
  IF public.sub_finder_order_closed(o.order_number, o.site) IS NOT NULL THEN
    RETURN jsonb_build_object('error', 'conflict', 'detail', 'this sale is marked fulfilled, cancelled or rejected');
  END IF;
  BEGIN
    v_buy := public.manual_sub_buy_request(
      coalesce(o.site, 'CRM'), o.order_number, o.tevo_event_id, (cv->>'listing_id')::bigint,
      (cv->>'buy_qty')::int, (cv->>'price_ea')::numeric, o.sold_ea, o.event_name,
      'crm api key ' || coalesce(p_key_label, p_key_id::text)
        || coalesce(' / ' || nullif(btrim(p_requested_by), ''), ''),
      'sub finder job ' || p_job_id || ': sold ' || o.section || ' row ' || o.seat_row || ' x' || o.qty
        || '; sub ' || (cv->>'section') || ' row ' || (cv->>'row') || ' x' || (cv->>'buy_qty'));
  EXCEPTION WHEN unique_violation THEN
    RETURN jsonb_build_object('error', 'conflict', 'detail', 'a buy already exists for this sale');
  END;
  UPDATE public.sub_finder_order SET buy_id = v_buy, updated_at = now()
   WHERE job_id = o.job_id AND idx = o.idx;
  RETURN jsonb_build_object('buy_id', v_buy, 'state', 'requested', 'order_number', o.order_number,
                            'listing_id', cv->>'listing_id', 'qty', (cv->>'buy_qty')::int,
                            'max_price_ea', (cv->>'price_ea')::numeric);
END
$$;

CREATE OR REPLACE FUNCTION public.sub_finder_gt_offer_request(
  p_key_id bigint, p_key_label text, p_order_number text, p_listing_id text,
  p_market text DEFAULT NULL, p_requested_by text DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path = public, pg_temp
AS $$
DECLARE
  o      public.sub_finder_order;
  cv     jsonb;
  v_gate integer;
  v_id   bigint;
  v_back integer;
BEGIN
  IF NOT coalesce((public.sub_finder_access(p_key_id)->>'offer')::boolean, false) THEN
    RETURN jsonb_build_object('error', 'forbidden', 'detail', 'offering subs is not enabled for this key');
  END IF;
  SELECT * INTO o FROM public.sub_finder_order
   WHERE key_id = p_key_id AND order_number = p_order_number AND watching
   ORDER BY updated_at DESC LIMIT 1 FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('error', 'not_found', 'detail', 'no open lookup holds this order; alert us first');
  END IF;
  IF lower(regexp_replace(coalesce(o.site, ''), '[^A-Za-z]', '', 'g')) <> 'gotickets' OR p_order_number !~ '^\d{1,18}$' THEN
    RETURN jsonb_build_object('error', 'invalid', 'detail', 'only GoTickets orders can be offered a sub here');
  END IF;
  -- the offer is decided on OUR copy of the order, not on what the caller sent
  IF NOT public.sub_finder_order_verified(o, ARRAY['api', 'n2s', 'marketplace'], false) THEN
    RETURN jsonb_build_object('error', 'invalid',
      'detail', 'this order is not in our copy of the GoTickets order book with these seats; alert us with the order number only');
  END IF;
  SELECT x INTO cv FROM jsonb_array_elements(o.covers) WITH ORDINALITY t(x, n)
   WHERE x->>'listing_id' = p_listing_id AND x->>'source' = 'native'
     AND (p_market IS NULL OR x->>'market' = lower(btrim(p_market)))
   ORDER BY n LIMIT 1;
  IF cv IS NULL THEN
    RETURN jsonb_build_object('error', 'invalid', 'detail', 'that listing is not a cover this lookup quoted for this order');
  END IF;
  v_gate := (cv->>'gate')::int;
  IF v_gate IS NULL OR v_gate < 3 THEN
    RETURN jsonb_build_object('error', 'invalid',
      'detail', 'gate 1-2 covers need no offer: the seats are in the same section, same or better row');
  END IF;
  IF v_gate = 6 THEN
    RETURN jsonb_build_object('error', 'invalid', 'detail', 'gate 6 covers are results only and are not offered');
  END IF;
  IF v_gate = 5 AND coalesce((cv->>'profit')::numeric, 0) <= 0 THEN
    RETURN jsonb_build_object('error', 'invalid', 'detail', 'no rebate can be worked out for this cover');
  END IF;
  v_back := public.seat_row_rank(cv->>'row') - public.seat_row_rank(o.seat_row);
  BEGIN
    INSERT INTO public.sub_finder_gt_offer
      (job_id, idx, key_id, requested_by, order_number, gt_order_id, gate, market, listing_id, section, seat_row,
       qty, buy_qty, price_ea, order_total, sub_total, rebate_amount, notes)
    VALUES (o.job_id, o.idx, p_key_id,
            'crm api key ' || coalesce(p_key_label, p_key_id::text) || coalesce(' / ' || nullif(btrim(p_requested_by), ''), ''),
            o.order_number, o.order_number::bigint, v_gate, cv->>'market', cv->>'listing_id', cv->>'section', cv->>'row',
            o.qty, (cv->>'buy_qty')::int, (cv->>'price_ea')::numeric, round(o.sold_ea * o.qty, 2), (cv->>'total')::numeric,
            CASE WHEN v_gate = 5 THEN (cv->>'profit')::numeric END,       -- sale total - sub total
            CASE WHEN v_gate = 5
                 THEN 'Replacement seats in the same area, ' || v_back || ' row' || CASE WHEN v_back = 1 THEN '' ELSE 's' END
                      || ' further back than the original row ' || o.seat_row || ', with a rebate.'
                 ELSE 'Comparable replacement seats in the same area, in the same row or closer than the original section '
                      || o.section || ' row ' || o.seat_row || '.' END)
    RETURNING offer_id INTO v_id;
  EXCEPTION WHEN unique_violation THEN
    RETURN jsonb_build_object('error', 'conflict', 'detail', 'an offer already exists for this order');
  END;
  UPDATE public.sub_finder_order SET updated_at = now() WHERE job_id = o.job_id AND idx = o.idx;
  RETURN jsonb_build_object('offer_id', v_id, 'state', 'requested', 'gate', v_gate,
                            'section', cv->>'section', 'row', cv->>'row',
                            'rebate', CASE WHEN v_gate = 5 THEN (cv->>'profit')::numeric END);
END
$$;

CREATE OR REPLACE FUNCTION public.sub_finder_gt_offer_buy(p_offer_id bigint)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path = public, pg_temp
AS $$
DECLARE
  c       public.sub_finder_config;
  r       public.sub_finder_gt_offer;
  o       public.sub_finder_order;
  v_note  text;
  v_buy   bigint;
  v_spent numeric;
  v_label text;
BEGIN
  SELECT * INTO c FROM public.sub_finder_config;
  PERFORM pg_advisory_xact_lock(hashtext('sub_finder_autobuy'));      -- one cap check + request at a time
  SELECT * INTO r FROM public.sub_finder_gt_offer WHERE offer_id = p_offer_id FOR UPDATE;
  IF NOT FOUND OR r.gt_status IS DISTINCT FROM 'ACCEPTED' OR r.buy_id IS NOT NULL OR r.buy_note IS NOT NULL THEN
    RETURN NULL;                                                      -- not accepted, or already decided
  END IF;
  SELECT * INTO o FROM public.sub_finder_order WHERE job_id = r.job_id AND idx = r.idx FOR UPDATE;
  v_note := CASE
    -- every switch above this one must be on too: the API, GoTickets offers, and this buy
    WHEN NOT (c.enabled AND c.gt_offer_enabled AND c.gt_offer_auto_buy) THEN 'auto_buy_off'
    WHEN NOT o.watching
      OR public.sub_finder_order_closed(r.order_number, 'GoTickets') IS NOT NULL
      THEN 'order_closed'
    WHEN r.market <> 'evo' THEN 'not_on_evo'
    WHEN r.buy_qty <> r.qty THEN 'needs_spare_ticket'
    WHEN o.buy_id IS NOT NULL
      OR EXISTS (SELECT 1 FROM public.manual_sub_buy b WHERE b.sale_order_number = r.order_number
                    AND b.state IN ('requested', 'buying', 'bought', 'unknown'))
      OR EXISTS (SELECT 1 FROM public.n2s_autobuy_exec x WHERE x.order_number = r.order_number)
      THEN 'already_bought_for_this_sale'
  END;
  IF v_note IS NULL THEN
    SELECT coalesce(sum(coalesce(b.bought_total_usd, round(b.max_price_ea * b.qty, 2))), 0) INTO v_spent
      FROM public.manual_sub_buy b
     WHERE b.requested_by LIKE 'sub finder auto%' AND b.state IN ('requested', 'buying', 'bought', 'unknown')
       AND (b.created_at AT TIME ZONE 'America/New_York')::date = (now() AT TIME ZONE 'America/New_York')::date;
    IF v_spent + r.price_ea * r.buy_qty > c.auto_buy_daily_cap_usd THEN v_note := 'over_daily_cap'; END IF;
  END IF;
  IF v_note IS NULL THEN
    SELECT key_label INTO v_label FROM public.sub_finder_job WHERE job_id = r.job_id;
    BEGIN
      v_buy := public.manual_sub_buy_request(
        'GoTickets', r.order_number, o.tevo_event_id, r.listing_id::bigint, r.buy_qty, r.price_ea, o.sold_ea,
        o.event_name, 'sub finder auto (gotickets offer accepted, key ' || coalesce(v_label, r.key_id::text) || ')',
        'customer accepted GoTickets substitution ' || r.gt_request_id || ' (gate ' || r.gate || '): sub '
          || r.section || ' row ' || r.seat_row || ' x' || r.buy_qty
          || coalesce(', rebate ' || r.rebate_amount, ''));
    EXCEPTION WHEN unique_violation THEN
      v_note := 'already_bought_for_this_sale';
    END;
  END IF;
  UPDATE public.sub_finder_gt_offer SET buy_id = v_buy, buy_note = v_note, updated_at = now() WHERE offer_id = p_offer_id;
  UPDATE public.sub_finder_order
     SET buy_id = coalesce(v_buy, buy_id), action = CASE WHEN v_buy IS NOT NULL THEN 'auto_bought' ELSE action END,
         updated_at = now()
   WHERE job_id = r.job_id AND idx = r.idx;
  RETURN coalesce(v_note, 'buy_requested');
END
$$;

CREATE OR REPLACE FUNCTION public.sub_finder_offer_json(o public.sub_finder_order)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SET search_path = public, pg_temp
AS $$
  SELECT CASE
    WHEN lower(regexp_replace(coalesce(o.site, ''), '[^A-Za-z]', '', 'g')) <> 'gotickets' THEN NULL
    WHEN r.offer_id IS NULL AND coalesce((o.best->>'gate')::int, 0) < 3 THEN NULL
    ELSE jsonb_build_object(
      'via', 'gotickets',
      -- true: tell us yes with POST /orders/{n}/offer-sub and this listing_id
      'ask_crm', r.offer_id IS NULL AND o.watching AND o.order_source IN ('api', 'n2s', 'marketplace')
                 AND (o.best->>'gate')::int IN (3, 4, 5),
      'results_only', r.offer_id IS NULL AND (o.best->>'gate')::int = 6,
      'gate', coalesce(r.gate, (o.best->>'gate')::int),
      'market', coalesce(r.market, o.best->>'market'),
      'listing_id', coalesce(r.listing_id, o.best->>'listing_id'),
      'section', coalesce(r.section, o.best->>'section'), 'row', coalesce(r.seat_row, o.best->>'row'),
      'rebate', CASE WHEN r.offer_id IS NOT NULL THEN r.rebate_amount
                     WHEN (o.best->>'gate')::int = 5 THEN (o.best->>'profit')::numeric END,
      'request', CASE WHEN r.offer_id IS NOT NULL THEN jsonb_build_object(
                   'offer_id', r.offer_id, 'state', r.state, 'reasons', r.reasons,
                   'gotickets_request_id', r.gt_request_id, 'status', r.gt_status,
                   'denial_reason', r.denial_reason, 'status_checked_at', r.status_checked_at,
                   -- after ACCEPTED: 'buy_requested' (see the order's `buy`) or why we did not buy
                   'buy', CASE WHEN r.buy_id IS NOT NULL THEN 'buy_requested' ELSE r.buy_note END,
                   'final_at', r.final_at) END)
  END
  FROM (SELECT 1) one
  LEFT JOIN LATERAL (SELECT g.* FROM public.sub_finder_gt_offer g
                      WHERE g.order_number = o.order_number AND g.key_id = o.key_id
                      ORDER BY g.live DESC, g.offer_id DESC LIMIT 1) r ON true;
$$;

CREATE OR REPLACE FUNCTION public.sub_finder_refresh()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path = public, pg_temp
AS $$
DECLARE
  c        public.sub_finder_config;
  v_closed integer := 0;
  v_jobs   integer := 0;
  v_evs    bigint[];
  r        record;
BEGIN
  SELECT * INTO c FROM public.sub_finder_config;
  IF NOT c.enabled OR NOT c.refresh_enabled THEN RETURN jsonb_build_object('skipped', 'off'); END IF;
  IF NOT public.cron_try_lock('sub_finder_refresh') THEN RETURN jsonb_build_object('skipped', 'overlap'); END IF;

  -- 1. stop watching what is finished. Only these reasons end a watch (plus a newer lookup
  --    of the same order, in sub_finder_submit). The cheap ones run for every order every tick.
  UPDATE public.sub_finder_order o
     SET watching = false, closed_reason = x.reason, closed_at = now(), updated_at = now()
    FROM (
      SELECT w.job_id, w.idx, CASE
          WHEN w.event_date < (now() AT TIME ZONE 'America/New_York')::date THEN 'event_passed'
          -- it came from the CRM's N2S book and is no longer open there
          WHEN (w.order_source = 'n2s' OR w.in_n2s) AND NOT EXISTS (
                 SELECT 1 FROM public.n2s_items n
                 WHERE (n.order_number = w.order_number OR n.n2s_order_key = w.order_number)
                   AND NOT coalesce(n.is_terminal, false) AND n.status IN ('n2s', 'n2b'))
            THEN 'left_crm_n2s'
        END AS reason
      FROM public.sub_finder_order w WHERE w.watching) x
   WHERE o.job_id = x.job_id AND o.idx = x.idx AND x.reason IS NOT NULL;
  GET DIAGNOSTICS v_closed = ROW_COUNT;
  -- "The marketplace says the sale is over": the order's own marketplace feed first (GoTickets,
  -- TickPick, Vivid, SeatGeek, EVO — each read by its indexed order id), then our mirror of the
  -- CRM's books. Paced: up to feed_check_batch orders a tick, each at most every feed_check_every.
  FOR r IN SELECT w.job_id, w.idx, w.order_number, w.site FROM public.sub_finder_order w
            WHERE w.watching AND (w.feed_checked_at IS NULL OR w.feed_checked_at < now() - c.feed_check_every)
            ORDER BY w.feed_checked_at NULLS FIRST, w.updated_at LIMIT c.feed_check_batch
  LOOP
    UPDATE public.sub_finder_order o
       SET feed_checked_at = now(),
           watching      = (f.reason IS NULL),
           closed_reason = coalesce(f.reason, o.closed_reason),
           closed_at     = CASE WHEN f.reason IS NULL THEN o.closed_at ELSE now() END,
           updated_at    = CASE WHEN f.reason IS NULL THEN o.updated_at ELSE now() END
      FROM (SELECT 'order_' || public.sub_finder_order_closed(r.order_number, r.site) AS reason) f
     WHERE o.job_id = r.job_id AND o.idx = r.idx;
    IF NOT (SELECT watching FROM public.sub_finder_order WHERE job_id = r.job_id AND idx = r.idx) THEN
      v_closed := v_closed + 1;
    END IF;
  END LOOP;

  -- 2. the watched events, longest-unrefreshed first. Their listings come from the routine
  --    polling; a pull of our own is fired only if refresh_pull is switched on (the pull
  --    function then skips any market whose own last pull is newer than pull_refresh).
  SELECT array_agg(e) INTO v_evs FROM (
    SELECT o.tevo_event_id AS e
    FROM public.sub_finder_order o JOIN public.sub_finder_job j USING (job_id)
    WHERE o.watching AND j.status = 'done' AND o.tevo_event_id IS NOT NULL
    GROUP BY 1 ORDER BY min(coalesce(o.refreshed_at, j.done_at)) LIMIT c.refresh_max_events) q;
  IF v_evs IS NULL THEN
    RETURN jsonb_build_object('closed', v_closed, 'events', 0, 'jobs_rematched', 0);
  END IF;
  IF c.refresh_pull THEN
    PERFORM public.n2s_pull_events(v_evs, c.pull_refresh);
  END IF;

  -- 3. re-match the jobs with a watched order whose event has landed something newer
  FOR r IN
    SELECT DISTINCT o.job_id
    FROM public.sub_finder_order o JOIN public.sub_finder_job j USING (job_id)
    WHERE o.watching AND j.status = 'done' AND o.state IN ('cover', 'no_cover')
      AND o.tevo_event_id = ANY (v_evs)
      AND (EXISTS (SELECT 1 FROM public.n2s_evo_current x WHERE x.event_id = o.tevo_event_id
                     AND x.pulled_at > coalesce(o.refreshed_at, j.done_at))
        OR EXISTS (SELECT 1 FROM public.n2s_gt_current x WHERE x.tevo_event_id = o.tevo_event_id
                     AND x.pulled_at > coalesce(o.refreshed_at, j.done_at))
        OR EXISTS (SELECT 1 FROM public.n2s_sg_current x WHERE x.tevo_event_id = o.tevo_event_id
                     AND x.pulled_at > coalesce(o.refreshed_at, j.done_at)))
    LIMIT 200
  LOOP
    UPDATE public.sub_finder_order SET rematch = true
     WHERE job_id = r.job_id AND watching AND state IN ('cover', 'no_cover');
    PERFORM public.sub_finder_load_native(r.job_id, c.refresh_fresh);
    PERFORM public.sub_finder_match(r.job_id);
    v_jobs := v_jobs + 1;
  END LOOP;
  RETURN jsonb_build_object('closed', v_closed, 'events', cardinality(v_evs), 'jobs_rematched', v_jobs);
END
$$;

REVOKE ALL ON FUNCTION public.sub_finder_lookup(text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.sub_finder_lookup_best(text, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.sub_finder_order_verified(public.sub_finder_order, text[], boolean) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.sub_finder_order_closed(text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.sub_finder_lookup(text) TO service_role;
GRANT EXECUTE ON FUNCTION public.sub_finder_lookup_best(text, text) TO service_role;
GRANT EXECUTE ON FUNCTION public.sub_finder_order_verified(public.sub_finder_order, text[], boolean) TO service_role;
GRANT EXECUTE ON FUNCTION public.sub_finder_order_closed(text, text) TO service_role;
