-- Migration 20260926014415 · level:secondary-sales · lane:D7 · writes:cron.job · reads:none · pre:20260925233701
--
-- Already applied to prod · via MCP 2026-09-26 under operator direction.
--
-- ============================================================================
-- Migration 20260926014415 — the GoTickets name matcher leaves the tick and
-- runs as its own every-minute job
--
-- Lane: D7 · Pre-reqs: 20260911020000 (n2s_gt_map_by_name), 20260925233701
--
-- WHY. Measured over 3 days of cron 640 (3,860 successful ticks): a tick that
-- starts on a minute divisible by 5 — the only minutes the tick ran
-- n2s_gt_map_by_name() — took a typical 2 min 1 s (p90 2 min 27 s); every
-- other tick took 41 s (p90 1 min 17 s). The matcher added ~80 s to 18% of all
-- ticks, and a tick is ONE transaction, so every new order drained by that
-- tick waited for it before its cover became visible. The N2S obligation is a
-- 10-minute window from CRM alert to returning subs.
--
-- The matcher does not map orders (the mapper does: 193 of 195 new orders over
-- 3 days). It links gotickets_event rows to TEvo so an order with no TEvo event
-- can be placed by the mapper on a following tick — 1 new link in 3 days. That
-- is exactly the order at risk on the 10-minute clock, so it keeps running, and
-- faster:
--
--   * removed from n2s_pipeline_tick (one anchored block; md5-guarded);
--   * new cron `n2s_gt_map_by_name_1min`, every minute, gated by
--     cron_should_fire (skips while the previous run is still going) and by
--     the SAME condition the tick used — only when a live order has no TEvo
--     event — so it costs nothing when every order is mapped;
--   * it only writes gotickets_event, which the tick only reads, so the two
--     never block each other.
--
-- Net: no 2-minute ticks, and an unmapped order gets the name pass within ~1
-- minute instead of at the next :00/:05/… tick.
-- Rollback at the bottom.
-- ============================================================================

DO $$
DECLARE
  v_def   text := pg_get_functiondef('public.n2s_pipeline_tick'::regproc);
  v_start int;
  v_end   int;
BEGIN
  IF md5(v_def) <> 'f247d5da6da580e8c54fb1cc435f6173' THEN
    RAISE EXCEPTION 'n2s_pipeline_tick drifted from the reviewed body — refusing';
  END IF;
  v_start := position('-- Fallback name-matcher' in v_def);
  v_end   := position('v_stage := ''pull_all_sources''' in v_def);
  IF v_start = 0 OR v_end = 0 OR v_end < v_start
     OR position('n2s_gt_map_by_name' in substring(v_def from v_start for v_end - v_start)) = 0 THEN
    RAISE EXCEPTION 'n2s_pipeline_tick: gt_map_by_name block not found where expected';
  END IF;
  v_def := substring(v_def from 1 for v_start - 1)
        || '-- GoTickets name matcher runs as its own job, n2s_gt_map_by_name_1min (20260926014415).' || E'\n  '
        || substring(v_def from v_end);
  EXECUTE v_def;
  IF position('n2s_gt_map_by_name()' in pg_get_functiondef('public.n2s_pipeline_tick'::regproc)) > 0 THEN
    RAISE EXCEPTION 'n2s_pipeline_tick still calls n2s_gt_map_by_name';
  END IF;
END $$;

SELECT cron.schedule(
  'n2s_gt_map_by_name_1min',
  '* * * * *',
  $cmd$
  SET statement_timeout = '150s';
  DO $b$ BEGIN
    IF NOT EXISTS (SELECT 1 FROM public.n2s_items i
                    WHERE i.tevo_event_id IS NULL
                      AND NOT i.is_terminal
                      AND public.n2s_event_live(i.event_dt, i.tevo_event_id)) THEN
      RETURN;
    END IF;
    IF NOT public.cron_should_fire('n2s_gt_map_by_name_1min') THEN RETURN; END IF;
    PERFORM * FROM public.n2s_gt_map_by_name();
  END $b$;
  $cmd$
);

-- ── rollback ───────────────────────────────────────────────────────────────
-- SELECT cron.unschedule('n2s_gt_map_by_name_1min');
-- Re-add the stage to n2s_pipeline_tick in place of the marker comment, before
-- `v_stage := 'pull_all_sources'`. The removed block, verbatim:
--
--   -- Fallback name-matcher: mean 44.3s, max 92.6s. Only helps an unmapped
--   -- order, so skip when there are none and otherwise run at 5-min cadence.
--   v_stage := 'gt_map_by_name';
--   IF clock_timestamp() - v_start < make_interval(secs => p_budget_seconds)
--      AND EXTRACT(minute FROM clock_timestamp())::int % 5 = 0
--      AND EXISTS (SELECT 1 FROM public.n2s_items i
--                   WHERE i.tevo_event_id IS NULL
--                     AND NOT i.is_terminal
--                     AND public.n2s_event_live(i.event_dt, i.tevo_event_id)) THEN
--     BEGIN
--       PERFORM * FROM public.n2s_gt_map_by_name();
--     EXCEPTION WHEN OTHERS THEN
--       v_errors := v_errors || jsonb_build_object('stage', v_stage, 'err', SQLERRM);
--     END;
--   END IF;
