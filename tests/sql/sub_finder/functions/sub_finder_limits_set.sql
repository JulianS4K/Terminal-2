CREATE OR REPLACE FUNCTION public.sub_finder_limits_set(p_key_id bigint, p_key_label text, p_body jsonb, p_by text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  a     jsonb := public.sub_finder_access(p_key_id);
  v_by  text := 'crm api key ' || coalesce(p_key_label, p_key_id::text) || coalesce(' / ' || nullif(btrim(p_by), ''), '');
  v_set jsonb := '[]'::jsonb;        -- [{kind, site, pct}], validated
  k     record;
  r     record;
  v_one jsonb;
  v_site text;
  v_hint constant text := 'send {"rebate_max_pct": {"default": 0-100 or null, "by_marketplace": {"<marketplace>": 0-100 or null}}, '
                          || '"buy_max_cost_pct": {"default": 1-1000 or null, "by_marketplace": {...}}}; either may be left out';
BEGIN
  IF NOT (coalesce((a->>'find')::boolean, false)
          AND (coalesce((a->>'buy')::boolean, false) OR coalesce((a->>'offer')::boolean, false))) THEN
    RETURN jsonb_build_object('error', 'forbidden', 'detail', 'this key may not set limits');
  END IF;
  IF jsonb_typeof(p_body) IS DISTINCT FROM 'object' OR NOT (p_body ? 'rebate_max_pct' OR p_body ? 'buy_max_cost_pct') THEN
    RETURN jsonb_build_object('error', 'invalid', 'detail', v_hint);
  END IF;
  FOR k IN SELECT * FROM (VALUES ('rebate_max_pct', 'rebate_max', 0, 100), ('buy_max_cost_pct', 'buy_max_cost', 1, 1000)) v(field, kind, lo, hi)
            WHERE p_body ? v.field
  LOOP
    v_one := p_body->k.field;
    IF jsonb_typeof(v_one) <> 'object' OR NOT (v_one ? 'default' OR v_one ? 'by_marketplace')
       OR (v_one ? 'by_marketplace' AND jsonb_typeof(v_one->'by_marketplace') <> 'object') THEN
      RETURN jsonb_build_object('error', 'invalid', 'detail', k.field || ': ' || v_hint);
    END IF;
    FOR r IN
      SELECT '*' AS name, v_one->'default' AS v WHERE v_one ? 'default'
      UNION ALL
      SELECT e.key, e.value FROM jsonb_each(coalesce(v_one->'by_marketplace', '{}'::jsonb)) e
    LOOP
      v_site := CASE WHEN r.name = '*' THEN '*' ELSE public.sub_finder_site_norm(r.name) END;
      IF v_site IS NULL OR (r.name <> '*' AND v_site = '*') THEN
        RETURN jsonb_build_object('error', 'invalid', 'detail', k.field || ': not a marketplace name: ' || r.name);
      END IF;
      IF jsonb_typeof(r.v) = 'null' THEN
        v_set := v_set || jsonb_build_object('kind', k.kind, 'site', v_site, 'pct', NULL);
      ELSIF jsonb_typeof(r.v) = 'number' AND (r.v)::text::numeric BETWEEN k.lo AND k.hi THEN
        v_set := v_set || jsonb_build_object('kind', k.kind, 'site', v_site, 'pct', round((r.v)::text::numeric, 2));
      ELSE
        RETURN jsonb_build_object('error', 'invalid',
          'detail', k.field || ' for ' || CASE WHEN r.name = '*' THEN 'the default' ELSE r.name END
                    || ' must be a number from ' || k.lo || ' to ' || k.hi || ' (percent of the sale total), or null');
      END IF;
    END LOOP;
  END LOOP;
  FOR r IN SELECT e->>'kind' AS kind, e->>'site' AS site,
                  CASE WHEN jsonb_typeof(e->'pct') = 'null' THEN NULL ELSE (e->'pct')::text::numeric END AS pct
             FROM jsonb_array_elements(v_set) e
  LOOP
    INSERT INTO public.sub_finder_crm_limit_log (key_id, set_by, kind, site, old_pct, new_pct)
    VALUES (p_key_id, v_by, r.kind, r.site,
            (SELECT l.pct FROM public.sub_finder_crm_limit l WHERE l.kind = r.kind AND l.site = r.site), r.pct);
    INSERT INTO public.sub_finder_crm_limit (kind, site, pct, set_by, set_at)
    VALUES (r.kind, r.site, r.pct, v_by, now())
    ON CONFLICT (kind, site) DO UPDATE SET pct = excluded.pct, set_by = excluded.set_by, set_at = now();
  END LOOP;
  RETURN public.sub_finder_limits(p_key_id);
END
$function$

