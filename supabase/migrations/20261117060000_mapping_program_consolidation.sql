-- Migration 20261117060000 · level:admin · lane:A1 (data plane — mapping program) · writes:hub_link_run(new),hub_link_tick()(new),cron:hub_link_hourly(new),cron:gt_map_events_hourly(command),cron.unschedule × 10 (gotickets_match_us_6h, gt_map_events_wide_daily, match_unmatched_orders_sweep_hourly, backfill-order-tevo-from-aq-hourly, resolve-aq-tevo-from-sources-hourly, resolve-aq-seatdata-link-hourly, aq_link_tevo_siblings_hourly, aq_link_tevo_from_events_hourly, aq_link_gotickets_catalogue_hourly, axs_aq_link_hourly),cron_policy(rows) · reads:cron.job · pre:20261117050000
--
-- MAPPING PROGRAM — CONSOLIDATION (operator 2026-11-17: "consolidate event matchers where it makes sense, then dry run").
-- Census the same day: 27 active matching / linking jobs. Two groups collapse without changing a single match rule.
--
-- UNIT 2 · THE GOTICKETS CATALOGUE WAS MAPPED BY THREE JOBS MAKING THE SAME CALL. gt_map_events_hourly (:32),
--   gotickets_match_us_6h (every 6 h) and gt_map_events_wide_daily (08:50, "horizon 3650") all call
--   event_mapper_run('gotickets_event'). The surface has been live since 2026-09-11 with live_fallback off, and in
--   live mode event_mapper_run ignores the horizon entirely: it calls event_mapper_map_surface(surface, true,
--   live_cap) and returns. So the 6-hour and daily jobs repeated the hourly one on the same rows (and timed out:
--   548 failed 4 of 7 nights, 545 5 of 28 runs, at the 170 s cap). The hourly job also ran event_mapper_shadow_tick,
--   which returns "not in shadow" at once for a live surface. Here: the hourly job keeps its name and schedule
--   with the one call that does the work and a 300 s ceiling; the other two are unscheduled. Nothing else changes:
--   same resolver, same cap, same rows — one pass an hour instead of three overlapping ones.
--
-- UNIT 1 · EIGHT HOURLY HUB FILLS AT EIGHT DIFFERENT MINUTES BECOME ONE ORDERED PASS. match_unmatched_orders_sweep
--   (:22), resolve_aq_tevo_from_sources (:28), backfill_order_tevo_from_aq (:40), aq_link_gotickets_from_catalogue
--   (:40), resolve_aq_seatdata_link (:42), link_aq_tevo_from_events (:45), aq_link_tevo_from_sibling_rows (:50),
--   axs_aq_link_tick (:21) each copy a known id from one place to another and run in an order that made orders wait
--   an hour for a hub fill made twenty minutes after them. hub_link_tick() runs the same eight functions, unchanged,
--   in dependency order — sources into the hub, hub to hub, hub to the order books — inside one job at :45, each
--   step in its own exception scope (one failing step no longer stops the others for the hour) with its result and
--   duration logged in hub_link_run. hub_link_tick(false) is a DRY RUN: every step runs for real inside a
--   subtransaction and is rolled back before the next, so the counts are the real ones.
--   Not merged: the match rules themselves (the one-hub-scan rewrite waits for the duplicate-row cleanup, KANBAN
--   MAP-5 — the sibling fill is the step that would spread a wrong id across a duplicate group).
--
-- NOT CONSOLIDATED, ON PURPOSE. cross_source_match_tick (152) is not a duplicate: besides the v3 SeatGeek matcher
--   (also run as the live fallback of cron 246) it runs the EVO orphan and SeatData xref resolvers.
--   match_listings_to_sg_tick (169) matches LISTINGS (ticket groups to SeatGeek listing ids), not events. The MLB,
--   TickPick, AXS and ESPN matchers have source-specific rules the shared resolver does badly and keep their own jobs.
-- Rollback: cron.schedule the ten jobs back with their former commands (recorded in cron_policy.notes below);
--   cron.unschedule('hub_link_hourly').

BEGIN;
SET LOCAL lock_timeout = '10s';

CREATE TABLE IF NOT EXISTS public.hub_link_run (
  id          bigserial PRIMARY KEY,
  at          timestamptz NOT NULL DEFAULT now(),
  applied     boolean NOT NULL,
  duration_ms integer,
  result      jsonb NOT NULL
);
CREATE INDEX IF NOT EXISTS hub_link_run_at_idx ON public.hub_link_run (at);
ALTER TABLE public.hub_link_run ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.hub_link_run FROM anon, authenticated;
GRANT SELECT ON public.hub_link_run TO service_role;
COMMENT ON TABLE public.hub_link_run IS 'One row per hub_link_tick() run: each hub-fill step''s result and duration. Mig 20261117060000.';

-- the eight hub fills, in dependency order, each in its own scope; p_apply=false rolls each step back after counting
CREATE OR REPLACE FUNCTION public.hub_link_tick(p_apply boolean DEFAULT true)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
DECLARE
  v_steps text[] := ARRAY['resolve_aq_tevo_from_sources', 'link_aq_tevo_from_events', 'aq_link_gotickets_from_catalogue',
                          'aq_link_tevo_from_sibling_rows', 'resolve_aq_seatdata_link', 'axs_aq_link_tick',
                          'backfill_order_tevo_from_aq', 'match_unmatched_orders_sweep'];
  v_step  text;
  v_res   jsonb;
  v_out   jsonb := '{}'::jsonb;
  v_t0    timestamptz := clock_timestamp();
  v_s0    timestamptz;
BEGIN
  IF current_user NOT IN ('service_role', 'postgres', 'supabase_admin') THEN
    RAISE EXCEPTION 'forbidden: %', current_user USING ERRCODE = '42501';
  END IF;
  FOREACH v_step IN ARRAY v_steps LOOP
    v_s0 := clock_timestamp();
    BEGIN
      CASE v_step
        WHEN 'resolve_aq_tevo_from_sources'    THEN v_res := to_jsonb(public.resolve_aq_tevo_from_sources());
        WHEN 'link_aq_tevo_from_events'        THEN v_res := to_jsonb(public.link_aq_tevo_from_events());
        WHEN 'aq_link_gotickets_from_catalogue' THEN v_res := to_jsonb(public.aq_link_gotickets_from_catalogue());
        WHEN 'aq_link_tevo_from_sibling_rows'  THEN v_res := to_jsonb(public.aq_link_tevo_from_sibling_rows());
        WHEN 'resolve_aq_seatdata_link'        THEN v_res := to_jsonb(public.resolve_aq_seatdata_link());
        WHEN 'axs_aq_link_tick'                THEN v_res := public.axs_aq_link_tick(300);
        WHEN 'backfill_order_tevo_from_aq'     THEN SELECT coalesce(jsonb_object_agg(t.tbl, t.newly_mapped), '{}'::jsonb) INTO v_res FROM public.backfill_order_tevo_from_aq() t;
        WHEN 'match_unmatched_orders_sweep'    THEN SELECT coalesce(jsonb_object_agg(t.table_name, jsonb_build_object('examined', t.rows_examined, 'matched', t.rows_matched, 'synthetic', t.rows_synthetic, 'unmatched', t.rows_unmatched)), '{}'::jsonb)
                                                      INTO v_res FROM public.match_unmatched_orders_sweep(500, true) t;
      END CASE;
      IF NOT p_apply THEN
        -- the dry run: carry the count out of the subtransaction on an exception, so the step's writes roll back
        RAISE EXCEPTION USING ERRCODE = 'P0DRY', MESSAGE = coalesce(v_res, 'null'::jsonb)::text;
      END IF;
    EXCEPTION
      WHEN SQLSTATE 'P0DRY' THEN v_res := public.safe_jsonb(SQLERRM);
      WHEN OTHERS THEN v_res := jsonb_build_object('error', SQLERRM);
    END;
    v_out := v_out || jsonb_build_object(v_step, jsonb_build_object('result', v_res, 'ms', round(extract(epoch FROM clock_timestamp() - v_s0) * 1000)::int));
  END LOOP;
  v_out := jsonb_build_object('applied', p_apply, 'ms', round(extract(epoch FROM clock_timestamp() - v_t0) * 1000)::int, 'steps', v_out);
  INSERT INTO public.hub_link_run (applied, duration_ms, result) VALUES (p_apply, (v_out->>'ms')::int, v_out);
  RETURN v_out;
END $function$;
COMMENT ON FUNCTION public.hub_link_tick(boolean) IS
  'The eight hourly hub fills in dependency order — resolve_aq_tevo_from_sources, link_aq_tevo_from_events, aq_link_gotickets_from_catalogue, aq_link_tevo_from_sibling_rows, resolve_aq_seatdata_link, axs_aq_link_tick, backfill_order_tevo_from_aq, match_unmatched_orders_sweep — each in its own scope, result + ms per step in hub_link_run. apply=false runs every step and rolls it back (real counts, no writes). Cron hub_link_hourly :45. Mig 20261117060000.';
REVOKE ALL ON FUNCTION public.hub_link_tick(boolean) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.hub_link_tick(boolean) TO service_role;

-- ───────────────────────── cron ─────────────────────────
DO $cron$
DECLARE
  j record;
BEGIN
  -- unit 1: the eight fills -> hub_link_hourly; their former commands kept in cron_policy.notes for rollback
  FOR j IN SELECT jobid, jobname, schedule, command FROM cron.job
            WHERE jobname IN ('match_unmatched_orders_sweep_hourly', 'backfill-order-tevo-from-aq-hourly',
                              'resolve-aq-tevo-from-sources-hourly', 'resolve-aq-seatdata-link-hourly',
                              'aq_link_tevo_siblings_hourly', 'aq_link_tevo_from_events_hourly',
                              'aq_link_gotickets_catalogue_hourly', 'axs_aq_link_hourly',
  -- unit 2: the two repeats of the hourly GoTickets pass
                              'gotickets_match_us_6h', 'gt_map_events_wide_daily') LOOP
    INSERT INTO public.cron_policy (jobname, enabled, notes)
    VALUES (j.jobname, false, format('retired 2026-11-17 (mig 20261117060000, consolidated into %s). was: schedule %L command %L',
                                     CASE WHEN j.jobname IN ('gotickets_match_us_6h', 'gt_map_events_wide_daily') THEN 'gt_map_events_hourly' ELSE 'hub_link_hourly' END,
                                     j.schedule, j.command))
    ON CONFLICT (jobname) DO UPDATE SET enabled = false, notes = EXCLUDED.notes, updated_at = now();
    PERFORM cron.unschedule(j.jobname);
  END LOOP;

  -- unit 2: the hourly GoTickets pass keeps its name and minute; one call, a 300 s ceiling, no dead shadow tick
  IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'gt_map_events_hourly') THEN
    PERFORM cron.unschedule('gt_map_events_hourly');
  END IF;
  PERFORM cron.schedule('gt_map_events_hourly', '32 * * * *',
                        $j$BEGIN; SET LOCAL statement_timeout = '300s'; SELECT public.event_mapper_run('gotickets_event'); COMMIT;$j$);

  -- unit 1: one ordered pass at :45
  INSERT INTO public.cron_policy (jobname, enabled, notes)
  VALUES ('hub_link_hourly', true, 'the eight hub fills in dependency order (hub_link_tick), mig 20261117060000')
  ON CONFLICT (jobname) DO UPDATE SET enabled = true, notes = EXCLUDED.notes, updated_at = now();
  IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'hub_link_hourly') THEN
    PERFORM cron.unschedule('hub_link_hourly');
  END IF;
  PERFORM cron.schedule('hub_link_hourly', '45 * * * *',
                        $j$BEGIN; SET LOCAL statement_timeout = '600s'; DO $b$ BEGIN IF NOT public.cron_should_fire('hub_link_hourly') THEN RETURN; END IF; PERFORM public.hub_link_tick(true); END $b$; COMMIT;$j$);
END
$cron$;

COMMIT;

-- VERIFY:
--   SELECT jobname, schedule FROM cron.job WHERE jobname IN ('hub_link_hourly', 'gt_map_events_hourly');   -- the two
--   SELECT jobname FROM cron.job WHERE jobname IN ('gotickets_match_us_6h', 'gt_map_events_wide_daily', 'match_unmatched_orders_sweep_hourly',
--     'backfill-order-tevo-from-aq-hourly', 'resolve-aq-tevo-from-sources-hourly', 'resolve-aq-seatdata-link-hourly',
--     'aq_link_tevo_siblings_hourly', 'aq_link_tevo_from_events_hourly', 'aq_link_gotickets_catalogue_hourly', 'axs_aq_link_hourly');   -- none
--   SELECT public.hub_link_tick(false);                               -- the dry run: real counts, nothing written
--   SELECT at, applied, duration_ms, result->'steps' FROM hub_link_run ORDER BY at DESC LIMIT 3;
