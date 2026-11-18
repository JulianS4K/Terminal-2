-- Migration 20260831221255 · reconstructed from prod · writes: see body
--
-- Recorded 2026-11-17 (branch triage): applied on prod as "s4k_orders_map_events_tightened" (version 20260831221255) but present in no
-- file in git. Body is prod's own supabase_migrations.schema_migrations.statements for that row,
-- statements separated by ';'. Recording only — it is already applied; do not re-apply.


-- v2 of the mapper. v1 produced roughly 1 bad link in 6 on a 12-row sample:
--
--   name tier : "Missouri Tigers vs. Kentucky Wildcats" (Faurot Field) matched
--               "Samford Bulldogs at Auburn Tigers Football" (Jordan Hare) --
--               a single shared token, "tigers", is not evidence of identity.
--   venue tier: "Squeeze with Adam Ant" at Hollywood Bowl 2026-09-19 matched a
--               DIFFERENT Hollywood Bowl show on 09-20 -- the +/-1 day window
--               collapses adjacent nights at a busy venue.
--
-- v2: the venue tier requires the local dates to be EQUAL (both sides already
-- carry a local date, so the tolerance bought nothing but false links), and the
-- name tier requires a token OVERLAP RATIO >= 0.6 over tokens of >= 4 chars
-- rather than any one shared token. Under that rule the two failures above are
-- rejected (1/4 = 0.25) while "Mac DeMarco", "Billy Strings" and
-- "Houston Astros at Philadelphia Phillies" all still match at ratio 1.0.
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
       AND left(e.occurs_at_local, 10) = to_char(o.event_date, 'YYYY-MM-DD')
     WHERE o.tevo_event_id IS NULL
       AND coalesce(o.venue_name,'') <> ''
       AND o.event_date IS NOT NULL
     GROUP BY o.source, o.order_id
     LIMIT p_max
  )
  UPDATE public.s4k_marketplace_orders o
     SET tevo_event_id = c.ev, map_method = 'venue_date_v2',
         map_confidence = 0.90, mapped_at = now()
    FROM cand c
   WHERE o.source = c.source AND o.order_id = c.order_id
     AND o.tevo_event_id IS NULL AND c.n = 1;
  GET DIAGNOSTICS n1 = ROW_COUNT;
  tier := 'venue_date'; mapped := n1; RETURN NEXT;

  WITH toks AS (
    SELECT o.source, o.order_id, o.event_date,
           array_agg(DISTINCT t.tok) AS s4k_toks
      FROM public.s4k_marketplace_orders o,
           unnest(string_to_array(
             lower(regexp_replace(coalesce(o.event_name,''), '[^a-z0-9 ]+',' ','gi')), ' ')) t(tok)
     WHERE o.tevo_event_id IS NULL
       AND o.event_date IS NOT NULL
       AND coalesce(o.event_name,'') <> ''
       AND length(t.tok) >= 4
     GROUP BY o.source, o.order_id, o.event_date
     LIMIT p_max
  ),
  cand AS (
    SELECT k.source, k.order_id, min(e.id) AS ev, count(*) AS n
      FROM toks k
      JOIN public.events e
        ON e.occurs_at_local IS NOT NULL
       AND left(e.occurs_at_local, 10) = to_char(k.event_date, 'YYYY-MM-DD')
       AND (SELECT count(*) FROM unnest(k.s4k_toks) x(tok)
             WHERE lower(coalesce(e.name,'')) LIKE '%' || x.tok || '%')::numeric
           / nullif(array_length(k.s4k_toks, 1), 0) >= 0.6
     GROUP BY k.source, k.order_id
  )
  UPDATE public.s4k_marketplace_orders o
     SET tevo_event_id = c.ev, map_method = 'name_date_v2',
         map_confidence = 0.75, mapped_at = now()
    FROM cand c
   WHERE o.source = c.source AND o.order_id = c.order_id
     AND o.tevo_event_id IS NULL AND c.n = 1;
  GET DIAGNOSTICS n2 = ROW_COUNT;
  tier := 'name_date'; mapped := n2; RETURN NEXT;
END $function$;

REVOKE ALL ON FUNCTION public.s4k_orders_map_events(integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.s4k_orders_map_events(integer) TO service_role;
;
