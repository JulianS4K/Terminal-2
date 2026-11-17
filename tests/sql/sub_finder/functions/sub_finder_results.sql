CREATE OR REPLACE FUNCTION public.sub_finder_results(p_key_id bigint, p_updated_since timestamp with time zone DEFAULT NULL::timestamp with time zone, p_limit integer DEFAULT 200, p_offset integer DEFAULT 0)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_now   timestamptz := now();
  v_limit integer := least(greatest(coalesce(p_limit, 200), 1), 1000);
  v_off   integer := greatest(coalesce(p_offset, 0), 0);
  r       record;
BEGIN
  IF NOT coalesce((public.sub_finder_access(p_key_id)->>'find')::boolean, false) THEN
    RETURN jsonb_build_object('error', 'forbidden', 'detail', 'this key may not use the sub finder');
  END IF;
  -- settle this key's open jobs first, so a caller that only ever syncs still gets answers
  FOR r IN SELECT job_id FROM public.sub_finder_job
            WHERE key_id = p_key_id AND status <> 'done' AND NOT public.sub_finder_bg_settle() LOOP
    PERFORM public.sub_finder_settle(r.job_id);
  END LOOP;
  RETURN (
    WITH f AS (
      SELECT o.* FROM public.sub_finder_order o
      WHERE o.key_id = p_key_id AND o.state <> 'pending'
        AND (p_updated_since IS NULL OR o.updated_at >= p_updated_since)
    ), page AS (
      SELECT * FROM f ORDER BY updated_at, job_id, idx LIMIT v_limit OFFSET v_off
    )
    SELECT jsonb_build_object(
      'count', (SELECT count(*) FROM page), 'total', (SELECT count(*) FROM f),
      'limit', v_limit, 'offset', v_off,
      'items', (SELECT coalesce(jsonb_agg(public.sub_finder_order_json(p) ORDER BY p.updated_at, p.job_id, p.idx),
                                '[]'::jsonb) FROM page p),
      'generated_at', to_char(v_now AT TIME ZONE 'utc', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"')));
END
$function$

