-- ============================================================================
-- Migration 20260911214000 — event_mapper_run(): shadow replay throttled to once per 30 min per surface
-- Migration 20260911214000 · level:data-collection · lane:A1 · writes:(none — function body only)
--
-- Lane:     A1 (data plane)
-- Touches:  event_mapper_run() (REPLACE — identical to mig 20260911210000 except the shadow gate)
-- Pre-reqs: 20260911210000
--
-- Already applied to prod · via MCP 2026-09-11 under operator direction (same session as the
-- 200000/200100/210000 apply; protects the shadow log from the per-minute N2S job).
--
-- First live shadow hour: n2s_map_events_5min runs every minute and each run replayed the same
-- ~336 open items → 336 shadow rows per minute. A dry run needs one verdict per row per while,
-- not one per tick: the replay now runs only when the surface has no shadow row younger than
-- 30 minutes. Legacy mappers still run every tick as before.
--
-- ROLLBACK: re-apply event_mapper_run from mig 20260911210000.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.event_mapper_run(p_surface text, p_horizon_days int DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $fn$
DECLARE
  v_mode text; v_legacy jsonb := NULL; v_keys text[]; v_sel text; v_n int := 0;
  v_agree int := 0; v_dis int := 0; v_ronly int := 0; v_lonly int := 0;
BEGIN
  IF current_user NOT IN ('service_role', 'postgres', 'supabase_admin') THEN
    RAISE EXCEPTION 'forbidden: %', current_user USING ERRCODE = '42501';
  END IF;
  PERFORM set_config('statement_timeout', '170000', true);
  SELECT mode INTO v_mode FROM public.event_mapper_switch WHERE surface = p_surface;
  v_mode := coalesce(v_mode, 'shadow');

  IF v_mode = 'live' THEN
    SELECT count(*) INTO v_n FROM public.event_mapper_map_surface(p_surface, true, 2000) m WHERE m.tevo_event_id IS NOT NULL;
    RETURN jsonb_build_object('surface', p_surface, 'mode', v_mode, 'mapped', v_n);
  END IF;

  -- Snapshot the unmapped keys the legacy mapper is about to see (bounded), so shadow can replay them.
  SELECT s.select_sql INTO v_sel FROM public.event_mapper_surface_sql(p_surface, coalesce(p_horizon_days, 180)) s;
  -- Shadow replay at most every 30 min per surface: the N2S job fires every minute and would
  -- otherwise re-log the same open rows each time (336 rows/min on the first live hour).
  IF v_mode = 'shadow' AND NOT EXISTS (SELECT 1 FROM public.event_mapper_shadow_log l
                                        WHERE l.surface = p_surface AND l.at > now() - interval '30 minutes') THEN
    EXECUTE format('SELECT coalesce(array_agg(q.row_key), ''{}''::text[]) FROM (SELECT row_key FROM (%s) q WHERE q.previous IS NULL ORDER BY q.ord DESC NULLS LAST LIMIT 2000) q', v_sel) INTO v_keys;
  END IF;

  -- The legacy mapper, exactly as its cron called it.
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

  IF v_mode = 'shadow' AND coalesce(array_length(v_keys, 1), 0) > 0 THEN
    -- Replay the same rows through the resolver (identity OFF — the hub must not answer for
    -- what the legacy mapper just wrote) and log the verdict; write nothing.
    -- m.previous is the value AFTER the legacy mapper ran (the key set was snapshotted before).
    INSERT INTO public.event_mapper_shadow_log (surface, row_key, legacy_tevo, resolver_tevo, method, score, verdict)
    SELECT p_surface, m.row_key, m.previous, m.tevo_event_id, m.method, m.score,
           CASE WHEN m.previous IS NOT NULL AND m.tevo_event_id = m.previous THEN 'agree'
                WHEN m.previous IS NOT NULL AND m.tevo_event_id IS NOT NULL  THEN 'disagree'
                WHEN m.previous IS NULL     AND m.tevo_event_id IS NOT NULL  THEN 'resolver_only'
                ELSE 'legacy_only' END
      FROM public.event_mapper_map_surface(p_surface, false, 2000, v_keys) m
     WHERE m.previous IS NOT NULL OR m.tevo_event_id IS NOT NULL;
    SELECT count(*) FILTER (WHERE verdict = 'agree'), count(*) FILTER (WHERE verdict = 'disagree'),
           count(*) FILTER (WHERE verdict = 'resolver_only'), count(*) FILTER (WHERE verdict = 'legacy_only')
      INTO v_agree, v_dis, v_ronly, v_lonly
      FROM public.event_mapper_shadow_log WHERE surface = p_surface AND at > now() - interval '1 minute';
  END IF;

  RETURN jsonb_build_object('surface', p_surface, 'mode', v_mode, 'legacy', v_legacy,
                            'shadow', jsonb_build_object('replayed', coalesce(array_length(v_keys, 1), 0), 'agree', v_agree,
                                                         'disagree', v_dis, 'resolver_only', v_ronly, 'legacy_only', v_lonly));
END $fn$;
REVOKE ALL ON FUNCTION public.event_mapper_run(text, int) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.event_mapper_run(text, int) TO service_role;
COMMENT ON FUNCTION public.event_mapper_run(text, int) IS
  'The ONE mapper entry point every cron calls. Dispatches on event_mapper_switch.mode: legacy → old mapper; shadow → old mapper writes + resolver replay logged (dry run); live → resolver writes + cross-maps. A1 mig 20260911210000; 30-min shadow throttle mig 20260911214000.';

