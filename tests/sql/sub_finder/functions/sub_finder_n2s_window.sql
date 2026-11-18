CREATE OR REPLACE FUNCTION public.sub_finder_n2s_window(p_order_number text)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT jsonb_build_object(
           'kind', x.kind,
           'alert_at', to_char(x.alert_at AT TIME ZONE 'utc', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
           'timer_expires_at', CASE WHEN x.kind = 'n2s'
                                    THEN to_char(x.timer_expires_at AT TIME ZONE 'utc', 'YYYY-MM-DD"T"HH24:MI:SS"Z"') END,
           -- need2buy: while the item is open. An alert: until its timer runs out.
           'in_window', x.open AND (x.kind = 'need2buy' OR coalesce(x.timer_expires_at > now(), false)))
    FROM (SELECT CASE WHEN n.item_source = 'gmail' OR public.sub_finder_need2buy(n.status, n.status_label, n.raw)
                      THEN 'need2buy' ELSE 'n2s' END AS kind,
                 NOT coalesce(n.is_terminal, false) AS open, n.alert_at, n.timer_expires_at
            FROM public.n2s_items n
           WHERE n.order_number = p_order_number OR n.n2s_order_key = p_order_number
           ORDER BY coalesce(n.is_terminal, false), n.last_seen_at DESC NULLS LAST, n.n2s_id DESC
           LIMIT 1) x
$function$

