-- Migration 20261113310000 · level:secondary-sales · lane:D0 · writes:sub_finder_config,sub_finder_stop_is_listing,sub_finder_listing_tried,sub_finder_cover_buyable,sub_finder_release_stopped,sub_finder_autobuy,sub_finder_buy,sub_finder_refresh,sub_finder_order_json · reads:manual_sub_buy,sub_finder_order,sub_finder_gt_offer · pre:20261113300000
--
-- SUB FINDER: when a buy stops, move on to the next cover.
--
-- Operator 2026-11-13: "do 1" (fall back when a buy stops).
--
-- Until now a buy that stopped (the listing sold, its price rose, the seller rejected it) stayed
-- attached to the order. Nothing else was tried until a person stepped in, and the CRM's buy
-- call answered 409 "a buy was already requested" even though nothing had been bought.
--
-- Now, once a minute (in sub_finder_refresh), an order whose buy stopped for a reason that
-- belongs to THAT LISTING is let go of and matched again, and the automatic buy may take the
-- next-best cover. Guards against going round in circles:
--   * only listing reasons (sub_finder_stop_is_listing): gone, price rose, quantity or split,
--     our own listing, unreadable, the market refused it, the taxed total was over the limit,
--     the seller rejected or cancelled. A stop that is about US (a spend ceiling, GoTickets
--     buying off, gift cards short, missing setup) is never released: trying another listing
--     would stop the same way.
--   * a listing that stopped for an order is not picked again for that order for
--     buy_fallback_retry (12 hours).
--   * at most buy_fallback_max (3) attempts per order per New York day.
--   * an 'unknown' outcome is never released: a person checks the market first.
--   * every rule of the automatic buy still applies to the next cover; nothing is loosened.
-- sub_finder_config.buy_fallback_enabled switches the automatic part (off by default).
--
-- Independently of that switch, the CRM's own buy call no longer answers 409 when the order's
-- only buy is a stopped one: a person may pick a different cover at any time.
-- The order object gains `last_stopped_buy` ({buy_id, market, listing_id, reasons, at}): the
-- most recent buy that stopped for this order, so the CRM can see what was tried.
--
-- rollback: UPDATE public.sub_finder_config SET buy_fallback_enabled = false WHERE id = true;

ALTER TABLE public.sub_finder_config
  ADD COLUMN IF NOT EXISTS buy_fallback_enabled boolean  NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS buy_fallback_max     integer  NOT NULL DEFAULT 3,
  ADD COLUMN IF NOT EXISTS buy_fallback_retry   interval NOT NULL DEFAULT '12 hours';

-- Is every reason this buy stopped for about the listing itself (so another listing may do)?
CREATE OR REPLACE FUNCTION public.sub_finder_stop_is_listing(p_reasons text[])
RETURNS boolean
LANGUAGE sql
IMMUTABLE
SET search_path = public, pg_temp
AS $function$
  SELECT coalesce(cardinality(p_reasons), 0) > 0
     AND p_reasons <@ ARRAY['listing_gone', 'price_above_ceiling', 'short_quantity', 'split_not_allowed',
                            'our_own_listing', 'unknown_format', 'no_seller_office', 'listing_read_failed',
                            'buy_failed', 'total_above_ceiling', 'tax_quote_failed', 'no_electronic_delivery',
                            'price_unknown', 'listing_unreadable', 'own_listing_check_failed',
                            'seller_rejected', 'order_canceled']::text[]
$function$;

-- Did a buy of this listing already stop for this order, recently?
CREATE OR REPLACE FUNCTION public.sub_finder_listing_tried(p_order_number text, p_market text, p_listing_id text)
RETURNS boolean
LANGUAGE sql
STABLE
SET search_path = public, pg_temp
AS $function$
  SELECT EXISTS (
    SELECT 1 FROM public.manual_sub_buy b
     WHERE b.sale_order_number = p_order_number AND b.market = p_market
       AND b.ticket_group_id::text = p_listing_id AND b.state = 'stopped'
       AND b.updated_at > now() - (SELECT buy_fallback_retry FROM public.sub_finder_config))
$function$;

-- May the automatic buy take this cover for this order: a market we can buy on, and not a
-- listing that already stopped for the order.
CREATE OR REPLACE FUNCTION public.sub_finder_cover_buyable(p_order_number text, p_cover jsonb)
RETURNS boolean
LANGUAGE sql
STABLE
SET search_path = public, pg_temp
AS $function$
  SELECT public.sub_finder_market_buyable(p_cover->>'market')
     AND NOT public.sub_finder_listing_tried(p_order_number, p_cover->>'market', p_cover->>'listing_id')
$function$;

-- Let go of stopped buys that another listing could replace. Returns how many orders were released.
CREATE OR REPLACE FUNCTION public.sub_finder_release_stopped()
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE
  c       public.sub_finder_config;
  r       record;
  v_n     integer := 0;
  v_today date := (now() AT TIME ZONE 'America/New_York')::date;
BEGIN
  SELECT * INTO c FROM public.sub_finder_config;
  IF NOT c.buy_fallback_enabled THEN RETURN 0; END IF;
  FOR r IN
    SELECT o.job_id, o.idx, o.buy_id
      FROM public.sub_finder_order o
      JOIN public.manual_sub_buy b ON b.buy_id = o.buy_id
     WHERE o.watching AND b.state = 'stopped' AND public.sub_finder_stop_is_listing(b.reasons)
       -- an accepted GoTickets offer's buy is released by its own rule (sub_finder_refresh, step 4)
       AND NOT EXISTS (SELECT 1 FROM public.sub_finder_gt_offer g WHERE g.buy_id = o.buy_id)
       AND (SELECT count(*) FROM public.manual_sub_buy s
             WHERE s.sale_order_number = o.order_number AND s.state = 'stopped'
               AND (s.updated_at AT TIME ZONE 'America/New_York')::date = v_today) < c.buy_fallback_max
     ORDER BY o.job_id, o.idx LIMIT 50
  LOOP
    UPDATE public.sub_finder_order
       SET buy_id = NULL, action = CASE WHEN action = 'auto_bought' THEN 'review' ELSE action END,
           rematch = true, updated_at = now()
     WHERE job_id = r.job_id AND idx = r.idx AND buy_id = r.buy_id;
    v_n := v_n + 1;
  END LOOP;
  RETURN v_n;
END
$function$;

REVOKE ALL ON FUNCTION public.sub_finder_stop_is_listing(text[]) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.sub_finder_listing_tried(text, text, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.sub_finder_cover_buyable(text, jsonb) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.sub_finder_release_stopped() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.sub_finder_stop_is_listing(text[]) TO service_role;
GRANT EXECUTE ON FUNCTION public.sub_finder_listing_tried(text, text, text) TO service_role;
GRANT EXECUTE ON FUNCTION public.sub_finder_cover_buyable(text, jsonb) TO service_role;
GRANT EXECUTE ON FUNCTION public.sub_finder_release_stopped() TO service_role;

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

-- the automatic buy skips a listing that already stopped for this order
SELECT pg_temp._sf_patch('public.sub_finder_autobuy(uuid)'::regprocedure, 'sub_finder_cover_buyable', ARRAY[
  [$o$public.sub_finder_market_buyable(x->>'market')$o$, $n$public.sub_finder_cover_buyable(o.order_number, x)$n$, '5']]);

-- a person may buy a different cover once the order's only buy has stopped
SELECT pg_temp._sf_patch('public.sub_finder_buy(bigint, text, uuid, text, text, text)'::regprocedure, $m$b.state = 'stopped') THEN$m$, ARRAY[
  [$o$IF o.buy_id IS NOT NULL THEN$o$,
   $n$IF o.buy_id IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM public.manual_sub_buy b WHERE b.buy_id = o.buy_id AND b.state = 'stopped') THEN$n$, '1']]);

-- once a minute: let go of stopped buys another listing could replace
SELECT pg_temp._sf_patch('public.sub_finder_refresh()'::regprocedure, 'sub_finder_release_stopped', ARRAY[
  [$o$RETURN jsonb_build_object('closed', v_closed, 'events', cardinality(v_evs), 'jobs_rematched', v_jobs);$o$,
   $n$PERFORM public.sub_finder_release_stopped();           -- 20261113310000: does nothing while the switch is off
  RETURN jsonb_build_object('closed', v_closed, 'events', cardinality(v_evs), 'jobs_rematched', v_jobs);$n$, '1']]);

-- what the CRM reads: the most recent buy that stopped for this order
SELECT pg_temp._sf_patch('public.sub_finder_order_json(public.sub_finder_order)'::regprocedure, 'last_stopped_buy', ARRAY[
  [$o$'updated_at', to_char(o.updated_at AT TIME ZONE 'utc'$o$,
   $n$'last_stopped_buy', (SELECT jsonb_build_object('buy_id', b.buy_id, 'market', b.market,
                                                    'listing_id', b.ticket_group_id::text, 'reasons', b.reasons,
                                                    'at', to_char(b.updated_at AT TIME ZONE 'utc', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'))
                           FROM public.manual_sub_buy b
                          WHERE b.sale_order_number = o.order_number AND b.state = 'stopped'
                          ORDER BY b.updated_at DESC, b.buy_id DESC LIMIT 1),
    'updated_at', to_char(o.updated_at AT TIME ZONE 'utc'$n$, '1']]);
