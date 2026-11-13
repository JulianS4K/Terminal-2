-- Migration 20261113080000 · level:secondary-sales · lane:D0 · writes:sub_finder_config,sub_finder_autobuy_gate,sub_finder_autobuy,sub_finder_order_json · reads:sub_finder_order,manual_sub_buy · pre:20261113070000
--
-- SUB FINDER auto-buy: a gate 2 cover may be bought at a loss of 5% or less; and a buy that tax
-- turned unprofitable is flagged gate 2.
--
-- Operator 2026-11-13: "if we buy something and tax makes it unprofitable flag as gate 2, also
-- allow for gate [2] to auto buy when loss is 5% or less".
--
--   * BEFORE the buy this already holds since 20261113070000: an EVO cover's `total` includes
--     the venue's expected tax, so a cover the tax makes unprofitable is gate 2, not gate 1.
--   * AFTER the buy: the order's `buy` now carries `profit_actual` (sale total - what EVO really
--     charged, tax included) and `gate_actual` / `label_actual`: 1 Index when that is a profit,
--     2 S4KTrading when the tax (or anything else) turned it into breakeven or a loss.
--   * AUTO BUY: besides gate 1, a gate 2 cover (same section, same or better row) is bought when
--     its loss, after expected tax, is at most auto_buy_max_loss_pct (5) percent of the sale
--     total. Breakeven is a 0% loss, so it stays covered. A bigger loss is never bought
--     automatically. Every other condition is unchanged (EVO, our own feed, exact quantity,
--     clear view, our own records of the order, live sale, never an N2S-book order, $1,000/day).
--     Covers are ordered gate first, so a profitable cover is always taken before a losing one.
--
-- rollback: re-apply sub_finder_autobuy from 20261113060000, sub_finder_autobuy_gate from 20261113040000 and
--           sub_finder_order_json from 20261113020000; ALTER TABLE public.sub_finder_config DROP COLUMN auto_buy_max_loss_pct;

ALTER TABLE public.sub_finder_config
  ADD COLUMN IF NOT EXISTS auto_buy_max_loss_pct numeric NOT NULL DEFAULT 5
    CHECK (auto_buy_max_loss_pct >= 0 AND auto_buy_max_loss_pct <= 25);

-- Is this cover one the automatic buy may take, by gate? Gate 1; or gate 2 when its loss is at
-- most auto_buy_max_loss_pct of the sale total (sale total = total + profit). No sale price = no.
CREATE OR REPLACE FUNCTION public.sub_finder_autobuy_gate(x jsonb)
 RETURNS boolean
 LANGUAGE sql
 STABLE
 SECURITY DEFINER
 SET search_path = public, pg_temp
AS $$
  SELECT coalesce(
    (x->>'gate')::int = 1
    OR ((x->>'gate')::int = 2
        AND (x->>'profit')::numeric <= 0
        AND (x->>'total')::numeric + (x->>'profit')::numeric > 0
        AND -(x->>'profit')::numeric
            <= ((x->>'total')::numeric + (x->>'profit')::numeric)
               * (SELECT c.auto_buy_max_loss_pct FROM public.sub_finder_config c) / 100.0),
    false);
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
    -- the best EVO one-to-one this may take: a profit, breakeven, or a gate 2 loss inside the limit;
    -- our own feed, exact quantity, clear view. Covers are ordered gate first, then cheapest.
    SELECT x INTO cv FROM jsonb_array_elements(o.covers) WITH ORDINALITY t(x, n)
     WHERE x->>'market' = 'evo' AND x->>'source' = 'native' AND public.sub_finder_autobuy_gate(x)
       AND (x->>'spare')::int = 0 AND x->>'view' IS DISTINCT FROM 'obstructed'
       AND ((x->>'gate')::int = 2      -- a gate 2 cover is already inside the loss limit (sub_finder_autobuy_gate)
            OR (x->>'profit')::numeric >= (x->>'total')::numeric * c.auto_buy_min_profit_pct / 100.0)
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
    -- GoTickets orders only: the sub we would offer the customer, and how that offer stands
    'sub_offer', public.sub_finder_offer_json(o),
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
                     -- what the buy really made or lost once EVO's charge (tax included) is known, and
                     -- the gate that makes it: 1 Index = a profit, 2 S4KTrading = tax or price turned it into a loss
                     'profit_actual', round(o.sold_ea * o.qty - b.order_total_usd, 2),
                     'gate_actual', CASE WHEN b.order_total_usd IS NULL OR o.sold_ea IS NULL THEN NULL
                                         WHEN o.sold_ea * o.qty - b.order_total_usd > 0 THEN 1 ELSE 2 END,
                     'label_actual', CASE WHEN b.order_total_usd IS NULL OR o.sold_ea IS NULL THEN NULL
                                          WHEN o.sold_ea * o.qty - b.order_total_usd > 0 THEN 'Index' ELSE 'S4KTrading' END,
                     'section', b.bought_section, 'row', b.bought_row, 'seats', b.seats,
                     'status_checked_at', b.status_checked_at, 'final_at', b.final_at)
            FROM public.manual_sub_buy b WHERE b.buy_id = o.buy_id),
    'updated_at', to_char(o.updated_at AT TIME ZONE 'utc', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'));
$$;
