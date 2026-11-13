CREATE OR REPLACE FUNCTION public.sub_buy_evo_inflight()
 RETURNS integer
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT ((SELECT count(*) FROM public.manual_sub_buy b
            WHERE b.market = 'evo'
              AND (b.state = 'buying'
                OR (b.state = 'bought' AND b.final_at IS NULL
                    AND b.updated_at > now() - make_interval(mins => k.evo_inflight_minutes))))
        + (SELECT count(*) FROM public.n2s_autobuy_exec e
            WHERE e.mode = 'live' AND e.sub_source = 'tevo'
              AND (e.phase = 'buying'
                OR (e.phase = 'buy_sent'
                    AND e.live_started_at > now() - make_interval(mins => k.evo_inflight_minutes)))))::integer
    FROM public.sub_buy_control k
$function$

