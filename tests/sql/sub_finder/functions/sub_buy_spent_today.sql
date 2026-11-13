CREATE OR REPLACE FUNCTION public.sub_buy_spent_today()
 RETURNS numeric
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT (SELECT COALESCE(sum(COALESCE(b.bought_total_usd, round(b.max_price_ea * b.qty, 2))), 0)
            FROM public.manual_sub_buy b
           WHERE b.state IN ('buying', 'bought', 'unknown')
             AND (b.updated_at AT TIME ZONE 'America/New_York')::date = (now() AT TIME ZONE 'America/New_York')::date)
       + (SELECT COALESCE(sum(COALESCE(e.buy_total_usd, e.sub_total_usd + COALESCE(e.est_tax_usd, 0))), 0)
            FROM public.n2s_autobuy_exec e
           WHERE e.mode = 'live'
             AND e.phase IN ('buying', 'buy_sent', 'sub_accepted', 'accepted', 'buy_unknown', 'accept_failed', 'accept_unknown')
             AND (e.live_started_at AT TIME ZONE 'America/New_York')::date = (now() AT TIME ZONE 'America/New_York')::date)
$function$

