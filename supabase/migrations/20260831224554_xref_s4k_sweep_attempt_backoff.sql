-- Migration 20260831224554 · reconstructed from prod · writes: see body
--
-- Recorded 2026-11-17 (branch triage): applied on prod as "xref_s4k_sweep_attempt_backoff" (version 20260831224554) but present in no
-- file in git. Body is prod's own supabase_migrations.schema_migrations.statements for that row,
-- statements separated by ';'. Recording only — it is already applied; do not re-apply.


-- ============================================================================
-- Migration 20260831260400 — S4K sweep: never-tried-first + attempt backoff
-- Lane:     xref+macro
-- Touches:  s4k_marketplace_orders (W)
-- Pre-reqs: 20260831260300
--
-- The sibling order sweeps re-select on `aq_short_event_id IS NULL` and so
-- re-try every unmatched row on every run. Those tables are small (2.5k-7k
-- rows); S4K is 22,442 orders across ~6,000 event groups, most of which can
-- never match because the event is absent from our catalogue entirely. Left
-- as-is, each cron tick would re-run the full matcher over thousands of
-- hopeless groups -- ~25ms each on the fall-through path.
--
-- So record attempts and order never-tried-first, the same convention
-- aq_tevo_search_candidates uses for the cold-search selector
-- (PROJECT_BIBLE §4). A group that has never been tried is always picked
-- before one that has; among tried ones the stalest goes first. New orders
-- landing from the twice-hourly pull are therefore matched promptly even
-- when a large hopeless backlog exists.
-- ============================================================================

ALTER TABLE public.s4k_marketplace_orders
  ADD COLUMN IF NOT EXISTS map_attempts         integer NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS map_last_attempt_at  timestamptz;

CREATE INDEX IF NOT EXISTS s4k_orders_map_attempt_idx
  ON public.s4k_marketplace_orders (map_attempts, map_last_attempt_at)
  WHERE aq_short_event_id IS NULL;

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
    SELECT source, event_name, venue_name, event_date,
           min(map_attempts) AS attempts,
           min(map_last_attempt_at) AS last_try
      FROM public.s4k_marketplace_orders
     WHERE aq_short_event_id IS NULL
       AND event_date IS NOT NULL
       AND coalesce(event_name,'') <> ''
     GROUP BY source, event_name, venue_name, event_date
     -- never-tried first, then stalest
     ORDER BY min(map_attempts), min(map_last_attempt_at) NULLS FIRST
     LIMIT p_max
  LOOP
    v_ex := v_ex + 1; v_aq := NULL; v_conf := NULL; v_meth := NULL;

    SELECT m.aq_short_event_id, m.confidence, m.match_method
      INTO v_aq, v_conf, v_meth
      FROM public.s4k_match_to_aq_event_id(r.source, r.event_name, r.venue_name, r.event_date) m
     LIMIT 1;

    IF v_aq IS NULL THEN
      -- record the miss so the next tick moves on to fresher work
      UPDATE public.s4k_marketplace_orders o
         SET map_attempts = o.map_attempts + 1, map_last_attempt_at = now()
       WHERE o.source = r.source
         AND o.event_name IS NOT DISTINCT FROM r.event_name
         AND o.venue_name IS NOT DISTINCT FROM r.venue_name
         AND o.event_date = r.event_date
         AND o.aq_short_event_id IS NULL;
      CONTINUE;
    END IF;

    SELECT a.venue_short_id, a.performer_short_id INTO v_vs, v_ps
      FROM public.aq_event_map a WHERE a.aq_short_event_id = v_aq LIMIT 1;

    UPDATE public.s4k_marketplace_orders o
       SET aq_short_event_id  = v_aq,
           venue_short_id     = coalesce(o.venue_short_id, v_vs),
           performer_short_id = coalesce(o.performer_short_id, v_ps),
           map_method         = v_meth,
           map_confidence     = v_conf,
           mapped_at          = now(),
           map_attempts       = o.map_attempts + 1,
           map_last_attempt_at = now()
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
