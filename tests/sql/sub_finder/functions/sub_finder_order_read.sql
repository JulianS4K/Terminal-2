CREATE OR REPLACE FUNCTION public.sub_finder_order_read(p_key_id bigint, p_job_id uuid, p_order_number text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
  IF NOT coalesce((public.sub_finder_access(p_key_id)->>'find')::boolean, false) THEN
    RETURN jsonb_build_object('error', 'forbidden', 'detail', 'this key may not use the sub finder');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.sub_finder_order
                 WHERE job_id = p_job_id AND key_id = p_key_id AND order_number = p_order_number) THEN
    RETURN NULL;
  END IF;
  IF NOT public.sub_finder_bg_settle() THEN       -- else the background job settles it (20261113260000)
    PERFORM public.sub_finder_settle(p_job_id);
  END IF;
  RETURN (SELECT jsonb_build_object(
            'items', jsonb_agg(public.sub_finder_order_json(o) ORDER BY o.idx), 'count', count(*))
          FROM public.sub_finder_order o
          WHERE o.job_id = p_job_id AND o.key_id = p_key_id AND o.order_number = p_order_number);
END
$function$

