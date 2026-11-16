CREATE OR REPLACE FUNCTION public.sub_finder_key_gate(p_key_id bigint)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT jsonb_build_object(
    'account_id', coalesce(k.account_id, p_key_id),
    'listed', k.key_id IS NOT NULL,
    'buy', coalesce(k.can_buy, true), 'offer', coalesce(k.can_offer, true),
    'allowed_ips', coalesce((SELECT jsonb_agg(host(a) || CASE WHEN masklen(a) < (CASE family(a) WHEN 4 THEN 32 ELSE 128 END)
                                                              THEN '/' || masklen(a) ELSE '' END)
                               FROM unnest(k.allowed_ips) a), '[]'::jsonb),
    'write_requires_ip', c.write_requires_ip,
    'client_ip_hops', c.client_ip_hops)       -- 20261116010000: which X-Forwarded-For entry is the caller
  FROM public.sub_finder_config c LEFT JOIN public.sub_finder_key k ON k.key_id = p_key_id;
$function$

