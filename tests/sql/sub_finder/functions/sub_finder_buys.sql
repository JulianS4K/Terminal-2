CREATE OR REPLACE FUNCTION public.sub_finder_buys(p_key_id bigint, p_updated_since timestamp with time zone DEFAULT NULL::timestamp with time zone, p_limit integer DEFAULT 200, p_offset integer DEFAULT 0)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  c       public.sub_finder_config;
  v_now   timestamptz := now();
  v_limit integer := least(greatest(coalesce(p_limit, 200), 1), 1000);
  v_off   integer := greatest(coalesce(p_offset, 0), 0);
BEGIN
  SELECT * INTO c FROM public.sub_finder_config;
  IF NOT coalesce(c.enabled, false) OR NOT (p_key_id = ANY (c.key_ids)) OR NOT (p_key_id = ANY (c.autobuys_key_ids)) THEN
    RETURN jsonb_build_object('error', 'forbidden', 'detail', 'this key may not read buy results');
  END IF;
  RETURN (
    WITH f AS (
      SELECT e.live_updated_at AS at, 1 AS src, e.exec_id AS id
        FROM public.n2s_autobuy_exec e
       WHERE e.mode = 'live' AND e.buy_order_id IS NOT NULL
         AND (p_updated_since IS NULL OR e.live_updated_at >= p_updated_since)
      UNION ALL
      SELECT b.changed_at, 2, b.buy_id
        FROM public.manual_sub_buy b
       WHERE b.buy_order_id IS NOT NULL AND b.origin = 'manual'   -- a buy filed by N2S is the n2s_auto item above
         AND (p_updated_since IS NULL OR b.changed_at >= p_updated_since)
    ), page AS (
      SELECT * FROM f ORDER BY at, src, id LIMIT v_limit OFFSET v_off
    )
    SELECT jsonb_build_object(
      'count', (SELECT count(*) FROM page), 'total', (SELECT count(*) FROM f),
      'limit', v_limit, 'offset', v_off,
      'items', (SELECT coalesce(jsonb_agg(
                         CASE p.src
                           WHEN 1 THEN (SELECT public.n2s_autobuy_result_json(e) || jsonb_build_object('buyer', 'n2s_auto')
                                          FROM public.n2s_autobuy_exec e WHERE e.exec_id = p.id)
                           ELSE (SELECT public.sub_finder_buy_result_json(b)
                                   FROM public.manual_sub_buy b WHERE b.buy_id = p.id) END
                         ORDER BY p.at, p.src, p.id), '[]'::jsonb) FROM page p),
      'generated_at', to_char(v_now AT TIME ZONE 'utc', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"')));
END
$function$

