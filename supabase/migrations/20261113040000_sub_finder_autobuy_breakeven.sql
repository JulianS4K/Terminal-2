-- Migration 20261113040000 · level:secondary-sales · lane:D0 · writes:sub_finder_config,sub_finder_autobuy_gate,sub_finder_autobuy · reads:sub_finder_order,n2s_items,n2s_autobuy_exec,v_s4kcs_orders,v_sub_orders,manual_sub_buy · pre:20261113010000
--
-- SUB FINDER auto-buy: buy at breakeven or profit.
--
-- Operator 2026-11-13: "Remove 10% gate auto buy at breakeven or profit".
--   * auto_buy_min_profit_pct now defaults to 0 (prod was set to 0 the same day).
--   * A cover that costs EXACTLY the sale is gate 2 by N2S's rule (gate 1 needs a profit), so
--     it was never bought. The automatic buy now takes a same-section, same-or-better cover at
--     gate 1, or at gate 2 when its profit is exactly 0. A loss of any size is still never
--     bought automatically. Every other condition of 20261113010000 is unchanged.
-- Note: EVO has charged above the listed price on some orders, so a breakeven buy can settle
-- as a small loss. Raise auto_buy_min_profit_pct to put a margin back.
--
-- rollback: re-apply sub_finder_autobuy from 20261113010000; DROP FUNCTION public.sub_finder_autobuy_gate(jsonb);
--           ALTER TABLE public.sub_finder_config ALTER COLUMN auto_buy_min_profit_pct SET DEFAULT 10;

ALTER TABLE public.sub_finder_config ALTER COLUMN auto_buy_min_profit_pct SET DEFAULT 0;
UPDATE public.sub_finder_config SET auto_buy_min_profit_pct = 0 WHERE id;

-- Is this cover one the automatic buy may take, by gate? Gate 1, or gate 2 at exactly breakeven.
CREATE OR REPLACE FUNCTION public.sub_finder_autobuy_gate(x jsonb)
 RETURNS boolean
 LANGUAGE sql
 IMMUTABLE
 SET search_path = public, pg_temp
AS $$
  SELECT coalesce((x->>'gate')::int = 1 OR ((x->>'gate')::int = 2 AND (x->>'profit')::numeric = 0), false);
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
      SELECT v.source, v.tevo_event_id, v.section, v.row, v.quantity, v.price_per_ticket INTO bk
        FROM public.v_s4kcs_orders v WHERE v.s4k_order_id = o.order_number
       ORDER BY v.pulled_at DESC NULLS LAST LIMIT 1;
      IF NOT FOUND OR (SELECT count(DISTINCT lower(v.source)) FROM public.v_s4kcs_orders v
                        WHERE v.s4k_order_id = o.order_number) > 1 THEN
        v_note := 'not_in_our_books';                  -- unknown, or the number is on two marketplaces
      ELSIF lower(btrim(bk.source)) IS DISTINCT FROM lower(btrim(o.site))
         OR bk.tevo_event_id IS DISTINCT FROM o.tevo_event_id
         OR public.seat_section_norm(bk.section) IS DISTINCT FROM public.seat_section_norm(o.section)
         OR upper(btrim(bk.row)) IS DISTINCT FROM upper(btrim(o.seat_row))
         OR bk.quantity IS DISTINCT FROM o.qty
         OR bk.price_per_ticket IS NULL OR o.sold_ea IS NULL
         OR abs(bk.price_per_ticket - o.sold_ea) > 0.01 THEN
        v_note := 'differs_from_our_books';
      -- the sale must still be live: any of our order feeds marking it finished stops the buy.
      -- (About 1.7 s per lookup, so it runs last, only for an order that would otherwise be bought.)
      ELSIF EXISTS (SELECT 1 FROM public.v_sub_orders v
                     WHERE v.order_id = o.order_number AND NOT v.is_open) THEN
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

REVOKE ALL ON FUNCTION public.sub_finder_autobuy_gate(jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.sub_finder_autobuy_gate(jsonb) TO service_role;
