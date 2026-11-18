-- Migration 20260831221129 · reconstructed from prod · writes: see body
--
-- Recorded 2026-11-17 (branch triage): applied on prod as "s4k_orders_map_events_grouped" (version 20260831221129) but present in no
-- file in git. Body is prod's own supabase_migrations.schema_migrations.statements for that row,
-- statements separated by ';'. Recording only — it is already applied; do not re-apply.


CREATE OR REPLACE FUNCTION public.s4k_orders_map_events(p_max integer DEFAULT 5000)
RETURNS TABLE(tier text, mapped integer)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE n1 int := 0; n2 int := 0;
BEGIN
  IF current_user NOT IN ('service_role','postgres','supabase_admin') THEN
    RAISE EXCEPTION 's4k_orders_map_events: caller % not authorized', current_user;
  END IF;

  WITH cand AS (
    SELECT o.source, o.order_id, min(e.id) AS ev, count(*) AS n
      FROM public.s4k_marketplace_orders o
      JOIN public.events e
        ON lower(regexp_replace(coalesce(e.venue_name,''), '[^a-z0-9]+','','gi'))
         = lower(regexp_replace(coalesce(o.venue_name,''), '[^a-z0-9]+','','gi'))
       AND e.occurs_at_local IS NOT NULL
       AND left(e.occurs_at_local, 10) = ANY (ARRAY[
             to_char(o.event_date - 1, 'YYYY-MM-DD'),
             to_char(o.event_date,     'YYYY-MM-DD'),
             to_char(o.event_date + 1, 'YYYY-MM-DD')])
     WHERE o.tevo_event_id IS NULL
       AND coalesce(o.venue_name,'') <> ''
       AND o.event_date IS NOT NULL
     GROUP BY o.source, o.order_id
     LIMIT p_max
  )
  UPDATE public.s4k_marketplace_orders o
     SET tevo_event_id = c.ev, map_method = 'venue_date_v1',
         map_confidence = 0.90, mapped_at = now()
    FROM cand c
   WHERE o.source = c.source AND o.order_id = c.order_id
     AND o.tevo_event_id IS NULL AND c.n = 1;
  GET DIAGNOSTICS n1 = ROW_COUNT;
  tier := 'venue_date'; mapped := n1; RETURN NEXT;

  WITH cand AS (
    SELECT o.source, o.order_id, min(e.id) AS ev, count(*) AS n
      FROM public.s4k_marketplace_orders o
      JOIN public.events e
        ON e.occurs_at_local IS NOT NULL
       AND left(e.occurs_at_local, 10) = to_char(o.event_date, 'YYYY-MM-DD')
       AND EXISTS (
             SELECT 1
               FROM unnest(string_to_array(
                      lower(regexp_replace(coalesce(o.event_name,''), '[^a-z0-9 ]+',' ','gi')), ' ')) t(tok)
              WHERE length(t.tok) >= 5
                AND lower(coalesce(e.name,'')) LIKE '%' || t.tok || '%')
     WHERE o.tevo_event_id IS NULL
       AND o.event_date IS NOT NULL
       AND coalesce(o.event_name,'') <> ''
     GROUP BY o.source, o.order_id
     LIMIT p_max
  )
  UPDATE public.s4k_marketplace_orders o
     SET tevo_event_id = c.ev, map_method = 'name_date_v1',
         map_confidence = 0.70, mapped_at = now()
    FROM cand c
   WHERE o.source = c.source AND o.order_id = c.order_id
     AND o.tevo_event_id IS NULL AND c.n = 1;
  GET DIAGNOSTICS n2 = ROW_COUNT;
  tier := 'name_date'; mapped := n2; RETURN NEXT;
END $function$;

REVOKE ALL ON FUNCTION public.s4k_orders_map_events(integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.s4k_orders_map_events(integer) TO service_role;
;
