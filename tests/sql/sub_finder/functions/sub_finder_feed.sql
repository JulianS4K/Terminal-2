CREATE OR REPLACE FUNCTION public.sub_finder_feed(p_key_id bigint, p_updated_since timestamp with time zone DEFAULT NULL::timestamp with time zone, p_limit integer DEFAULT 200, p_offset integer DEFAULT 0, p_scope text DEFAULT 'n2s'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_now   timestamptz := now();
  v_limit integer := least(greatest(coalesce(p_limit, 200), 1), 1000);
  v_off   integer := greatest(coalesce(p_offset, 0), 0);
  v_scope text := coalesce(p_scope, 'n2s');
  r       record;
BEGIN
  IF NOT coalesce((public.sub_finder_access(p_key_id)->>'find')::boolean, false) THEN
    RETURN jsonb_build_object('error', 'forbidden', 'detail', 'this key may not use the sub finder');
  END IF;
  IF v_scope NOT IN ('n2s', 'all') THEN
    RETURN jsonb_build_object('error', 'invalid', 'detail', 'scope must be n2s or all');
  END IF;
  -- settle this key's open jobs first, so a caller that only ever syncs still gets answers
  FOR r IN SELECT job_id FROM public.sub_finder_job
            WHERE key_id = p_key_id AND status <> 'done' AND NOT public.sub_finder_bg_settle() LOOP
    PERFORM public.sub_finder_settle(r.job_id);
  END LOOP;
  RETURN (
    WITH base AS (
      SELECT o, public.sub_finder_n2s_window(o.order_number) AS w,
             -- a purchase or an offer the caller is still following: not final, or final this week
             (EXISTS (SELECT 1 FROM public.manual_sub_buy b
                       WHERE b.buy_id = o.buy_id AND (b.final_at IS NULL OR b.final_at > v_now - interval '7 days'))
              OR EXISTS (SELECT 1 FROM public.sub_finder_gt_offer g
                          WHERE g.job_id = o.job_id AND g.idx = o.idx
                            AND (g.final_at IS NULL OR g.final_at > v_now - interval '7 days'))) AS acted
        FROM public.sub_finder_order o
       WHERE o.key_id = p_key_id AND o.state <> 'pending'
    ), ranked AS (
      -- one row per order: the lookup with the purchase or offer, else the watched one, else the newest
      SELECT b.*, row_number() OVER (PARTITION BY (b.o).order_number
                                     ORDER BY b.acted DESC, (b.o).watching DESC, (b.o).updated_at DESC,
                                              (b.o).job_id, (b.o).idx) AS rn
        FROM base b
    ), f AS (
      SELECT k.* FROM ranked k
       WHERE (p_updated_since IS NULL OR (k.o).updated_at >= p_updated_since)
         AND (v_scope = 'all'
              OR (k.rn = 1 AND (k.acted OR ((k.o).watching AND coalesce((k.w->>'in_window')::boolean, false)))))
    ), page AS (
      SELECT * FROM f ORDER BY (f.o).updated_at, (f.o).job_id, (f.o).idx LIMIT v_limit OFFSET v_off
    )
    SELECT jsonb_build_object(
      'count', (SELECT count(*) FROM page), 'total', (SELECT count(*) FROM f),
      'limit', v_limit, 'offset', v_off, 'scope', v_scope,
      'items', (SELECT coalesce(jsonb_agg(public.sub_finder_order_json(p.o)
                                          || jsonb_build_object('n2s', p.w - 'in_window')
                                          ORDER BY (p.o).updated_at, (p.o).job_id, (p.o).idx),
                                '[]'::jsonb) FROM page p),
      'generated_at', to_char(v_now AT TIME ZONE 'utc', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"')));
END
$function$

