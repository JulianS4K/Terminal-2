CREATE OR REPLACE FUNCTION public.sub_finder_set_notes(p_key_id bigint, p_order_number text, p_notes text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  c      public.sub_finder_config;
  v_note text := left(nullif(btrim(coalesce(p_notes, '')), ''), 500);
  r      record;
BEGIN
  SELECT * INTO c FROM public.sub_finder_config;
  IF NOT c.enabled OR NOT (p_key_id = ANY (c.key_ids)) THEN
    RETURN jsonb_build_object('error', 'forbidden', 'detail', 'this key may not use the sub finder');
  END IF;
  -- the newest lookup of this order for this key: the watched one first
  SELECT o.job_id, o.idx INTO r FROM public.sub_finder_order o
   WHERE o.key_id = p_key_id AND o.order_number = p_order_number
   ORDER BY o.watching DESC, o.updated_at DESC LIMIT 1 FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('error', 'not_found', 'detail', 'no lookup holds this order; alert us first');
  END IF;
  UPDATE public.sub_finder_order
     SET crm_notes = v_note, crm_notes_at = now(), updated_at = now()
   WHERE job_id = r.job_id AND idx = r.idx;
  RETURN jsonb_build_object('order_number', p_order_number, 'job_id', r.job_id, 'notes', v_note,
                            'notes_at', to_char(now() AT TIME ZONE 'utc', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'));
END
$function$

