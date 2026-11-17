-- Migration 20260831224400 · reconstructed from prod · writes: see body
--
-- Recorded 2026-11-17 (branch triage): applied on prod as "xref_s4k_sweep_record_provenance" (version 20260831224400) but present in no
-- file in git. Body is prod's own supabase_migrations.schema_migrations.statements for that row,
-- statements separated by ';'. Recording only — it is already applied; do not re-apply.


-- ============================================================================
-- Migration 20260831260300 — S4K sweep records which tier matched
-- Lane:     xref+macro
-- Touches:  s4k_marketplace_orders (W)
-- Pre-reqs: 20260831260100
--
-- The sibling blocks in match_unmatched_orders_sweep discard the matcher's
-- confidence/method and keep only the hub key. S4K already carries map_method
-- and map_confidence columns (freed when the interim bespoke mapping was
-- cleared), so record them: it makes every stamp auditable by tier without a
-- second pass, which is the whole reason that column was cleared rather than
-- left mixed. tevo_event_id is deliberately NOT set here -- it stays NULL
-- until backfill_order_tevo_from_aq derives it from the hub (PROJECT_BIBLE §5).
-- ============================================================================

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
    SELECT source, event_name, venue_name, event_date
      FROM public.s4k_marketplace_orders
     WHERE aq_short_event_id IS NULL
       AND event_date IS NOT NULL
       AND coalesce(event_name,'') <> ''
     GROUP BY source, event_name, venue_name, event_date
     LIMIT p_max
  LOOP
    v_ex := v_ex + 1; v_aq := NULL; v_conf := NULL; v_meth := NULL;

    SELECT m.aq_short_event_id, m.confidence, m.match_method
      INTO v_aq, v_conf, v_meth
      FROM public.s4k_match_to_aq_event_id(r.source, r.event_name, r.venue_name, r.event_date) m
     LIMIT 1;

    CONTINUE WHEN v_aq IS NULL;

    SELECT a.venue_short_id, a.performer_short_id INTO v_vs, v_ps
      FROM public.aq_event_map a WHERE a.aq_short_event_id = v_aq LIMIT 1;

    UPDATE public.s4k_marketplace_orders o
       SET aq_short_event_id  = v_aq,
           venue_short_id     = coalesce(o.venue_short_id, v_vs),
           performer_short_id = coalesce(o.performer_short_id, v_ps),
           map_method         = v_meth,
           map_confidence     = v_conf,
           mapped_at          = now()
     WHERE o.source = r.source
       AND o.event_name IS NOT DISTINCT FROM r.event_name
       AND o.venue_name IS NOT DISTINCT FROM r.venue_name
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
