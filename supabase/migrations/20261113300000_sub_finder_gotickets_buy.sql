-- Migration 20261113300000 · level:secondary-sales · lane:D0 · writes:manual_sub_buy,manual_sub_buy_config,sub_finder_config,manual_sub_buy_request_market,sub_finder_market_buyable,manual_sub_buy_claim,manual_sub_buy_record,manual_sub_buy_follow_claim,manual_sub_buy_alert_text,sub_finder_buy,sub_finder_buy_confirmed,sub_finder_autobuy,sub_finder_gt_offer_buy,sub_finder_match,sub_finder_order_json · reads:n2s_gt_current,gotickets_event,n2s_autobuy_config · pre:20261113270000
--
-- SUB FINDER: a GoTickets cover can be bought, the same way an EVO cover is.
--
-- Operator 2026-11-13: "n2s also incorporated gotickets autobuy look at how it functions and
-- incorporate but modify to match how we use evo".
--
-- How we use EVO (unchanged): a buy is one row in manual_sub_buy, filed by the automatic
-- one-to-one buy (sub_finder_autobuy), by the CRM (sub_finder_buy, also from a feed decision)
-- or after a GoTickets customer accepts an offer (sub_finder_gt_offer_buy). The worker
-- (core/manual_sub_buy.py) claims one row under a lease, reads the listing fresh, buys once,
-- never retries, and follows the order until the seller confirms or rejects.
--
-- GoTickets now rides the same path. A row carries its market:
--   manual_sub_buy.market       'evo' (default) | 'gotickets'
--   manual_sub_buy.gt_event_id  the GoTickets event the listing is on
-- For a GoTickets row the worker does what the N2S GoTickets buyer does (mig 20261113400000):
-- reads the listing from the Pro API, refuses one of our own listings, takes the cheapest
-- electronic delivery, prices the order with GoTickets' formula, pays from gift cards only and
-- sends POST /rest/pro/api/orders once through gotickets_buy_client.py (GT_BUY_WRITES).
--
-- Switches, all OFF until the operator turns them on:
--   sub_finder_config.gt_buy_enabled      the sub finder may pick a GoTickets cover (automatic
--                                         buy, CRM buy, accepted-offer buy)
--   manual_sub_buy_config.gt_enabled      the worker may send a GoTickets buy
-- A GoTickets cover reads `buyable: true`, and a request is filed, only while BOTH are on, so
-- one switch alone changes nothing. If the worker's switch goes off after a request was filed,
-- that row stops with 'gotickets_buy_off' and nothing is sent.
-- Limits (operator 2026-11-13: "gotix celing here matches evo"): GoTickets uses the same
-- per-order and per-day ceilings as EVO (manual_sub_buy_config.per_order_cap_usd /
-- daily_cap_usd). gt_per_order_cap_usd / gt_daily_cap_usd are empty; a number there overrides
-- EVO's for GoTickets only. Each market's spend is counted against its own day ceiling. The
-- automatic buy's own daily cap (sub_finder_config.auto_buy_daily_cap_usd) counts
-- both markets together. Every other rule is the EVO rule: exact quantity, no flags, a profit
-- or a loss inside the limit, never an N2S or PED order, our copy of the order must agree, the
-- sale must still be live, one buy per sale.
--
-- The buyer details GoTickets needs on an order are copied once from the N2S buyer's config
-- (the same account); after that this path reads only its own config.
--
-- Every existing function is patched in place; each patch fails loudly if its anchor is not
-- there the expected number of times, and does nothing on a second run.
--
-- rollback: UPDATE public.sub_finder_config SET gt_buy_enabled = false WHERE id = true;
--           UPDATE public.manual_sub_buy_config SET gt_enabled = false WHERE id = true;
--           (to remove: re-apply the patched functions from their earlier migrations and drop
--            the two new functions and the new columns.)

ALTER TABLE public.manual_sub_buy
  ADD COLUMN IF NOT EXISTS market      text NOT NULL DEFAULT 'evo',
  ADD COLUMN IF NOT EXISTS gt_event_id bigint;

ALTER TABLE public.manual_sub_buy_config
  ADD COLUMN IF NOT EXISTS gt_enabled           boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS gt_per_order_cap_usd numeric,          -- NULL = the EVO ceiling
  ADD COLUMN IF NOT EXISTS gt_daily_cap_usd     numeric,          -- NULL = the EVO ceiling
  ADD COLUMN IF NOT EXISTS gt_buyer_email       text,
  ADD COLUMN IF NOT EXISTS gt_buyer_phone       text,
  ADD COLUMN IF NOT EXISTS gt_billing_address   jsonb,
  ADD COLUMN IF NOT EXISTS gt_recipient         jsonb,
  ADD COLUMN IF NOT EXISTS gt_gift_card_ids     bigint[];

ALTER TABLE public.sub_finder_config
  ADD COLUMN IF NOT EXISTS gt_buy_enabled boolean NOT NULL DEFAULT false;

DO $chk$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'manual_sub_buy_market_check') THEN
    ALTER TABLE public.manual_sub_buy
      ADD CONSTRAINT manual_sub_buy_market_check CHECK (market IN ('evo', 'gotickets'));
  END IF;
  -- the GoTickets buyer details: copied once from the N2S buyer's config, where they exist
  IF EXISTS (SELECT 1 FROM information_schema.columns
              WHERE table_schema = 'public' AND table_name = 'n2s_autobuy_config' AND column_name = 'gt_buyer_email') THEN
    EXECUTE $q$
      UPDATE public.manual_sub_buy_config m
         SET gt_buyer_email     = coalesce(m.gt_buyer_email, n.gt_buyer_email),
             gt_buyer_phone     = coalesce(m.gt_buyer_phone, n.gt_buyer_phone),
             gt_billing_address = coalesce(m.gt_billing_address, n.gt_billing_address),
             gt_recipient       = coalesce(m.gt_recipient, n.gt_recipient),
             gt_gift_card_ids   = coalesce(m.gt_gift_card_ids, n.gt_gift_card_ids::bigint[])
        FROM public.n2s_autobuy_config n
       WHERE m.id = true
    $q$;
  END IF;
END
$chk$;

-- Can a cover on this market be bought through this path right now?
CREATE OR REPLACE FUNCTION public.sub_finder_market_buyable(p_market text)
RETURNS boolean
LANGUAGE sql
STABLE
SET search_path = public, pg_temp
AS $function$
  SELECT p_market = 'evo'
      OR (p_market = 'gotickets'
          AND coalesce((SELECT gt_buy_enabled FROM public.sub_finder_config), false)
          AND coalesce((SELECT gt_enabled FROM public.manual_sub_buy_config), false))   -- both switches
$function$;

REVOKE ALL ON FUNCTION public.sub_finder_market_buyable(text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.sub_finder_market_buyable(text) TO service_role;

-- File one buy request on a named market. EVO: exactly manual_sub_buy_request. GoTickets: the
-- same row, marked 'gotickets', with the GoTickets event the listing is on (from our own feed;
-- a row without one is stopped by the worker with 'no_gt_event_id', nothing is sent).
CREATE OR REPLACE FUNCTION public.manual_sub_buy_request_market(
  p_market text, p_sale_site text, p_sale_order_number text, p_tevo_event_id bigint, p_listing_id bigint,
  p_qty integer, p_max_price_ea numeric, p_sold_ea numeric DEFAULT NULL, p_event_name text DEFAULT NULL,
  p_requested_by text DEFAULT NULL, p_note text DEFAULT NULL)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE
  v_market text := lower(coalesce(btrim(p_market), 'evo'));
  v_id     bigint;
  v_event  bigint;
BEGIN
  IF v_market NOT IN ('evo', 'gotickets') THEN
    RAISE EXCEPTION 'manual_sub_buy_request_market: cannot buy on market %', p_market;
  END IF;
  v_id := public.manual_sub_buy_request(p_sale_site, p_sale_order_number, p_tevo_event_id, p_listing_id,
                                        p_qty, p_max_price_ea, p_sold_ea, p_event_name, p_requested_by, p_note);
  IF v_market = 'gotickets' THEN
    SELECT g.gt_event_id INTO v_event FROM public.n2s_gt_current g
     WHERE g.gt_listing_id = p_listing_id AND g.tevo_event_id = p_tevo_event_id AND g.gt_event_id IS NOT NULL
     ORDER BY g.pulled_at DESC LIMIT 1;
    IF v_event IS NULL THEN
      SELECT e.gt_event_id INTO v_event FROM public.gotickets_event e
       WHERE e.tevo_event_id = p_tevo_event_id ORDER BY e.gt_event_id LIMIT 1;
    END IF;
    UPDATE public.manual_sub_buy SET market = 'gotickets', gt_event_id = v_event WHERE buy_id = v_id;
  END IF;
  RETURN v_id;
END
$function$;

REVOKE ALL ON FUNCTION public.manual_sub_buy_request_market(text, text, text, bigint, bigint, integer, numeric, numeric, text, text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.manual_sub_buy_request_market(text, text, text, bigint, bigint, integer, numeric, numeric, text, text, text) TO service_role;

-- The money alerts name the market the buy was sent to.
CREATE OR REPLACE FUNCTION public.manual_sub_buy_alert_text(b public.manual_sub_buy, p_kind text)
RETURNS jsonb
LANGUAGE sql
STABLE
SET search_path = public, pg_temp
AS $function$
  SELECT jsonb_build_object(
    'subject', CASE p_kind
        WHEN 'bought'  THEN format('Sub buy PLACED: %s order %s for %s sale %s ($%s)',
                                   t.mkt, b.buy_order_id, b.sale_site, b.sale_order_number, t.total)
        WHEN 'unknown' THEN format('Sub buy NEEDS A CHECK: %s sale %s, %s did not answer clearly',
                                   b.sale_site, b.sale_order_number, t.mkt)
        ELSE format('Sub buy %s: %s order %s for %s sale %s',
                    upper(CASE b.outcome WHEN 'canceled' THEN 'cancelled' ELSE b.outcome END), t.mkt,
                    coalesce(b.buy_order_id, 'n/a'), b.sale_site, b.sale_order_number) END,
    'text', format(E'%s\n\n'
                || E'Buy id %s, requested by %s\n'
                || E'%s order: %s (listing %s)\n'
                || E'Sale it covers: order %s on %s\n\n'
                || E'Event: %s\nSeats: %s\nQty %s at $%s each, total $%s\n'
                || E'Sold at $%s each, total $%s: %s\n%s',
           CASE p_kind
             WHEN 'bought'  THEN t.mkt || ' took the order. Money is committed; waiting for the seller to confirm.'
             WHEN 'unknown' THEN t.mkt || ' did not answer clearly, so we do not know whether this was bought. '
                              || 'Check it in ' || t.mkt || '. No other buy goes out until this is cleared.'
             ELSE CASE b.outcome
                    WHEN 'confirmed' THEN 'The seller confirmed. The sale is covered.'
                    WHEN 'rejected'  THEN 'The seller REJECTED the order. The sale is NOT covered; pick another sub.'
                    ELSE 'The order was CANCELLED. The sale is NOT covered; pick another sub.' END END,
           b.buy_id, b.requested_by,
           t.mkt, coalesce(b.buy_order_id, 'none recorded'), b.ticket_group_id,
           b.sale_order_number, b.sale_site,
           coalesce(b.event_name, 'event ' || coalesce(b.tevo_event_id::text, '?')),
           coalesce(nullif(concat_ws(' row ', b.bought_section, b.bought_row), ''), 'not known yet'),
           b.qty, coalesce(b.bought_price_ea, b.max_price_ea), t.total,
           coalesce(b.sold_ea::text, '?'), coalesce((b.sold_ea * b.qty)::text, '?'),
           CASE WHEN b.sold_ea IS NULL THEN 'profit not known'
                WHEN b.sold_ea * b.qty - t.total >= 0 THEN 'profit $' || round(b.sold_ea * b.qty - t.total, 2)
                ELSE 'LOSS $' || round(t.total - b.sold_ea * b.qty, 2) END,
           CASE WHEN b.rejection_reason IS NOT NULL THEN 'Reason given: ' || b.rejection_reason
                WHEN b.error IS NOT NULL AND p_kind = 'unknown' THEN 'Error: ' || left(b.error, 300)
                ELSE '' END))
  FROM (SELECT round(coalesce(b.order_total_usd, b.bought_total_usd,
                              b.qty * coalesce(b.bought_price_ea, b.max_price_ea)), 2) AS total,
               CASE b.market WHEN 'gotickets' THEN 'GoTickets' ELSE 'EVO' END AS mkt) t
$function$;

-- ── in-place patches ───────────────────────────────────────────────────────────────────────
-- _sf_patch(function, marker, pairs): pairs is {anchor, replacement, times}. Nothing is done
-- when the marker is already in the function; every anchor must be there exactly `times` times.
CREATE OR REPLACE FUNCTION pg_temp._sf_patch(p_fn regprocedure, p_marker text, p_pairs text[][])
RETURNS void
LANGUAGE plpgsql
AS $function$
DECLARE
  v_def text := pg_get_functiondef(p_fn);
  i     integer;
BEGIN
  IF position(p_marker IN v_def) > 0 THEN RETURN; END IF;             -- already patched
  FOR i IN 1 .. array_length(p_pairs, 1) LOOP
    IF (length(v_def) - length(replace(v_def, p_pairs[i][1], ''))) / length(p_pairs[i][1]) <> p_pairs[i][3]::int THEN
      RAISE EXCEPTION '%: anchor % was not found exactly % time(s)', p_fn, i, p_pairs[i][3];
    END IF;
    v_def := replace(v_def, p_pairs[i][1], p_pairs[i][2]);
  END LOOP;
  EXECUTE v_def;
END
$function$;

-- the worker's claim: GoTickets has its own switch, EVO's ceilings unless it is given its own,
-- and gets its buyer details
SELECT pg_temp._sf_patch('public.manual_sub_buy_claim()'::regprocedure, 'gt_per_order_cap_usd', ARRAY[
  [$o$WHERE state IN ('bought', 'unknown') AND (updated_at AT TIME ZONE 'America/New_York')::date = v_today;$o$,
   $n$WHERE state IN ('bought', 'unknown') AND (updated_at AT TIME ZONE 'America/New_York')::date = v_today
     AND market = b.market;                             -- each market spends against its own ceiling$n$, '1'],
  [$o$IF v_total > c.per_order_cap_usd          THEN r := r || 'over_order_cap'::text; END IF;$o$,
   $n$IF b.market = 'gotickets' AND NOT c.gt_enabled THEN r := r || 'gotickets_buy_off'::text; END IF;
  IF v_total > (CASE b.market WHEN 'gotickets' THEN coalesce(c.gt_per_order_cap_usd, c.per_order_cap_usd)
                              ELSE c.per_order_cap_usd END)
    THEN r := r || 'over_order_cap'::text; END IF;$n$, '1'],
  [$o$IF v_spent + v_total > c.daily_cap_usd    THEN r := r || 'over_daily_cap'::text; END IF;$o$,
   $n$IF v_spent + v_total > (CASE b.market WHEN 'gotickets' THEN coalesce(c.gt_daily_cap_usd, c.daily_cap_usd)
                                        ELSE c.daily_cap_usd END)
    THEN r := r || 'over_daily_cap'::text; END IF;$n$, '1'],
  [$o$'tax_quote', c.tax_quote,$o$,
   $n$'tax_quote', c.tax_quote,
                              'gt_buyer_email', c.gt_buyer_email, 'gt_buyer_phone', c.gt_buyer_phone,
                              'gt_billing_address', c.gt_billing_address, 'gt_recipient', c.gt_recipient,
                              'gt_gift_card_ids', to_jsonb(c.gt_gift_card_ids),$n$, '1'],
  [$o$kill_reason = 'a buy was left unfinished: check EVO'$o$,
   $n$kill_reason = 'a buy was left unfinished: check EVO and GoTickets'$n$, '1']]);

SELECT pg_temp._sf_patch('public.manual_sub_buy_record(bigint, uuid, jsonb)'::regprocedure, 'check GoTickets', ARRAY[
  [$o$kill_reason = format('buy %s: outcome unknown, check EVO', p_buy_id)$o$,
   $n$kill_reason = format('buy %s: outcome unknown, %s', p_buy_id,
                                (SELECT CASE b.market WHEN 'gotickets' THEN 'check GoTickets' ELSE 'check EVO' END
                                   FROM public.manual_sub_buy b WHERE b.buy_id = p_buy_id))$n$, '1']]);

SELECT pg_temp._sf_patch('public.manual_sub_buy_follow_claim()'::regprocedure, $m$'market', b.market$m$, ARRAY[
  [$o$RETURN jsonb_build_object('buy_id', b.buy_id, 'buy_order_id', b.buy_order_id);$o$,
   $n$RETURN jsonb_build_object('buy_id', b.buy_id, 'buy_order_id', b.buy_order_id, 'market', b.market);$n$, '1']]);

-- the CRM's buy: an EVO cover, or a GoTickets cover while GoTickets buying is on
SELECT pg_temp._sf_patch('public.sub_finder_buy(bigint, text, uuid, text, text, text)'::regprocedure,
  'manual_sub_buy_request_market', ARRAY[
  [$o$WHERE x->>'market' = 'evo' AND x->>'listing_id' = p_listing_id LIMIT 1;$o$,
   $n$WHERE public.sub_finder_market_buyable(x->>'market') AND x->>'listing_id' = p_listing_id
   ORDER BY (x->>'market' = 'evo') DESC LIMIT 1;$n$, '1'],
  [$o$'that listing is not an EVO cover this job quoted for this order'$o$,
   $n$'that listing is not a cover we can buy that this job quoted for this order'$n$, '1'],
  [$o$v_buy := public.manual_sub_buy_request($o$,
   $n$v_buy := public.manual_sub_buy_request_market(cv->>'market',$n$, '1'],
  [$o$'listing_id', cv->>'listing_id', 'qty', (cv->>'buy_qty')::int,$o$,
   $n$'market', cv->>'market', 'listing_id', cv->>'listing_id', 'qty', (cv->>'buy_qty')::int,$n$, '1']]);

SELECT pg_temp._sf_patch('public.sub_finder_autobuy(uuid)'::regprocedure, 'manual_sub_buy_request_market', ARRAY[
  [$o$x->>'market' = 'evo'$o$, $n$public.sub_finder_market_buyable(x->>'market')$n$, '5'],
  [$o$v_buy := public.manual_sub_buy_request($o$,
   $n$v_buy := public.manual_sub_buy_request_market(cv->>'market',$n$, '1']]);

SELECT pg_temp._sf_patch('public.sub_finder_gt_offer_buy(bigint)'::regprocedure, 'manual_sub_buy_request_market', ARRAY[
  [$o$WHEN r.market <> 'evo' THEN 'not_on_evo'$o$,
   $n$WHEN NOT public.sub_finder_market_buyable(r.market) THEN 'not_on_evo'$n$, '1'],
  [$o$v_buy := public.manual_sub_buy_request($o$,
   $n$v_buy := public.manual_sub_buy_request_market(r.market,$n$, '1']]);

SELECT pg_temp._sf_patch('public.sub_finder_match(uuid, boolean)'::regprocedure, 'sub_finder_market_buyable', ARRAY[
  [$o$'buyable', market = 'evo'$o$, $n$'buyable', public.sub_finder_market_buyable(market)$n$, '1']]);

-- what the CRM reads on a buy: which market it was sent to, and the order number there
SELECT pg_temp._sf_patch('public.sub_finder_order_json(public.sub_finder_order)'::regprocedure, $m$'market', b.market$m$, ARRAY[
  [$o$'evo_order_id', b.buy_order_id, 'outcome', b.outcome,$o$,
   $n$'market', b.market, 'order_id', b.buy_order_id,
                     'evo_order_id', CASE WHEN b.market = 'evo' THEN b.buy_order_id END, 'outcome', b.outcome,$n$, '1']]);

SELECT pg_temp._sf_patch('public.sub_finder_buy_confirmed(bigint, text, uuid, text, text, text, boolean)'::regprocedure,
  'sub_finder_market_buyable', ARRAY[
  [$o$AND x->>'market' = 'evo' AND x->>'listing_id' = p_listing_id$o$,
   $n$AND public.sub_finder_market_buyable(x->>'market') AND x->>'listing_id' = p_listing_id
   ORDER BY (x->>'market' = 'evo') DESC                -- the same cover sub_finder_buy will take$n$, '1']]);
