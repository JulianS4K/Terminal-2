-- Migration 20261113010000 · level:secondary-sales · lane:D0 · writes:sub_finder_config,sub_finder_order,sub_finder_scratch,sub_finder_load_native,sub_finder_match,sub_finder_autobuy,sub_finder_order_json · reads:events,performer_zones(via n2s_zone_of),n2s_items,n2s_autobuy_exec,manual_sub_buy,n2s_evo_current,n2s_gt_current,n2s_sg_current · pre:20261112010000
--
-- SUB FINDER: N2S's gate labels on every cover, the widened rules when the strict one finds
-- nothing, and an automatic buy of the clean one-to-one case.
--
-- Operator 2026-11-13: "auto buy 1-1 automatically and profit when sub is on, if not send
-- results ... expand to other sub rules and give those results if no answer", then:
--   * "no [answer] means no buy in that same section same row or better"
--   * "never buy extra automatically, send result"
--   * who buys the rest: "they buy manually outside our pipeline"
--   * N2S orders: "these are separate orders so should always be excluded"
--   * "cap at 1000 a day on autobuy for now"
--
-- 1. GATES. Every cover now carries N2S's own gate number and label (docs/d7_n2s_pipeline.md
--    §4a), so the CRM reads the same words the N2S desk does:
--      1 Index                       same section, same or better row, profitable
--      2 S4KTrading                  same section, same or better row, up to 200% of the sale
--      3 Index offer subs            another section in the same curated zone, same or better row, profitable
--      4 offer subs s4ktrading       the same, up to 200%
--      5 Index Down offer subs       up to rows_back rows back in the same zone, profitable
--      6 Down offer subs S4KTrading  the same, up to 200%
--    with the suffixes ' zone unverified' (5/6 where neither seat has a curated zone),
--    ' obstructed view', ' single ticket' (a one-seat sale) and ' repost single' (one spare
--    ticket has to be bought). A same-section cover above 200% has no gate and is labelled
--    'over 200% of sale'; with no sale price the cost rule cannot be checked, so the even
--    gate is used and ' no sale price' is appended.
--
-- 2. WIDENING. Gates 3-6 are searched ONLY for an order with no gate 1 or 2 cover — "no buy in
--    that same section same row or better". They move the buyer, so they are offers: never
--    bought here. An order that has a gate 1/2 cover is shown only those.
--
-- 3. `action` on the order says what to do with the answer:
--      auto_bought   we bought the one-to-one EVO cover (see 4)
--      buy_manually  a same-section, same-or-better cover exists: the desk buys it themselves
--      offer         only widened covers exist: ask the buyer first, then buy manually
--      review        only an over-200% cover exists
--      none          nothing found (we keep looking while the order is watched)
--    `auto_buy_note` says why an order was not bought automatically.
--
-- 4. AUTO BUY (sub_finder_autobuy, off until sub_finder_config.auto_buy_enabled). While an
--    order is watched and has no buy, it buys ONE cover when ALL of these hold:
--      * EVO, from our own feed, gate 1 (same section, same or better row, profitable)
--      * exactly the quantity sold — a lot that needs a spare ticket is never bought, only shown
--      * no obstructed view
--      * profit is at least auto_buy_min_profit_pct of the cost (default 10%: EVO has added
--        5-9% on top of the listed price on some orders, which would turn a thin profit into
--        a loss; set it to 0 for "any profit")
--      * the order is not N2S's: it has no row in the N2S book (n2s_items, whatever its timer
--        or state) and no N2S auto-buy row — "always excluded"
--      * the order is in our own mirror of the marketplace order book (v_s4kcs_orders) and its
--        event, section, row, quantity and sale price there are the ones the cover was matched
--        on. What a caller sends can steer a search, never a purchase: an order we cannot
--        verify, or one sent with details that differ from our book, is results only
--      * today's automatic buys plus this one stay within auto_buy_daily_cap_usd ($1,000)
--    The cap check and the request are serialized by an advisory lock, so two jobs settling
--    at once cannot both spend the last of the day's cap.
--    It adds NO write path: it files a manual_sub_buy request, exactly as an operator buy
--    does, so that path's own switch, kill switch, per-order ceiling, one-live-request-per-sale
--    rule and fresh re-read of the listing (gone / dearer than quoted = no buy) all still apply.
--    Everything else is results only.
--
-- rollback: DROP FUNCTION public.sub_finder_autobuy(uuid); re-apply sub_finder_scratch,
--           sub_finder_load_native, sub_finder_match and sub_finder_order_json from
--           20261112010000; ALTER TABLE public.sub_finder_order DROP COLUMN action, DROP COLUMN auto_buy_note;
--           ALTER TABLE public.sub_finder_config DROP COLUMN auto_buy_enabled, DROP COLUMN auto_buy_daily_cap_usd,
--             DROP COLUMN auto_buy_min_profit_pct;

ALTER TABLE public.sub_finder_config
  ADD COLUMN IF NOT EXISTS auto_buy_enabled        boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS auto_buy_daily_cap_usd  numeric NOT NULL DEFAULT 1000,
  ADD COLUMN IF NOT EXISTS auto_buy_min_profit_pct numeric NOT NULL DEFAULT 10;
ALTER TABLE public.sub_finder_order
  ADD COLUMN IF NOT EXISTS action        text NOT NULL DEFAULT 'none',
  ADD COLUMN IF NOT EXISTS auto_buy_note text;

-- The scratch table gains the listing's view, where the market discloses one.
CREATE OR REPLACE FUNCTION public.sub_finder_scratch()
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path = public, pg_temp
AS $$
BEGIN
  IF to_regclass('pg_temp._sf_l') IS NOT NULL THEN DROP TABLE _sf_l; END IF;
  CREATE TEMP TABLE _sf_l (
    market text, via text, eid bigint, lid text, section text, seat_row text, quantity integer,
    px numeric, sp integer[], pulled_at timestamptz, link text, price_note text,
    view_note text) ON COMMIT DROP;
END
$$;

CREATE OR REPLACE FUNCTION public.sub_finder_load_native(p_job_id uuid, p_max_age interval DEFAULT NULL)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path = public, pg_temp
AS $$
DECLARE
  v_since timestamptz := CASE WHEN p_max_age IS NULL THEN '-infinity'::timestamptz ELSE now() - p_max_age END;
  v_n     integer;
BEGIN
  PERFORM public.sub_finder_scratch();
  INSERT INTO _sf_l
  SELECT 'evo', 'native', x.event_id, x.tevo_ticket_group_id::text, x.section, x.row, x.quantity,
         x.retail_price, x.splits::int[], x.pulled_at,
         'https://core.ticketevolution.com/buy/event/' || x.event_id || '/tickets/' || x.tevo_ticket_group_id, NULL,
         CASE WHEN x.view_type ~* '(obstruct|limited|partial|restricted)'
                OR x.public_notes ~* '(obstruct|limited view|partial view|restricted view)' THEN 'obstructed' END
  FROM public.n2s_evo_current x
  WHERE x.event_id IN (SELECT tevo_event_id FROM public.sub_finder_order WHERE job_id = p_job_id)
    AND x.pulled_at >= v_since
    AND NOT coalesce(x.is_owned, false) AND NOT coalesce(x.is_ancillary, false)
  UNION ALL
  SELECT 'gotickets', 'native', x.tevo_event_id, x.gt_listing_id::text, x.section, x.row, x.quantity,
         x.all_in_price, x.splits::int[], x.pulled_at,
         'https://pro.gotickets.com/tickets/' || x.gt_event_id || '/?sortBy=price&sortDirection=asc', NULL,
         CASE WHEN x.notes ~* '(obstruct|limited view|partial view|restricted view)' THEN 'obstructed' END
  FROM public.n2s_gt_current x
  WHERE x.tevo_event_id IN (SELECT tevo_event_id FROM public.sub_finder_order WHERE job_id = p_job_id)
    AND x.pulled_at >= v_since
  UNION ALL
  -- SeatGeek link: the stored event URL plus the listing's display id — both or neither
  -- (see mig 20260910310000: half a link is worse than none).
  SELECT 'seatgeek', 'native', x.tevo_event_id, x.sglid::text, x.section, x.row, x.quantity,
         x.retail_price_all_in,
         ARRAY(SELECT jsonb_array_elements_text(CASE WHEN jsonb_typeof(x.splits) = 'array' THEN x.splits
                                                     ELSE '[]'::jsonb END)::int),
         x.pulled_at,
         CASE WHEN sg.sg_url IS NOT NULL AND x.display_id IS NOT NULL
              THEN sg.sg_url || '#listing=' || x.display_id END, NULL,
         CASE WHEN coalesce(x.has_limited_view, false) THEN 'obstructed' END
  FROM public.n2s_sg_current x
  LEFT JOIN public.sg_events_canonical sg ON sg.sg_event_id = x.sg_event_id
  WHERE x.tevo_event_id IN (SELECT tevo_event_id FROM public.sub_finder_order WHERE job_id = p_job_id)
    AND x.pulled_at >= v_since
    AND NOT coalesce(x.is_broker_owned, false);
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n;
END
$$;

-- Rank the listings in the caller's temp table _sf_l against a job's orders, label each
-- cover with its N2S gate, store them, then let sub_finder_autobuy act. Which orders, and the
-- carry-over rule for a rematch, are as before (20261112010000). See the header for the gates.
CREATE OR REPLACE FUNCTION public.sub_finder_match(p_job_id uuid, p_td_answered boolean DEFAULT false)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path = public, pg_temp
AS $$
DECLARE
  v_back integer := (SELECT rows_back FROM public.sub_finder_config);
  v_n    integer;
BEGIN
  WITH o AS (
    SELECT so.*, e.primary_performer_id AS perf, e.venue_id AS ven
    FROM public.sub_finder_order so
    LEFT JOIN public.events e ON e.id = so.tevo_event_id
    WHERE so.job_id = p_job_id
      AND ((so.state = 'pending' AND (NOT p_td_answered OR so.td_state IN ('searched', 'failed')))
           OR (so.rematch AND so.state IN ('cover', 'no_cover')))
  ), same_sec AS (
    -- the order's own section: same or better row, or up to rows_back behind
    SELECT o.job_id, o.idx, o.qty, o.sold_ea, o.perf, o.ven, o.section AS o_section, o.seat_row AS o_row,
           l.*, false AS moved,
           CASE WHEN o.qty = ANY (l.sp) OR l.quantity = o.qty THEN o.qty
                WHEN l.quantity = o.qty + 1 THEN o.qty + 1 END AS buy_qty,
           public.seat_row_rank(l.seat_row) - public.seat_row_rank(o.seat_row) AS row_delta
    FROM o JOIN _sf_l l ON l.eid = o.tevo_event_id
     AND public.seat_section_norm(l.section) = public.seat_section_norm(o.section)
     AND public.seat_row_kind(l.seat_row) = public.seat_row_kind(o.seat_row)
     AND public.seat_row_rank(l.seat_row) <= public.seat_row_rank(o.seat_row) + v_back
    WHERE l.px > 0 AND l.quantity > 0
  ), strict_ok AS (
    -- orders that HAVE "a buy in that same section, same row or better" (gate 1 or 2)
    SELECT DISTINCT s.job_id, s.idx FROM same_sec s
    WHERE s.buy_qty IS NOT NULL AND s.row_delta <= 0
      AND (s.sold_ea IS NULL OR s.buy_qty * s.px <= 2 * s.sold_ea * s.qty)
  ), need AS (
    -- the rest: only these are widened to the zone rules
    SELECT o.* FROM o WHERE NOT EXISTS (SELECT 1 FROM strict_ok k WHERE k.job_id = o.job_id AND k.idx = o.idx)
  ), oz AS (
    SELECT n.job_id, n.idx, public.n2s_zone_of(n.perf, n.ven, n.section, n.seat_row) AS z FROM need n
  ), lz AS (
    -- the zone of each distinct listing seat, for the events of the orders being widened
    SELECT d.eid, d.section, d.seat_row, public.n2s_zone_of(e.primary_performer_id, e.venue_id, d.section, d.seat_row) AS z
    FROM (SELECT DISTINCT l.eid, l.section, l.seat_row FROM _sf_l l
          WHERE l.eid IN (SELECT tevo_event_id FROM need)) d
    JOIN public.events e ON e.id = d.eid
  ), zone_sec AS (
    -- another section in the SAME curated zone
    SELECT n.job_id, n.idx, n.qty, n.sold_ea, n.perf, n.ven, n.section AS o_section, n.seat_row AS o_row,
           l.*, true AS moved,
           CASE WHEN n.qty = ANY (l.sp) OR l.quantity = n.qty THEN n.qty
                WHEN l.quantity = n.qty + 1 THEN n.qty + 1 END AS buy_qty,
           public.seat_row_rank(l.seat_row) - public.seat_row_rank(n.seat_row) AS row_delta
    FROM need n
    JOIN oz ON oz.job_id = n.job_id AND oz.idx = n.idx AND oz.z IS NOT NULL
    JOIN lz ON lz.eid = n.tevo_event_id AND lz.z = oz.z
    JOIN _sf_l l ON l.eid = lz.eid AND l.section = lz.section AND l.seat_row = lz.seat_row
     AND public.seat_section_norm(l.section) <> public.seat_section_norm(n.section)
     AND public.seat_row_kind(l.seat_row) = public.seat_row_kind(n.seat_row)
     AND public.seat_row_rank(l.seat_row) <= public.seat_row_rank(n.seat_row) + v_back
    WHERE l.px > 0 AND l.quantity > 0
  ), cand AS (
    SELECT * FROM same_sec UNION ALL SELECT * FROM zone_sec
  ), priced AS (
    SELECT c.*, c.buy_qty * c.px AS total,
           CASE WHEN c.sold_ea IS NOT NULL THEN round(c.sold_ea * c.qty - c.buy_qty * c.px, 2) END AS profit,
           (c.sold_ea IS NOT NULL AND c.sold_ea * c.qty - c.buy_qty * c.px > 0) AS profitable,
           (c.sold_ea IS NULL OR c.buy_qty * c.px <= 2 * c.sold_ea * c.qty) AS within_200,
           EXISTS (SELECT 1 FROM strict_ok k WHERE k.job_id = c.job_id AND k.idx = c.idx) AS has_strict,
           (SELECT oz.z FROM oz WHERE oz.job_id = c.job_id AND oz.idx = c.idx) AS o_zone,
           (SELECT lz.z FROM lz WHERE lz.eid = c.eid AND lz.section = c.section AND lz.seat_row = c.seat_row) AS l_zone
    FROM cand c WHERE c.buy_qty IS NOT NULL
  ), gated AS (
    SELECT p.*,
           CASE
             WHEN NOT p.within_200 THEN NULL
             WHEN NOT p.moved AND p.row_delta <= 0 THEN CASE WHEN p.profitable THEN 1 ELSE 2 END
             WHEN p.has_strict THEN NULL                      -- not widened: gates 3-6 do not apply
             WHEN p.moved AND p.row_delta <= 0 THEN CASE WHEN p.profitable THEN 3 ELSE 4 END
             -- rows back: the same zone, or no zone on either side (then it is flagged)
             WHEN p.row_delta > 0 AND (p.moved OR p.o_zone IS NOT DISTINCT FROM p.l_zone)
               THEN CASE WHEN p.profitable THEN 5 ELSE 6 END
           END AS gate
    FROM priced p
  ), kept_rows AS (
    -- what is shown: any gated cover, plus a same-section same-or-better cover above 200%
    SELECT g.* FROM gated g
    WHERE g.gate IS NOT NULL OR (NOT g.moved AND g.row_delta <= 0)
  ), ranked AS (
    SELECT k.*, row_number() OVER (PARTITION BY k.job_id, k.idx, k.market
                                   ORDER BY k.gate NULLS LAST, k.total, k.lid) AS rn
    FROM kept_rows k
  ), fresh AS (
    SELECT job_id, idx, jsonb_build_object(
             'market', market, 'source', via, 'listing_id', lid, 'section', section, 'row', seat_row,
             'listing_qty', quantity, 'buy_qty', buy_qty, 'spare', buy_qty - qty,
             'price_ea', px, 'total', round(total, 2), 'profit', profit, 'price_note', price_note,
             'row_relation', CASE WHEN row_delta < 0 THEN 'better' WHEN row_delta = 0 THEN 'same' ELSE 'back' END,
             'gate', gate,
             'label', CASE gate WHEN 1 THEN 'Index' WHEN 2 THEN 'S4KTrading' WHEN 3 THEN 'Index offer subs'
                                WHEN 4 THEN 'offer subs s4ktrading' WHEN 5 THEN 'Index Down offer subs'
                                WHEN 6 THEN 'Down offer subs S4KTrading' ELSE 'over 200% of sale' END
                      || CASE WHEN gate IN (5, 6) AND o_zone IS NULL AND l_zone IS NULL THEN ' zone unverified' ELSE '' END
                      || CASE WHEN view_note = 'obstructed' THEN ' obstructed view' ELSE '' END
                      || CASE WHEN qty = 1 THEN ' single ticket' ELSE '' END
                      || CASE WHEN buy_qty > qty THEN ' repost single' ELSE '' END
                      || CASE WHEN sold_ea IS NULL AND gate IS NOT NULL THEN ' no sale price' ELSE '' END,
             'needs_buyer_ok', coalesce(gate >= 3, false),
             'zone', l_zone, 'view', view_note,
             'link', link, 'buyable', market = 'evo', 'listing_seen_at', pulled_at) AS cover
    FROM ranked WHERE rn <= 3
  ), kept AS (
    -- rematch only: what a market found before, when that market has nothing in _sf_l now
    SELECT o.job_id, o.idx, x AS cover
    FROM o, jsonb_array_elements(o.covers) x
    WHERE o.rematch AND o.state IN ('cover', 'no_cover')
      AND NOT EXISTS (SELECT 1 FROM _sf_l l WHERE l.eid = o.tevo_event_id AND l.market = x->>'market')
  ), per_order AS (
    SELECT job_id, idx,
           jsonb_agg(cover ORDER BY (cover->>'gate')::int NULLS LAST, (cover->>'total')::numeric,
                                    cover->>'listing_id') AS covers
    FROM (SELECT * FROM fresh UNION ALL SELECT * FROM kept) u GROUP BY job_id, idx
  )
  UPDATE public.sub_finder_order t
     SET covers = coalesce(p.covers, '[]'::jsonb),
         best   = p.covers -> 0,                    -- lowest gate first, then cheapest
         state  = CASE WHEN p.covers IS NULL THEN 'no_cover' ELSE 'cover' END,
         action = CASE
                    WHEN t.buy_id IS NOT NULL THEN t.action
                    WHEN p.covers IS NULL THEN 'none'
                    WHEN (p.covers -> 0 ->> 'gate')::int IN (1, 2) THEN 'buy_manually'
                    WHEN (p.covers -> 0 ->> 'gate')::int >= 3 THEN 'offer'
                    ELSE 'review' END,
         updated_at = CASE WHEN o.state = 'pending'
                             OR public.sub_finder_covers_key(p.covers) IS DISTINCT FROM public.sub_finder_covers_key(o.covers)
                           THEN now() ELSE t.updated_at END,
         refreshed_at  = CASE WHEN o.state = 'pending' THEN t.refreshed_at ELSE now() END,
         refresh_count = t.refresh_count + CASE WHEN o.state = 'pending' THEN 0 ELSE 1 END,
         rematch = false
    FROM o LEFT JOIN per_order p ON p.job_id = o.job_id AND p.idx = o.idx
   WHERE t.job_id = o.job_id AND t.idx = o.idx;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  PERFORM public.sub_finder_autobuy(p_job_id);
  RETURN v_n;
END
$$;

-- Buy the clean one-to-one EVO cover of each watched order of a job that has none yet, when
-- every condition in the header holds. Records why not in auto_buy_note. Returns buys filed.
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
  bk      record;
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
    -- the cheapest EVO one-to-one: gate 1, our own feed, exact quantity, clear view, enough profit
    SELECT x INTO cv FROM jsonb_array_elements(o.covers) WITH ORDINALITY t(x, n)
     WHERE x->>'market' = 'evo' AND x->>'source' = 'native' AND (x->>'gate')::int = 1
       AND (x->>'spare')::int = 0 AND x->>'view' IS DISTINCT FROM 'obstructed'
       AND (x->>'profit')::numeric >= (x->>'total')::numeric * c.auto_buy_min_profit_pct / 100.0
     ORDER BY n LIMIT 1;
    v_note := CASE
      WHEN NOT c.auto_buy_enabled THEN 'auto_buy_off'
      WHEN cv IS NOT NULL THEN NULL
      WHEN NOT EXISTS (SELECT 1 FROM jsonb_array_elements(o.covers) x
                       WHERE x->>'market' = 'evo' AND x->>'source' = 'native' AND (x->>'gate')::int = 1)
        THEN 'no_evo_one_to_one'
      WHEN NOT EXISTS (SELECT 1 FROM jsonb_array_elements(o.covers) x
                       WHERE x->>'market' = 'evo' AND (x->>'gate')::int = 1 AND (x->>'spare')::int = 0)
        THEN 'needs_spare_ticket'
      WHEN NOT EXISTS (SELECT 1 FROM jsonb_array_elements(o.covers) x
                       WHERE x->>'market' = 'evo' AND (x->>'gate')::int = 1 AND (x->>'spare')::int = 0
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
      SELECT v.tevo_event_id, v.section, v.row, v.quantity, v.price_per_ticket INTO bk
        FROM public.v_s4kcs_orders v WHERE v.s4k_order_id = o.order_number
       ORDER BY v.pulled_at DESC NULLS LAST LIMIT 1;
      IF NOT FOUND THEN
        v_note := 'not_in_our_books';
      ELSIF bk.tevo_event_id IS DISTINCT FROM o.tevo_event_id
         OR public.seat_section_norm(bk.section) IS DISTINCT FROM public.seat_section_norm(o.section)
         OR upper(btrim(bk.row)) IS DISTINCT FROM upper(btrim(o.seat_row))
         OR bk.quantity IS DISTINCT FROM o.qty
         OR bk.price_per_ticket IS NULL OR o.sold_ea IS NULL
         OR abs(bk.price_per_ticket - o.sold_ea) > 0.01 THEN
        v_note := 'differs_from_our_books';
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
          'auto: gate 1 Index, sold ' || o.section || ' row ' || o.seat_row || ' x' || o.qty
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

CREATE OR REPLACE FUNCTION public.sub_finder_order_json(o public.sub_finder_order)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SET search_path = public, pg_temp
AS $$
  SELECT jsonb_build_object(
    'job_id', o.job_id, 'order_number', o.order_number, 'site', o.site,
    'tevo_event_id', o.tevo_event_id, 'event_name', o.event_name, 'event_date', o.event_date, 'venue', o.venue,
    'section', o.section, 'row', o.seat_row, 'qty', o.qty, 'sold_ea', o.sold_ea,
    'order_source', o.order_source, 'state', o.state,
    -- what to do with the answer, and why it was not bought automatically
    'action', o.action, 'auto_buy_note', o.auto_buy_note,
    'best', o.best, 'covers', o.covers,
    'markets_searched', CASE WHEN o.state IN ('cover', 'no_cover')
                             THEN to_jsonb(ARRAY['evo', 'gotickets', 'seatgeek']
                                           || CASE WHEN o.td_state = 'searched' THEN ARRAY['ticketsdata']
                                                   ELSE ARRAY[]::text[] END) END,
    'ticketsdata', o.td_state,
    'watching', o.watching, 'refreshed_at', o.refreshed_at, 'closed_reason', o.closed_reason,
    'buy', (SELECT jsonb_build_object(
                     'buy_id', b.buy_id, 'request_state', b.state, 'reasons', b.reasons,
                     'evo_order_id', b.buy_order_id, 'outcome', b.outcome,
                     'seller_state', b.seller_state, 'order_state', b.order_state,
                     'rejection_reason', b.rejection_reason,
                     'qty', b.qty, 'price_ea', b.bought_price_ea,
                     'total', coalesce(b.order_total_usd, b.bought_total_usd),
                     'section', b.bought_section, 'row', b.bought_row, 'seats', b.seats,
                     'status_checked_at', b.status_checked_at, 'final_at', b.final_at)
            FROM public.manual_sub_buy b WHERE b.buy_id = o.buy_id),
    'updated_at', to_char(o.updated_at AT TIME ZONE 'utc', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'));
$$;

REVOKE ALL ON FUNCTION public.sub_finder_autobuy(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.sub_finder_autobuy(uuid) TO service_role;
