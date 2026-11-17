CREATE OR REPLACE FUNCTION public.sub_finder_lookup_best(p_order text, p_site text DEFAULT NULL::text)
 RETURNS TABLE(book text, site text, tevo_event_id bigint, event_name text, event_date date, venue text, section text, seat_row text, qty integer, sold_ea numeric)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  WITH l AS MATERIALIZED (SELECT * FROM public.sub_finder_lookup(p_order)),
  hint AS (SELECT coalesce(public.sub_finder_site_norm(p_site),
                           (SELECT public.sub_finder_site_norm(x.site) FROM l x WHERE x.book <> 'api'
                             ORDER BY x.rnk, x.pulled_at DESC NULLS LAST LIMIT 1)) AS h),
  ok AS (
    -- a marketplace-feed row only on the marketplace we were told (or the CRM gives) for this
    -- number; with no such hint, only when a single feed holds the number
    SELECT l.* FROM l, hint
     WHERE l.book <> 'api'
        OR CASE WHEN hint.h IS NOT NULL THEN public.sub_finder_site_norm(l.site) = hint.h
                ELSE (SELECT count(DISTINCT y.site) FROM l y WHERE y.book = 'api') = 1 END),
  top AS (SELECT * FROM ok WHERE ok.section IS NOT NULL AND ok.seat_row IS NOT NULL AND ok.qty IS NOT NULL
           ORDER BY ok.rnk, ok.pulled_at DESC NULLS LAST LIMIT 1),
  same AS (SELECT ok.* FROM ok, top
            WHERE public.seat_section_norm(ok.section) = public.seat_section_norm(top.section)
              AND upper(btrim(ok.seat_row)) = upper(btrim(top.seat_row)) AND ok.qty = top.qty)
  SELECT top.book, top.site,
         (SELECT s.tevo_event_id FROM same s WHERE s.tevo_event_id IS NOT NULL ORDER BY s.rnk, s.pulled_at DESC NULLS LAST LIMIT 1),
         (SELECT s.event_name FROM same s WHERE s.event_name IS NOT NULL ORDER BY s.rnk, s.pulled_at DESC NULLS LAST LIMIT 1),
         (SELECT s.event_date FROM same s WHERE s.event_date IS NOT NULL ORDER BY s.rnk, s.pulled_at DESC NULLS LAST LIMIT 1),
         (SELECT s.venue FROM same s WHERE s.venue IS NOT NULL ORDER BY s.rnk, s.pulled_at DESC NULLS LAST LIMIT 1),
         top.section, top.seat_row, top.qty,
         (SELECT s.sold_ea FROM same s WHERE s.sold_ea IS NOT NULL ORDER BY s.rnk, s.pulled_at DESC NULLS LAST LIMIT 1)
  FROM top;
$function$

