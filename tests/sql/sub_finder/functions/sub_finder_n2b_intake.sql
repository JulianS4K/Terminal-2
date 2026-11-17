CREATE OR REPLACE FUNCTION public.sub_finder_n2b_intake()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  c     public.sub_finder_config;
  r     record;
  v_out jsonb;
  v_lbl text;
  v_n   integer := 0;
BEGIN
  SELECT * INTO c FROM public.sub_finder_config;
  IF NOT (c.enabled AND c.n2b_intake_enabled) OR c.n2b_key_id IS NULL OR NOT (c.n2b_key_id = ANY (c.key_ids)) THEN
    RETURN 0;
  END IF;
  -- the label went (or the item closed): forget it, so labelling it again hands it over again
  DELETE FROM public.sub_finder_n2b_seen s
   WHERE NOT EXISTS (SELECT 1 FROM public.n2s_items n
                      WHERE n.n2s_id = s.n2s_id AND NOT coalesce(n.is_terminal, false)
                        AND n.item_source IS DISTINCT FROM 'gmail'
                        AND public.sub_finder_need2buy(n.status, n.status_label, n.raw));
  SELECT k.label INTO v_lbl FROM public.mcp_api_keys k WHERE k.id = c.n2b_key_id;
  FOR r IN
    SELECT n.n2s_id, n.order_number, n.marketplace, n.raw->>'seller_notes' AS notes
      FROM public.n2s_items n
     WHERE NOT coalesce(n.is_terminal, false) AND n.item_source IS DISTINCT FROM 'gmail'
       AND public.sub_finder_need2buy(n.status, n.status_label, n.raw)
       AND n.order_number ~ '^[A-Za-z0-9._-]{1,64}$'
       AND NOT EXISTS (SELECT 1 FROM public.sub_finder_n2b_seen s WHERE s.n2s_id = n.n2s_id)
     ORDER BY n.n2s_updated_at NULLS LAST, n.n2s_id LIMIT c.n2b_batch
  LOOP
    BEGIN
      v_out := public.sub_finder_submit(
        c.n2b_key_id, coalesce(v_lbl, 'crm need2buy'),
        jsonb_build_array(jsonb_strip_nulls(jsonb_build_object(
          'order_number', r.order_number, 'site', r.marketplace,
          'notes', left(nullif(btrim(r.notes), ''), 500)))),
        'need2buy:' || r.n2s_id || ':' || to_char(clock_timestamp(), 'YYYYMMDDHH24MISSUS'));   -- never a replay: sub_finder_n2b_seen is the once-only guard
    EXCEPTION WHEN OTHERS THEN
      v_out := jsonb_build_object('error', left(SQLERRM, 200));      -- one bad item never stops the rest
    END;
    -- these lookups live as long as the label does (or until the marketplace says the sale is over)
    UPDATE public.sub_finder_order SET via_need2buy = true
     WHERE job_id = (v_out->>'job_id')::uuid AND order_number = r.order_number;
    INSERT INTO public.sub_finder_n2b_seen (n2s_id, order_number, job_id, result)
    VALUES (r.n2s_id, r.order_number, (v_out->>'job_id')::uuid, coalesce(v_out->>'error', v_out->>'status'))
    ON CONFLICT (n2s_id) DO NOTHING;
    v_n := v_n + 1;
  END LOOP;
  RETURN v_n;
END
$function$

