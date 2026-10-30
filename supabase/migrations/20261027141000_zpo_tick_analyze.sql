-- Migration 20261027141000 · level:ops · lane:A1 (data plane — ML feature store) · writes:zpo_daily_tick()(replace),cron zone_price_observations_daily(replace) · reads:zone_metrics,zone_price_observations,zpo_build_state · pre:20261027030432 (zpo runner)
--
-- ============================================================================
-- zpo_daily_tick: ANALYZE before enrichment + smaller per-run budget
--
-- WHAT BROKE (first night of the 20261027030432 runner, 06:15–11:45 UTC): all 12 runs hit
-- the 15-min cron statement timeout and rolled back. A pg_cron command is ONE statement, so
-- the timeout discards the whole run — the build progress too — and zpo_build_state never
-- advanced. Cause: the day's rows are inserted earlier in the same run and have no planner
-- statistics, so the enrichment UPDATEs (first the news-buzz join) planned for ~1 row and
-- chose nested loops over tens of thousands. Measured on prod (rolled back, 80 events /
-- 1,025 rows of 2026-10-26): buzz step > 50 s without statistics, 0.14 s after ANALYZE (3.5 s).
--
-- FIX: ANALYZE zone_price_observations before enriching whenever rows were built since the last
-- ANALYZE, and run with a 480 s budget (build stops at 480 s; enrichment only starts before 360 s), leaving
-- > 8 min of headroom under the 900 s timeout.
--
-- ROLLBACK: re-apply zpo_daily_tick from 20261027030432 and reschedule with zpo_daily_tick(600).
-- ============================================================================

SET LOCAL lock_timeout = '10s';

CREATE OR REPLACE FUNCTION public.zpo_daily_tick(p_budget_seconds integer DEFAULT 600)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_start   timestamptz := clock_timestamp();
  v_budget  interval := make_interval(secs => p_budget_seconds);
  v_caller  text;
  v_d       date;
  st        public.zpo_build_state%ROWTYPE;
  v_ev      bigint;
  v_n       integer;
  v_t0      timestamptz;
  v_log     jsonb := '[]'::jsonb;
  v_stop    boolean := false;
  v_stale   boolean;
  v_unanalyzed boolean := false;   -- rows built since the last ANALYZE
BEGIN
  -- inside SECURITY DEFINER current_user is the owner; check the caller's role
  v_caller := CASE WHEN coalesce(current_setting('role', true), 'none') IN ('', 'none')
                   THEN session_user::text ELSE current_setting('role', true) END;
  IF v_caller NOT IN ('service_role','postgres','supabase_admin') THEN
    RAISE EXCEPTION 'forbidden: zpo_daily_tick is service-only (caller %)', v_caller USING ERRCODE = '42501';
  END IF;

  -- Last 14 days, oldest first (velocity reads the previous day's rows).
  FOR v_d IN SELECT d::date FROM generate_series(current_date - 14, current_date, interval '1 day') d ORDER BY d LOOP
    EXIT WHEN v_stop;
    SELECT * INTO st FROM public.zpo_build_state WHERE capture_date = v_d;

    -- first sight of a day: count its events once (BRIN on captured_at); empty days are recorded as done
    IF st.capture_date IS NULL THEN
      SELECT count(DISTINCT event_id) INTO v_n FROM zone_metrics
       WHERE captured_at >= v_d::timestamptz AND captured_at < (v_d + 1)::timestamptz;
      INSERT INTO public.zpo_build_state (capture_date, events_total, build_started_at, build_finished_at, enriched_at)
      VALUES (v_d, v_n, now(),
              CASE WHEN v_n = 0 THEN now() END,
              CASE WHEN v_n = 0 THEN now() END)
      ON CONFLICT (capture_date) DO NOTHING;
      SELECT * INTO st FROM public.zpo_build_state WHERE capture_date = v_d;
    END IF;

    -- A finished build is stale only for YESTERDAY when it was made before the day ended
    -- (it saw a partial day). Today is built once per day; older days once.
    v_stale := st.build_finished_at IS NOT NULL
               AND v_d = current_date - 1
               AND st.build_finished_at < (v_d + 1)::timestamptz;
    IF v_stale THEN
      SELECT count(DISTINCT event_id) INTO v_n FROM zone_metrics
       WHERE captured_at >= v_d::timestamptz AND captured_at < (v_d + 1)::timestamptz;
      UPDATE public.zpo_build_state
         SET events_total = v_n, last_event_id = 0, events_built = 0, rows_built = 0,
             build_started_at = now(), build_finished_at = NULL, enriched_at = NULL,
             enrich_seconds = NULL, last_error = NULL, updated_at = now()
       WHERE capture_date = v_d;
      SELECT * INTO st FROM public.zpo_build_state WHERE capture_date = v_d;
    END IF;

    CONTINUE WHEN st.build_finished_at IS NOT NULL AND st.enriched_at IS NOT NULL;   -- done

    -- build, event by event, from the resumable cursor
    IF st.build_finished_at IS NULL THEN
      FOR v_ev IN
        SELECT DISTINCT event_id FROM zone_metrics
         WHERE captured_at >= v_d::timestamptz AND captured_at < (v_d + 1)::timestamptz
           AND event_id > st.last_event_id
         ORDER BY event_id
      LOOP
        IF clock_timestamp() - v_start > v_budget THEN v_stop := true; EXIT; END IF;
        v_n := public.build_zone_price_observations(v_ev, v_d);
        v_unanalyzed := true;
        UPDATE public.zpo_build_state
           SET last_event_id = v_ev, events_built = events_built + 1, rows_built = rows_built + v_n, updated_at = now()
         WHERE capture_date = v_d;
      END LOOP;
      IF v_stop THEN
        SELECT * INTO st FROM public.zpo_build_state WHERE capture_date = v_d;
        v_log := v_log || jsonb_build_object('date', v_d, 'status', 'build_paused',
                                             'events_built', st.events_built, 'events_total', st.events_total);
        EXIT;
      END IF;
      UPDATE public.zpo_build_state SET build_finished_at = now(), updated_at = now() WHERE capture_date = v_d;
    END IF;

    -- enrichment takes ~30–60 s for a full day: don't start it in the last 2 minutes of the
    -- budget (a statement timeout cannot be caught and would roll the whole run back)
    IF clock_timestamp() - v_start > v_budget - interval '2 minutes' THEN
      v_log := v_log || jsonb_build_object('date', v_d, 'status', 'enrich_deferred');
      v_stop := true; EXIT;
    END IF;

    -- Rows built earlier in this same run have no planner statistics yet: without them the
    -- enrichment UPDATEs estimate 1 row per day and pick nested loops over ~40 k rows (every
    -- run hit the 15-min timeout on 2026-10-27). ANALYZE (~4 s) whenever rows were built since
    -- the last one.
    IF v_unanalyzed THEN
      ANALYZE public.zone_price_observations;
      v_unanalyzed := false;
    END IF;

    v_t0 := clock_timestamp();
    BEGIN
      PERFORM public.enrich_zone_price_observations(v_d);
      UPDATE public.zpo_build_state
         SET enriched_at = now(), enrich_seconds = round(extract(epoch FROM clock_timestamp() - v_t0)::numeric, 1),
             last_error = NULL, updated_at = now()
       WHERE capture_date = v_d;
      SELECT * INTO st FROM public.zpo_build_state WHERE capture_date = v_d;
      v_log := v_log || jsonb_build_object('date', v_d, 'status', 'done', 'rows', st.rows_built,
                                           'events', st.events_built, 'enrich_s', st.enrich_seconds);
    EXCEPTION WHEN OTHERS THEN
      -- recorded; the build above is kept and the next run retries enrichment only
      UPDATE public.zpo_build_state SET last_error = left(SQLERRM, 500), updated_at = now() WHERE capture_date = v_d;
      v_log := v_log || jsonb_build_object('date', v_d, 'status', 'enrich_failed', 'error', left(SQLERRM, 200));
    END;
  END LOOP;

  RETURN jsonb_build_object('days', v_log, 'seconds', round(extract(epoch FROM clock_timestamp() - v_start)::numeric, 1),
                            'stopped_on_budget', v_stop);
END $$;

REVOKE ALL ON FUNCTION public.zpo_daily_tick(integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.zpo_daily_tick(integer) TO service_role;

DO $c$
BEGIN
  PERFORM cron.unschedule(jobid) FROM cron.job WHERE jobname = 'zone_price_observations_daily';
  PERFORM cron.schedule('zone_price_observations_daily', '15,45 6-11 * * *',
    $cmd$DO $b$ BEGIN IF NOT public.cron_try_lock('zone_price_observations_daily') THEN RETURN; END IF; PERFORM public.zpo_daily_tick(480); END $b$;$cmd$);
END $c$;

-- VERIFY: SELECT capture_date, rows_built, enriched_at, enrich_seconds, last_error FROM public.zpo_build_state ORDER BY 1;
