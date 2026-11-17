-- Migration 20261113320000 · level:secondary-sales · lane:D0 · writes:sub_finder_loss_limit,sub_finder_loss_limit_log,sub_finder_config,sub_finder_order_is_need2buy,sub_finder_max_loss_pct,sub_finder_autobuy_gate,sub_finder_loss_limits,sub_finder_loss_limits_set,sub_finder_autobuy,manual_sub_buy_total_ceiling,sub_finder_order_json · reads:n2s_items,sub_finder_order · pre:20261113310000
--
-- SUB FINDER: the automatic buy's loss limit, by marketplace, set by the CRM, for need2buy orders.
--
-- Operator 2026-11-13: "for index we allow 5% loss by default when autobuying but allow crm to
-- set loss conditions based on each marketplace for autobuy and automatically move losses to
-- gate 2 in category after" · "as a percent of sale total up to 200%" · "but thats only for
-- need2buy labeled orders, n2s original from automatiq is strictly profit only".
--
-- Until now one number (sub_finder_config.auto_buy_max_loss_pct, 5) let ANY order the sub finder
-- buys for be bought at a loss of up to 5% of the sale.
--
-- Now:
--   * a NEED2BUY order (labelled need2buy in the CRM's N2S feed) may be bought at a cost of up to
--     a limit, as a percent of the sale total: 105 (a 5% loss) unless the CRM has set one for
--     the marketplace the order sold on. Allowed range 100 (no loss) to 200 (gate 2's own bound).
--   * EVERY OTHER order is bought automatically at a profit only (gate 1). Orders in the N2S
--     book that are not labelled need2buy are, as before, not bought here at all.
--   * the CRM reads the limits and, with a key in sub_finder_config.loss_limit_key_ids, sets them:
--     sub_finder_loss_limits / sub_finder_loss_limits_set (GET / PUT /api/v1/subs/settings/auto-buy-loss).
--     Every change is kept in sub_finder_loss_limit_log.
--   * the tax-included ceiling the buy worker enforces (manual_sub_buy_total_ceiling) follows
--     the same limit; for a profit-only order it is one cent under the sale total.
--   * the order object shows `auto_buy_max_cost_pct`: the limit that applies to that order.
-- A buy that ends at a loss is already put in the gate 2 category afterwards: the order's
-- `buy.gate_actual` / `label_actual` read 2 / `S4KTrading` once the real charge is known
-- (mig 20261113080000). Nothing changes there.
--
-- Spend ceilings are untouched: per order, per day, and the automatic buy's own daily cap.
-- Functions are shipped as full definitions (MIGRATION_CONVENTIONS 6a).
--
-- rollback: UPDATE public.sub_finder_loss_limit SET max_cost_pct = NULL;  (back to 105 everywhere)
--           re-apply sub_finder_autobuy, manual_sub_buy_total_ceiling and sub_finder_order_json
--           from 20261113310000's result to restore the one global limit for every order.

CREATE TABLE IF NOT EXISTS public.sub_finder_loss_limit (
  site         text PRIMARY KEY,                  -- sub_finder_site_norm() of the marketplace, or '*' = every other one
  max_cost_pct numeric CHECK (max_cost_pct IS NULL OR (max_cost_pct >= 100 AND max_cost_pct <= 200)),  -- NULL = not set
  set_by       text,
  set_at       timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS public.sub_finder_loss_limit_log (
  id       bigserial PRIMARY KEY,
  at       timestamptz NOT NULL DEFAULT now(),
  key_id   bigint,
  set_by   text,
  site     text NOT NULL,
  old_pct  numeric,
  new_pct  numeric
);
ALTER TABLE public.sub_finder_loss_limit     ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sub_finder_loss_limit_log ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.sub_finder_loss_limit, public.sub_finder_loss_limit_log FROM PUBLIC, anon, authenticated;

ALTER TABLE public.sub_finder_config
  ADD COLUMN IF NOT EXISTS loss_limit_key_ids bigint[] NOT NULL DEFAULT '{}';

-- Is this order labelled need2buy in the CRM's N2S feed right now? (Our own Gmail PED rows are
-- report-only and never count.)
CREATE OR REPLACE FUNCTION public.sub_finder_order_is_need2buy(p_order_number text)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT EXISTS (
    SELECT 1 FROM public.n2s_items n
     WHERE (n.order_number = p_order_number OR n.n2s_order_key = p_order_number)
       AND n.item_source IS DISTINCT FROM 'gmail'
       AND public.sub_finder_need2buy(n.status, n.status_label, n.raw));
$function$;

-- The loss an automatic buy may be made at for an order, as a percent of the sale total.
-- NULL = none: the order is bought at a profit only.
CREATE OR REPLACE FUNCTION public.sub_finder_max_loss_pct(p_site text, p_need2buy boolean)
 RETURNS numeric
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT CASE WHEN coalesce(p_need2buy, false) THEN trim_scale(
    coalesce(
      (SELECT l.max_cost_pct - 100 FROM public.sub_finder_loss_limit l
        WHERE l.site = public.sub_finder_site_norm(p_site) AND l.max_cost_pct IS NOT NULL),
      (SELECT l.max_cost_pct - 100 FROM public.sub_finder_loss_limit l
        WHERE l.site = '*' AND l.max_cost_pct IS NOT NULL),
      (SELECT greatest(c.auto_buy_max_loss_pct, 0) FROM public.sub_finder_config c),
      0)) END;
$function$;

-- May the automatic buy take this cover: gate 1 (a profit), or, when the order has a loss
-- allowance, a gate 2 cover whose loss is inside it.
CREATE OR REPLACE FUNCTION public.sub_finder_autobuy_gate(x jsonb, p_max_loss_pct numeric)
 RETURNS boolean
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT coalesce(
    (x->>'gate')::int = 1
    OR (p_max_loss_pct IS NOT NULL
        AND (x->>'gate')::int = 2
        AND (x->>'profit')::numeric <= 0
        AND (x->>'total')::numeric + (x->>'profit')::numeric > 0
        AND -(x->>'profit')::numeric
            <= ((x->>'total')::numeric + (x->>'profit')::numeric) * p_max_loss_pct / 100.0),
    false);
$function$;

-- What the CRM reads: the limit for every marketplace, and whether this key may change them.
CREATE OR REPLACE FUNCTION public.sub_finder_loss_limits(p_key_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  c     public.sub_finder_config;
  v_def numeric;
BEGIN
  SELECT * INTO c FROM public.sub_finder_config;
  IF NOT coalesce(c.enabled, false) OR NOT (p_key_id = ANY (c.key_ids)) THEN
    RETURN jsonb_build_object('error', 'forbidden', 'detail', 'the sub finder is not enabled for this key');
  END IF;
  v_def := 100 + public.sub_finder_max_loss_pct('*', true);
  RETURN jsonb_build_object(
    'applies_to', 'need2buy orders only; every other order is bought automatically at a profit only',
    'unit', 'the most an automatic buy may cost, as a percent of the sale total (100 = no loss, 105 = a 5% loss)',
    'min', 100, 'max', 200,
    'default_max_cost_pct', v_def,
    'by_marketplace', (SELECT coalesce(jsonb_object_agg(l.site, trim_scale(l.max_cost_pct) ORDER BY l.site), '{}'::jsonb)
                         FROM public.sub_finder_loss_limit l WHERE l.site <> '*' AND l.max_cost_pct IS NOT NULL),
    'marketplaces', to_jsonb(ARRAY['evo', 'gametime', 'gotickets', 'seatgeek', 'stubhub', 'ticketmaster',
                                   'tickpick', 'viagogo', 'vivid']),
    'can_set', p_key_id = ANY (c.loss_limit_key_ids),
    'updated_at', (SELECT max(l.set_at) FROM public.sub_finder_loss_limit l));
END
$function$;

-- The CRM sets limits: {"default_max_cost_pct": 105, "by_marketplace": {"stubhub": 110, "vivid": null}}.
-- A number is 100 to 200; null takes a marketplace (or the default) back to "not set".
-- Nothing is changed unless every value in the body is valid.
CREATE OR REPLACE FUNCTION public.sub_finder_loss_limits_set(p_key_id bigint, p_key_label text, p_body jsonb, p_by text DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  c     public.sub_finder_config;
  v_by  text := 'crm api key ' || coalesce(p_key_label, p_key_id::text) || coalesce(' / ' || nullif(btrim(p_by), ''), '');
  v_set jsonb := '{}'::jsonb;        -- site -> new value (a number or null), validated
  r     record;
  v_site text;
BEGIN
  SELECT * INTO c FROM public.sub_finder_config;
  IF NOT coalesce(c.enabled, false) OR NOT (p_key_id = ANY (c.key_ids)) OR NOT (p_key_id = ANY (c.loss_limit_key_ids)) THEN
    RETURN jsonb_build_object('error', 'forbidden', 'detail', 'this key may not set the automatic buy loss limits');
  END IF;
  IF jsonb_typeof(p_body) IS DISTINCT FROM 'object'
     OR NOT (p_body ? 'default_max_cost_pct' OR p_body ? 'by_marketplace')
     OR (p_body ? 'by_marketplace' AND jsonb_typeof(p_body->'by_marketplace') <> 'object') THEN
    RETURN jsonb_build_object('error', 'invalid',
      'detail', 'send {"default_max_cost_pct": 100-200 or null, "by_marketplace": {"<marketplace>": 100-200 or null}}');
  END IF;
  FOR r IN
    SELECT '*' AS k, p_body->'default_max_cost_pct' AS v WHERE p_body ? 'default_max_cost_pct'
    UNION ALL
    SELECT e.key, e.value FROM jsonb_each(coalesce(p_body->'by_marketplace', '{}'::jsonb)) e
  LOOP
    v_site := CASE WHEN r.k = '*' THEN '*' ELSE public.sub_finder_site_norm(r.k) END;
    IF v_site IS NULL OR (r.k <> '*' AND v_site = '*') THEN
      RETURN jsonb_build_object('error', 'invalid', 'detail', 'not a marketplace name: ' || r.k);
    END IF;
    IF jsonb_typeof(r.v) = 'null' THEN
      v_set := v_set || jsonb_build_object(v_site, NULL);
    ELSIF jsonb_typeof(r.v) = 'number' AND (r.v)::text::numeric BETWEEN 100 AND 200 THEN
      v_set := v_set || jsonb_build_object(v_site, round((r.v)::text::numeric, 2));
    ELSE
      RETURN jsonb_build_object('error', 'invalid',
        'detail', 'the limit for ' || r.k || ' must be a number from 100 to 200 (percent of the sale total), or null');
    END IF;
  END LOOP;
  FOR r IN SELECT e.key AS site, CASE WHEN jsonb_typeof(e.value) = 'null' THEN NULL ELSE (e.value)::text::numeric END AS pct
             FROM jsonb_each(v_set) e
  LOOP
    INSERT INTO public.sub_finder_loss_limit_log (key_id, set_by, site, old_pct, new_pct)
    VALUES (p_key_id, v_by, r.site, (SELECT l.max_cost_pct FROM public.sub_finder_loss_limit l WHERE l.site = r.site), r.pct);
    INSERT INTO public.sub_finder_loss_limit (site, max_cost_pct, set_by, set_at)
    VALUES (r.site, r.pct, v_by, now())
    ON CONFLICT (site) DO UPDATE SET max_cost_pct = excluded.max_cost_pct, set_by = excluded.set_by, set_at = now();
  END LOOP;
  RETURN public.sub_finder_loss_limits(p_key_id);
END
$function$;

REVOKE ALL ON FUNCTION public.sub_finder_order_is_need2buy(text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.sub_finder_max_loss_pct(text, boolean) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.sub_finder_autobuy_gate(jsonb, numeric) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.sub_finder_loss_limits(bigint) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.sub_finder_loss_limits_set(bigint, text, jsonb, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.sub_finder_order_is_need2buy(text) TO service_role;
GRANT EXECUTE ON FUNCTION public.sub_finder_max_loss_pct(text, boolean) TO service_role;
GRANT EXECUTE ON FUNCTION public.sub_finder_autobuy_gate(jsonb, numeric) TO service_role;
GRANT EXECUTE ON FUNCTION public.sub_finder_loss_limits(bigint) TO service_role;
GRANT EXECUTE ON FUNCTION public.sub_finder_loss_limits_set(bigint, text, jsonb, text) TO service_role;

-- ── full definitions of the three functions that change ─────────────────────────────────────

CREATE OR REPLACE FUNCTION public.sub_finder_autobuy(p_job_id uuid)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
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
  v_loss  numeric;                  -- the loss this order may be bought at, % of the sale; NULL = profit only
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
    -- 20261113320000: a loss is allowed only on a need2buy order, up to the CRM's limit for the
    -- marketplace it sold on (5% unless set); every other order is bought at a profit only
    v_loss := public.sub_finder_max_loss_pct(o.site, o.via_need2buy OR public.sub_finder_order_is_need2buy(o.order_number));
    -- the best one-to-one this may take: a profit, or (need2buy orders) breakeven or a gate 2 loss inside the limit;
    -- our own feed, exact quantity, clear view. Covers are ordered gate first, then cheapest.
    SELECT x INTO cv FROM jsonb_array_elements(o.covers) WITH ORDINALITY t(x, n)
     WHERE public.sub_finder_cover_buyable(o.order_number, x) AND x->>'source' = 'native' AND public.sub_finder_autobuy_gate(x, v_loss)
       AND (x->>'spare')::int = 0 AND x->>'view' IS DISTINCT FROM 'obstructed'
       AND jsonb_array_length(public.sub_finder_cover_flags(x)) = 0     -- a flagged cover waits for the CRM
       AND ((x->>'gate')::int = 2      -- a gate 2 cover is already inside the loss limit (sub_finder_autobuy_gate)
            OR (x->>'profit')::numeric >= (x->>'total')::numeric * c.auto_buy_min_profit_pct / 100.0)
     ORDER BY n LIMIT 1;
    v_note := CASE
      WHEN NOT c.auto_buy_enabled THEN 'auto_buy_off'
      WHEN cv IS NOT NULL THEN NULL
      WHEN NOT EXISTS (SELECT 1 FROM jsonb_array_elements(o.covers) x
                       WHERE public.sub_finder_cover_buyable(o.order_number, x) AND x->>'source' = 'native' AND public.sub_finder_autobuy_gate(x, v_loss))
        THEN 'no_evo_one_to_one'
      WHEN NOT EXISTS (SELECT 1 FROM jsonb_array_elements(o.covers) x
                       WHERE public.sub_finder_cover_buyable(o.order_number, x) AND public.sub_finder_autobuy_gate(x, v_loss) AND (x->>'spare')::int = 0)
        THEN 'needs_spare_ticket'
      WHEN NOT EXISTS (SELECT 1 FROM jsonb_array_elements(o.covers) x
                       WHERE public.sub_finder_cover_buyable(o.order_number, x) AND public.sub_finder_autobuy_gate(x, v_loss) AND (x->>'spare')::int = 0
                         AND x->>'view' IS DISTINCT FROM 'obstructed')
        THEN 'obstructed_view'
      WHEN NOT EXISTS (SELECT 1 FROM jsonb_array_elements(o.covers) x
                       WHERE public.sub_finder_cover_buyable(o.order_number, x) AND public.sub_finder_autobuy_gate(x, v_loss) AND (x->>'spare')::int = 0
                         AND x->>'view' IS DISTINCT FROM 'obstructed'
                         AND jsonb_array_length(public.sub_finder_cover_flags(x)) = 0)
        THEN 'needs_crm_confirm'
      ELSE 'profit_too_thin' END;
    IF v_note IS NULL AND (
         EXISTS (SELECT 1 FROM public.n2s_items n
                 WHERE (n.order_number = o.order_number OR n.n2s_order_key = o.order_number)
                   AND NOT (n.item_source IS DISTINCT FROM 'gmail'
                            AND public.sub_finder_need2buy(n.status, n.status_label, n.raw)))
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
        v_buy := public.manual_sub_buy_request_market(cv->>'market',
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
$function$;

CREATE OR REPLACE FUNCTION public.manual_sub_buy_total_ceiling(b manual_sub_buy)
 RETURNS numeric
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  -- The most an automatic buy may cost in total, tax included. A need2buy order: the sale plus the
  -- loss allowed for its marketplace. Any other order: under the sale (a profit), mig 20261113320000.
  SELECT CASE WHEN b.requested_by LIKE 'sub finder auto (key %' AND b.sold_ea > 0
              THEN CASE WHEN l.pct IS NULL THEN round(b.sold_ea * b.qty, 2) - 0.01
                        ELSE round(b.sold_ea * b.qty * (1 + greatest(l.pct, 0) / 100.0), 2) END END
  FROM (SELECT public.sub_finder_max_loss_pct(
                 b.sale_site, public.sub_finder_order_is_need2buy(b.sale_order_number)) AS pct) l;
$function$;

CREATE OR REPLACE FUNCTION public.sub_finder_order_json(o sub_finder_order)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT jsonb_build_object(
    'job_id', o.job_id, 'order_number', o.order_number, 'site', o.site,
    'tevo_event_id', o.tevo_event_id, 'event_name', o.event_name, 'event_date', o.event_date, 'venue', o.venue,
    'section', o.section, 'row', o.seat_row, 'qty', o.qty, 'sold_ea', o.sold_ea,
    'order_source', o.order_source, 'state', o.state,
    -- free text the CRM wrote on this order (POST /orders/{n}/notes, or `notes` with the alert)
    'notes', o.crm_notes,
    -- the last decision read from your N2S feed for this order, and what carrying it out answered
    'feed_decision', (SELECT jsonb_build_object(
                         'decision', d.decision, 'listing_id', d.listing_id, 'decided_at', d.decided_at,
                         'decided_by', d.decided_by, 'outcome', d.outcome,
                         'detail', d.result->>'detail', 'flags', d.result->'flags',
                         'acted_at', to_char(d.acted_at AT TIME ZONE 'utc', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'))
                        FROM public.sub_finder_feed_decision d
                       WHERE d.order_number = o.order_number AND d.key_id = o.key_id
                       ORDER BY d.acted_at DESC LIMIT 1),
    'notes_at', to_char(o.crm_notes_at AT TIME ZONE 'utc', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
    -- what to do with the answer, and why it was not bought automatically
    -- once a GoTickets customer has accepted the sub there is nobody left to ask: while the offered
    -- seats are still there, 'offer' reads 'buy_manually' until they are bought. If they are gone
    -- the action is the new match's own (see sub_offer.accepted_next / new_best)
    'action', CASE WHEN o.action = 'offer' AND o.buy_id IS NULL
                        AND EXISTS (SELECT 1 FROM public.sub_finder_gt_offer g
                                     WHERE g.order_number = o.order_number AND g.key_id = o.key_id
                                       AND g.live AND g.gt_status = 'ACCEPTED'
                                       AND NOT coalesce(public.sub_finder_offer_gone(g, o.tevo_event_id), false))
                   THEN 'buy_manually' ELSE o.action END,
    'auto_buy_note', o.auto_buy_note,
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
                     'market', b.market, 'order_id', b.buy_order_id,
                     'evo_order_id', CASE WHEN b.market = 'evo' THEN b.buy_order_id END, 'outcome', b.outcome,
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
    -- the most an automatic buy may cost for this order, as a percent of the sale total
    -- (100 = no loss: profit only), mig 20261113320000
    'auto_buy_max_cost_pct', 100 + coalesce(public.sub_finder_max_loss_pct(
        o.site, o.via_need2buy OR public.sub_finder_order_is_need2buy(o.order_number)), 0),
    'last_stopped_buy', (SELECT jsonb_build_object('buy_id', b.buy_id, 'market', b.market,
                                                    'listing_id', b.ticket_group_id::text, 'reasons', b.reasons,
                                                    'at', to_char(b.updated_at AT TIME ZONE 'utc', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'))
                           FROM public.manual_sub_buy b
                          WHERE b.sale_order_number = o.order_number AND b.state = 'stopped'
                          ORDER BY b.updated_at DESC, b.buy_id DESC LIMIT 1),
    'updated_at', to_char(o.updated_at AT TIME ZONE 'utc', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'));
$function$;
