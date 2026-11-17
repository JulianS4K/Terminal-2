CREATE OR REPLACE FUNCTION public.sub_finder_audit_read(p_key_id bigint, p_since timestamp with time zone DEFAULT NULL::timestamp with time zone, p_limit integer DEFAULT 200, p_offset integer DEFAULT 0)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_limit integer := least(greatest(coalesce(p_limit, 200), 1), 1000);
  v_off   integer := greatest(coalesce(p_offset, 0), 0);
BEGIN
  IF NOT coalesce((public.sub_finder_access(p_key_id)->>'find')::boolean, false) THEN
    RETURN jsonb_build_object('error', 'forbidden', 'detail', 'this key may not read the audit log');
  END IF;
  RETURN (
    WITH f AS (
      SELECT * FROM public.sub_finder_audit a
       WHERE a.account_id = p_key_id AND (p_since IS NULL OR a.at >= p_since)
    ), page AS (
      SELECT * FROM f ORDER BY at DESC, audit_id DESC LIMIT v_limit OFFSET v_off
    )
    SELECT jsonb_build_object(
      'count', (SELECT count(*) FROM page), 'total', (SELECT count(*) FROM f),
      'limit', v_limit, 'offset', v_off,
      'items', (SELECT coalesce(jsonb_agg(jsonb_build_object(
                         'at', to_char(p.at AT TIME ZONE 'utc', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'),
                         'action', p.action, 'order_number', p.order_number, 'listing_id', p.listing_id,
                         'market', p.market, 'amount_usd', p.amount_usd, 'rebate_usd', p.rebate_usd,
                         'source_ip', p.source_ip, 'key_label', p.key_label, 'requested_by', p.requested_by,
                         'idempotency_key', p.idem_key, 'http_status', p.http_status, 'outcome', p.outcome,
                         'buy_id', p.buy_id, 'offer_id', p.offer_id)
                         ORDER BY p.at DESC, p.audit_id DESC), '[]'::jsonb) FROM page p),
      'generated_at', to_char(now() AT TIME ZONE 'utc', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"')));
END
$function$

