CREATE OR REPLACE FUNCTION public.sub_finder_job_json(p_key_id bigint, p_job_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
  IF NOT coalesce((public.sub_finder_access(p_key_id)->>'find')::boolean, false) THEN
    RETURN jsonb_build_object('error', 'forbidden', 'detail', 'this key may not use the sub finder');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.sub_finder_job WHERE job_id = p_job_id AND key_id = p_key_id) THEN
    RETURN NULL;
  END IF;
  IF NOT public.sub_finder_bg_settle() THEN       -- else the background job settles it (20261113260000)
    PERFORM public.sub_finder_settle(p_job_id);
  END IF;
  RETURN (
    SELECT jsonb_build_object(
      'job_id', j.job_id, 'status', j.status, 'order_count', j.order_count,
      'created_at', j.created_at, 'done_at', j.done_at,
      'summary', (SELECT jsonb_object_agg(s.state, s.n) FROM (
                    SELECT o.state, count(*) AS n FROM public.sub_finder_order o
                    WHERE o.job_id = j.job_id GROUP BY o.state) s),
      'items', (SELECT coalesce(jsonb_agg(public.sub_finder_order_json(o) ORDER BY o.idx), '[]'::jsonb)
                FROM public.sub_finder_order o WHERE o.job_id = j.job_id))
    FROM public.sub_finder_job j WHERE j.job_id = p_job_id);
END
$function$

