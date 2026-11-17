-- Migration 20260831225618 · reconstructed from prod · writes: see body
--
-- Recorded 2026-11-17 (branch triage): applied on prod as "xref_s4k_sweep_synthetic_hub_rows" (version 20260831225618) but present in no
-- file in git. Body is prod's own supabase_migrations.schema_migrations.statements for that row,
-- statements separated by ';'. Recording only — it is already applied; do not re-apply.


-- ============================================================================
-- Migration 20260831261000 — S4K sweep: synthetic hub rows for full coverage
-- Lane:     xref+macro
-- Touches:  s4k_marketplace_orders (W), aq_event_map (W via create_system_aq_event)
-- Pre-reqs: 20260831260900
--
-- Operator directive 2026-08-31 ("map till 100%") supersedes the earlier
-- stamp-only choice. The seven matching tiers are exhausted at ~74% of orders;
-- the residue names events that have no row in `events` at all (the table is a
-- tracked subset, 15,881 rows / 8,931 future -- overwhelmingly college
-- football). No matcher can reach them, so the only route to full hub-key
-- coverage is the house fallback the vivid / tickpick / seatgeek blocks of
-- match_unmatched_orders_sweep already use: create_system_aq_event.
--
-- What that buys and what it does not:
--   * aq_short_event_id reaches 100% -- every order becomes joinable on the
--     canonical key and stops being invisible to hub-keyed views.
--   * tevo_event_id does NOT. A synthetic row has no TEvo event behind it, so
--     it stays NULL until the event enters our catalogue. That is a catalogue
--     limit, not a matcher limit, and the honest number to quote.
--
-- The synthetic id is md5(name|venue|date-to-minute), so the same event sold
-- on StubHub and SeatGeek collapses to ONE hub row rather than six, and the
-- insert is ON CONFLICT DO NOTHING -- re-running mints nothing new.
--
-- Rows land with aq_source='system_seed', which is the documented marker for
-- exactly this: seeded rows awaiting a real cross-source link. The existing
-- resolve_aq_tevo_from_sources() / link_aq_tevo_from_events() crons and the
-- TEvo cold-search bridge (aq_tevo_search_candidates) will fill their
-- tevo_event_id as those events appear -- which is the "prevent this next
-- time" mechanism: the work is recorded in the hub, once, for every source.
--
-- Cross-lane: aq_event_map is the shared AQ hub (A1 surface). Written here
-- through the canonical creator only -- never directly. Flagged to bot_chat.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.s4k_orders_match_sweep(
  p_max integer DEFAULT 5000,
  p_create_synthetic boolean DEFAULT true)
RETURNS TABLE(table_name text, groups_examined integer, groups_matched integer,
              groups_synthetic integer, rows_stamped integer, groups_unmatched integer)
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
DECLARE
  r RECORD; v_aq text; v_conf numeric; v_meth text; v_vs text; v_ps text;
  v_ex integer := 0; v_m integer := 0; v_syn integer := 0;
  v_rows integer := 0; v_n integer;
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

    IF v_aq IS NULL AND p_create_synthetic THEN
      v_aq := public.create_system_aq_event(
                lower(replace(r.source, ' ', '')),
                r.event_name,
                nullif(r.venue_name, ''),
                r.event_date::timestamptz);
      v_conf := 0.50; v_meth := 's4k_system_seed';
      v_syn := v_syn + 1;
    END IF;

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

  RETURN QUERY SELECT 's4k_marketplace_orders'::text, v_ex, v_m - v_syn, v_syn, v_rows, v_ex - v_m;
END;
$function$;

DROP FUNCTION IF EXISTS public.s4k_orders_match_sweep(integer);
REVOKE ALL ON FUNCTION public.s4k_orders_match_sweep(integer, boolean) FROM PUBLIC, anon, authenticated;
;
