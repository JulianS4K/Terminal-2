-- ============================================================================
-- Migration 20260911217000 — event_mapper_run(): live mode keeps the legacy mapper as a fill-only fallback per surface
-- Migration 20260911217000 · level:data-collection · lane:A1 · writes:event_mapper_switch
--
-- Lane:     A1 (data plane)
-- Touches:  event_mapper_switch (NEW column live_fallback), event_mapper_run() (REPLACE)
-- Pre-reqs: 20260911215000
--
-- Already applied to prod · via MCP 2026-09-11 under operator direction ("Apply and merge into prod and then begin mapping and crons").
--
-- The shadow dry run (event_mapper_shadow_tick) showed 0 disagreements on s4kcs / N2S / SG canonical
-- but a small legacy_only residue — rows the old mapper binds by name alone (three venue-less s4kcs
-- orders) or by the parking convention (an N2S "… Parking" row → the main event's tevo id, which is
-- how TEvo lists parking; the resolver declines parking on purpose). Flipping those surfaces to
-- live with resolver-only writes would lose that recall. So live mode is now: resolver first
-- (writes + cross-map, cap 400), then — when the surface's live_fallback is on — the legacy mapper
-- for whatever is still NULL. Every legacy mapper is fill-only on tevo_event_id, so the resolver's
-- picks always win; legacy only ever adds. gotickets_event keeps live_fallback OFF: its legacy
-- gt_map_events binds stale re-listed twins (3 disagreements in the first tick), which is exactly
-- what the resolver's liveness tie-break corrects.
--
-- ROLLBACK: re-apply event_mapper_run from 20260911215000; ALTER TABLE public.event_mapper_switch DROP COLUMN live_fallback;
-- ============================================================================

ALTER TABLE public.event_mapper_switch ADD COLUMN IF NOT EXISTS live_fallback boolean NOT NULL DEFAULT false;
COMMENT ON COLUMN public.event_mapper_switch.live_fallback IS
  'live mode only: after the resolver writes, also run the surface''s legacy mapper for rows still NULL (fill-only). mig 20260911217000';

UPDATE public.event_mapper_switch SET live_fallback = true
 WHERE surface IN ('s4kcs_orders', 'n2s_items', 'sg_events_canonical');

CREATE OR REPLACE FUNCTION public.event_mapper_run(p_surface text, p_horizon_days int DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $fn$
DECLARE
  v_mode text; v_fallback boolean := false; v_legacy jsonb := NULL; v_n int := 0; v_by jsonb := '{}'::jsonb;
BEGIN
  IF current_user NOT IN ('service_role', 'postgres', 'supabase_admin') THEN
    RAISE EXCEPTION 'forbidden: %', current_user USING ERRCODE = '42501';
  END IF;
  PERFORM set_config('statement_timeout', '170000', true);
  SELECT s.mode, s.live_fallback INTO v_mode, v_fallback FROM public.event_mapper_switch s WHERE s.surface = p_surface;
  v_mode := coalesce(v_mode, 'shadow');

  IF v_mode = 'live' THEN
    -- resolver first: bounded to the 400 newest unmapped rows per run (a 10-min / hourly cadence
    -- drains any backlog); writes fill-only + cross-maps (event_mapper_apply)
    SELECT count(*), coalesce(jsonb_object_agg(x.method, x.n), '{}'::jsonb) INTO v_n, v_by
      FROM (SELECT m.method, count(*) AS n FROM public.event_mapper_map_surface(p_surface, true, 400) m
             WHERE m.tevo_event_id IS NOT NULL GROUP BY m.method) x;
    IF NOT v_fallback THEN
      RETURN jsonb_build_object('surface', p_surface, 'mode', v_mode, 'mapped', v_n, 'by', v_by);
    END IF;
  END IF;

  -- legacy mapper: the whole job in legacy / shadow mode; the fill-only fallback for rows the
  -- resolver left NULL in live mode (mig 20260911217000). The shadow replay lives in
  -- event_mapper_shadow_tick(), which every cron calls in its OWN transaction, so a slow replay can
  -- never roll back a legacy write (2026-09-11 18:16: a 2000-key replay hit the 170 s cap and undid
  -- s4kcs_map_events' writes).
  CASE p_surface
    WHEN 's4kcs_orders'        THEN SELECT jsonb_agg(to_jsonb(t)) INTO v_legacy FROM public.s4kcs_map_events() t;
    WHEN 'n2s_items'           THEN SELECT jsonb_agg(to_jsonb(t)) INTO v_legacy FROM public.n2s_map_events(true) t;
    WHEN 'gotickets_event'     THEN
      v_legacy := jsonb_build_object('gt_map_events', public.gt_map_events(coalesce(p_horizon_days, 120)));
      IF p_horizon_days IS NOT NULL AND p_horizon_days > 180 THEN
        SELECT v_legacy || jsonb_build_object('match_gotickets_us_events', to_jsonb(t)) INTO v_legacy FROM public.match_gotickets_us_events(3000, p_horizon_days, 0.80, true) t;
      ELSE
        SELECT v_legacy || jsonb_build_object('match_gotickets_us_events', to_jsonb(t)) INTO v_legacy FROM public.match_gotickets_us_events(1500, 180, 0.80, true) t;
      END IF;
    WHEN 'sg_events_canonical' THEN SELECT to_jsonb(t) INTO v_legacy FROM public.auto_match_sg_canonical_v3() t;
    ELSE v_legacy := jsonb_build_object('legacy', 'none (AQ sweep :22 / backfill :40 own this surface)');
  END CASE;

  IF v_mode = 'live' THEN
    RETURN jsonb_build_object('surface', p_surface, 'mode', v_mode, 'mapped', v_n, 'by', v_by, 'legacy_fallback', v_legacy);
  END IF;
  RETURN jsonb_build_object('surface', p_surface, 'mode', v_mode, 'legacy', v_legacy,
                            'shadow', 'see event_mapper_shadow_tick(surface) - separate transaction');
END $fn$;
REVOKE ALL ON FUNCTION public.event_mapper_run(text, int) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.event_mapper_run(text, int) TO service_role;
COMMENT ON FUNCTION public.event_mapper_run(text, int) IS
  'The ONE mapper entry point every cron calls. Dispatches on event_mapper_switch.mode: legacy / shadow → old mapper only (the dry run is event_mapper_shadow_tick, own transaction); live → resolver writes + cross-maps (cap 400), then the old mapper as a fill-only fallback when live_fallback is on. A1 mig 20260911210000; reshaped 215000; live fallback 217000.';
