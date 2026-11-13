CREATE OR REPLACE FUNCTION public.sub_finder_loss_limits_set(p_key_id bigint, p_key_label text, p_body jsonb, p_by text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  c     public.sub_finder_config;
  v_by  text := 'crm api key ' || coalesce(p_key_label, p_key_id::text) || coalesce(' / ' || nullif(btrim(p_by), ''), '');
  v_set jsonb := '{}'::jsonb;        -- site -> new value (a number or null), validated
  r     record;
  v_site text;
BEGIN
  SELECT * INTO c FROM public.sub_finder_config;
  IF NOT coalesce(c.enabled, false) OR NOT (p_key_id = ANY (c.key_ids)) OR NOT (p_key_id = ANY (c.loss_limit_key_ids)) THEN
    RETURN jsonb_build_object('error', 'forbidden', 'detail', 'this key may not set the automatic buy loss limits');
  END IF;
  IF jsonb_typeof(p_body) IS DISTINCT FROM 'object'
     OR NOT (p_body ? 'default_max_cost_pct' OR p_body ? 'by_marketplace')
     OR (p_body ? 'by_marketplace' AND jsonb_typeof(p_body->'by_marketplace') <> 'object') THEN
    RETURN jsonb_build_object('error', 'invalid',
      'detail', 'send {"default_max_cost_pct": 100-200 or null, "by_marketplace": {"<marketplace>": 100-200 or null}}');
  END IF;
  FOR r IN
    SELECT '*' AS k, p_body->'default_max_cost_pct' AS v WHERE p_body ? 'default_max_cost_pct'
    UNION ALL
    SELECT e.key, e.value FROM jsonb_each(coalesce(p_body->'by_marketplace', '{}'::jsonb)) e
  LOOP
    v_site := CASE WHEN r.k = '*' THEN '*' ELSE public.sub_finder_site_norm(r.k) END;
    IF v_site IS NULL OR (r.k <> '*' AND v_site = '*') THEN
      RETURN jsonb_build_object('error', 'invalid', 'detail', 'not a marketplace name: ' || r.k);
    END IF;
    IF jsonb_typeof(r.v) = 'null' THEN
      v_set := v_set || jsonb_build_object(v_site, NULL);
    ELSIF jsonb_typeof(r.v) = 'number' AND (r.v)::text::numeric BETWEEN 100 AND 200 THEN
      v_set := v_set || jsonb_build_object(v_site, round((r.v)::text::numeric, 2));
    ELSE
      RETURN jsonb_build_object('error', 'invalid',
        'detail', 'the limit for ' || r.k || ' must be a number from 100 to 200 (percent of the sale total), or null');
    END IF;
  END LOOP;
  FOR r IN SELECT e.key AS site, CASE WHEN jsonb_typeof(e.value) = 'null' THEN NULL ELSE (e.value)::text::numeric END AS pct
             FROM jsonb_each(v_set) e
  LOOP
    INSERT INTO public.sub_finder_loss_limit_log (key_id, set_by, site, old_pct, new_pct)
    VALUES (p_key_id, v_by, r.site, (SELECT l.max_cost_pct FROM public.sub_finder_loss_limit l WHERE l.site = r.site), r.pct);
    INSERT INTO public.sub_finder_loss_limit (site, max_cost_pct, set_by, set_at)
    VALUES (r.site, r.pct, v_by, now())
    ON CONFLICT (site) DO UPDATE SET max_cost_pct = excluded.max_cost_pct, set_by = excluded.set_by, set_at = now();
  END LOOP;
  RETURN public.sub_finder_loss_limits(p_key_id);
END
$function$

