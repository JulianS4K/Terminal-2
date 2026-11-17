-- Migration 20260831224850 · reconstructed from prod · writes: see body
--
-- Recorded 2026-11-17 (branch triage): applied on prod as "xref_s4k_sweep_pass_venue_city_state" (version 20260831224850) but present in no
-- file in git. Body is prod's own supabase_migrations.schema_migrations.statements for that row,
-- statements separated by ';'. Recording only — it is already applied; do not re-apply.


-- ============================================================================
-- Migration 20260831260700 — S4K sweep passes venue city/state to the matcher
-- Lane:     xref+macro
-- Touches:  s4k_marketplace_orders (W)
-- Pre-reqs: 20260831260600
--
-- s4k_match_to_aq_event_id gained p_venue_city/p_venue_state for the venue-id
-- tier (cross_source_venue_resolve). The sweep groups by them so each distinct
-- venue spelling resolves independently.
--
-- Also clears map_attempts: every group attempted under the pre-1b/1c matcher
-- was judged by a strictly weaker rule set, so those misses are stale and must
-- be re-offered rather than aged to the back of the queue.
-- ============================================================================

UPDATE public.s4k_marketplace_orders
   SET map_attempts = 0, map_last_attempt_at = NULL
 WHERE aq_short_event_id IS NULL AND map_attempts > 0;

CREATE OR REPLACE FUNCTION public.s4k_orders_match_sweep(p_max integer DEFAULT 5000)
RETURNS TABLE(table_name text, groups_examined integer, groups_matched integer,
              rows_stamped integer, groups_unmatched integer)
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
DECLARE
  r RECORD; v_aq text; v_conf numeric; v_meth text; v_vs text; v_ps text;
  v_ex integer := 0; v_m integer := 0; v_rows integer := 0; v_n integer;
BEGIN
  IF current_user NOT IN ('service_role','postgres','supabase_admin') THEN
    RAISE EXCEPTION 's4k_orders_match_sweep: caller % not authorized', current_user;
  END IF;

  FOR r IN
    SELECT source, event_name, venue_name, venue_city, venue_state, event_date
      FROM public.s4k_marketplace_orders
     WHERE aq_short_event_id IS NULL
       AND event_date IS NOT NULL
       AND coalesce(event_name,'') <> ''
     GROUP BY source, event_name, venue_name, venue_city, venue_state, event_date
     ORDER BY min(map_attempts), min(map_last_attempt_at) NULLS FIRST
     LIMIT p_max
  LOOP
    v_ex := v_ex + 1; v_aq := NULL; v_conf := NULL; v_meth := NULL;

    SELECT m.aq_short_event_id, m.confidence, m.match_method
      INTO v_aq, v_conf, v_meth
      FROM public.s4k_match_to_aq_event_id(
             r.source, r.event_name, r.venue_name, r.event_date,
             r.venue_city, r.venue_state) m
     LIMIT 1;

    IF v_aq IS NULL THEN
      UPDATE public.s4k_marketplace_orders o
         SET map_attempts = o.map_attempts + 1, map_last_attempt_at = now()
       WHERE o.source = r.source
         AND o.event_name IS NOT DISTINCT FROM r.event_name
         AND o.venue_name IS NOT DISTINCT FROM r.venue_name
         AND o.venue_city IS NOT DISTINCT FROM r.venue_city
         AND o.venue_state IS NOT DISTINCT FROM r.venue_state
         AND o.event_date = r.event_date
         AND o.aq_short_event_id IS NULL;
      CONTINUE;
    END IF;

    SELECT a.venue_short_id, a.performer_short_id INTO v_vs, v_ps
      FROM public.aq_event_map a WHERE a.aq_short_event_id = v_aq LIMIT 1;

    UPDATE public.s4k_marketplace_orders o
       SET aq_short_event_id   = v_aq,
           venue_short_id      = coalesce(o.venue_short_id, v_vs),
           performer_short_id  = coalesce(o.performer_short_id, v_ps),
           map_method          = v_meth,
           map_confidence      = v_conf,
           mapped_at           = now(),
           map_attempts        = o.map_attempts + 1,
           map_last_attempt_at = now()
     WHERE o.source = r.source
       AND o.event_name IS NOT DISTINCT FROM r.event_name
       AND o.venue_name IS NOT DISTINCT FROM r.venue_name
       AND o.venue_city IS NOT DISTINCT FROM r.venue_city
       AND o.venue_state IS NOT DISTINCT FROM r.venue_state
       AND o.event_date = r.event_date
       AND o.aq_short_event_id IS NULL;
    GET DIAGNOSTICS v_n = ROW_COUNT;

    v_m := v_m + 1; v_rows := v_rows + v_n;
  END LOOP;

  RETURN QUERY SELECT 's4k_marketplace_orders'::text, v_ex, v_m, v_rows, v_ex - v_m;
END;
$function$;

REVOKE ALL ON FUNCTION public.s4k_orders_match_sweep(integer) FROM PUBLIC, anon, authenticated;
;
