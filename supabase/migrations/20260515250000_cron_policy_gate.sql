-- Migration 20260515250000 · level:admin · lane:Audit/Push · writes:cron_policy (new), cron_gate_decisions (new), cron_should_fire() fn, cron_last_fire() fn, cron_resume_with_gate() fn, cron_gate_decisions_prune_daily cron, seed policy rows · reads:cron_pause_state_20260514 · pre:20260515240000
-- Data-driven cron policy gate balancing data-freshness vs resource conservation.
--
-- Operator directive 2026-05-14 (after pausing all 71 crons + collecting
-- hour-of-day activity data + clarifying twin goals):
--   "can we program crons to use this data effectively?" (peak/off-peak data)
--   "Consider environmental conservation efforts as an additional focus
--    aside from data freshness"
--
-- Twin goals balanced per-job:
--   1. FRESHNESS: fire often enough during peak hours to keep data current
--   2. CONSERVATION: fire only when needed (work present, budget not blown,
--      interval elapsed). Every avoided fire saves CPU, WAL, network egress,
--      and carbon.
--
-- 4-stage gate (cheap → expensive ordering):
--   Stage 0: disabled flag (instant kill switch)
--   Stage 1: daily budget cap (CONSERVATION) — indexed COUNT
--   Stage 2: min-interval based on peak/off-peak (FRESHNESS guardrail) — indexed MAX
--   Stage 3: work-presence check (CONSERVATION) — operator-defined EXISTS query
--
-- ## Already applied to prod
-- Applied via MCP 2026-05-14 (this session). DDL + functions + 1 retrofit.
-- Operator graduates additional crons one at a time via cron_resume_with_gate().
--
-- ## Regression risk
-- None. New tables, no view rewrites, no existing-cron mutations except the
-- single retrofit (sweep_duplicate_listings_hourly was paused, comes back
-- through gate).

-- ============================================================
-- 1. cron_policy table
-- ============================================================

CREATE TABLE IF NOT EXISTS public.cron_policy (
  jobname                  text PRIMARY KEY,
  peak_hours_et            int[]   NOT NULL,
  peak_min_interval_min    int     NOT NULL,
  offpeak_min_interval_min int     NOT NULL,
  work_check_sql           text,
  daily_max_fires          int,
  enabled                  boolean NOT NULL DEFAULT true,
  notes                    text,
  updated_at               timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.cron_policy IS
  'Per-cron firing policy. peak_hours_et + peak_min_interval_min control freshness window; work_check_sql + daily_max_fires control resource conservation. Gate function: public.cron_should_fire(jobname).';

COMMENT ON COLUMN public.cron_policy.work_check_sql IS
  'Optional SQL that must return boolean. Gate skips if FALSE/NULL. Keep these as EXISTS (... LIMIT 1) for sub-ms latency. Fails OPEN on SQL error (permits fire) to never silently lose freshness.';

COMMENT ON COLUMN public.cron_policy.daily_max_fires IS
  'Hard cap on actual fires per UTC day. NULL = unlimited. Conservation guardrail.';

-- ============================================================
-- 2. cron_gate_decisions audit table
-- ============================================================

CREATE TABLE IF NOT EXISTS public.cron_gate_decisions (
  jobname        text        NOT NULL,
  decided_at     timestamptz NOT NULL DEFAULT clock_timestamp(),  -- NOT now() — needs wall-clock for same-txn callability
  decision       text        NOT NULL,
  hour_et        int         NOT NULL,
  last_fire_at   timestamptz,
  fires_today    int,
  PRIMARY KEY (jobname, decided_at)
);

COMMENT ON TABLE public.cron_gate_decisions IS
  'Audit trail of cron_should_fire() decisions. decision is one of: fire | fire_no_policy | skip_offpeak | skip_interval | skip_no_work | skip_budget | disabled. Pruned to 30 days by cron_gate_decisions_prune_daily (keeps all fire rows).';

CREATE INDEX IF NOT EXISTS cron_gate_decisions_jobname_fire_idx
  ON public.cron_gate_decisions (jobname, decided_at DESC)
  WHERE decision = 'fire';

-- ============================================================
-- 3. cron_last_fire() helper
-- ============================================================

CREATE OR REPLACE FUNCTION public.cron_last_fire(p_jobname text)
RETURNS timestamptz
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, extensions, pg_temp
AS $$
  SELECT max(decided_at) FROM public.cron_gate_decisions
  WHERE jobname = p_jobname AND decision = 'fire';
$$;

COMMENT ON FUNCTION public.cron_last_fire IS
  'Returns timestamp of last successful fire decision for a jobname. Use in work_check_sql expressions.';

-- ============================================================
-- 4. cron_should_fire() — the 4-stage gate
-- ============================================================

CREATE OR REPLACE FUNCTION public.cron_should_fire(p_jobname text)
RETURNS boolean
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = public, extensions, pg_temp
AS $$
DECLARE
  v_policy        public.cron_policy%ROWTYPE;
  v_hour_et       int;
  v_in_peak       boolean;
  v_interval_min  int;
  v_last_fire     timestamptz;
  v_fires_today   int := NULL;
  v_has_work      boolean := true;
  v_decision      text;
  v_now           timestamptz := clock_timestamp();
BEGIN
  v_hour_et := EXTRACT(hour FROM (v_now AT TIME ZONE 'America/New_York'))::int;
  SELECT * INTO v_policy FROM public.cron_policy WHERE jobname = p_jobname;

  -- No policy row → unconstrained (preserves legacy behavior for non-graduated crons)
  IF NOT FOUND THEN
    INSERT INTO public.cron_gate_decisions(jobname, decided_at, decision, hour_et)
      VALUES (p_jobname, v_now, 'fire_no_policy', v_hour_et);
    RETURN true;
  END IF;

  -- Stage 0: explicitly disabled
  IF NOT v_policy.enabled THEN
    INSERT INTO public.cron_gate_decisions(jobname, decided_at, decision, hour_et)
      VALUES (p_jobname, v_now, 'disabled', v_hour_et);
    RETURN false;
  END IF;

  -- Stage 1: daily budget (CONSERVATION) — cheapest check first
  IF v_policy.daily_max_fires IS NOT NULL THEN
    SELECT count(*) INTO v_fires_today FROM public.cron_gate_decisions
      WHERE jobname = p_jobname AND decision = 'fire'
        AND decided_at >= date_trunc('day', v_now AT TIME ZONE 'UTC');
    IF v_fires_today >= v_policy.daily_max_fires THEN
      INSERT INTO public.cron_gate_decisions(jobname, decided_at, decision, hour_et, fires_today)
        VALUES (p_jobname, v_now, 'skip_budget', v_hour_et, v_fires_today);
      RETURN false;
    END IF;
  END IF;

  -- Stage 2: min-interval
  SELECT max(decided_at) INTO v_last_fire
    FROM public.cron_gate_decisions
    WHERE jobname = p_jobname AND decision = 'fire';
  v_in_peak := v_hour_et = ANY(v_policy.peak_hours_et);
  v_interval_min := CASE WHEN v_in_peak THEN v_policy.peak_min_interval_min
                                        ELSE v_policy.offpeak_min_interval_min END;
  IF v_last_fire IS NOT NULL AND (v_now - v_last_fire) < make_interval(mins => v_interval_min) THEN
    v_decision := CASE WHEN v_in_peak THEN 'skip_interval' ELSE 'skip_offpeak' END;
    INSERT INTO public.cron_gate_decisions(jobname, decided_at, decision, hour_et, last_fire_at, fires_today)
      VALUES (p_jobname, v_now, v_decision, v_hour_et, v_last_fire, v_fires_today);
    RETURN false;
  END IF;

  -- Stage 3: work-presence (CONSERVATION)
  IF v_policy.work_check_sql IS NOT NULL THEN
    BEGIN
      EXECUTE v_policy.work_check_sql INTO v_has_work;
    EXCEPTION WHEN OTHERS THEN
      -- Bad SQL in policy → permit fire (fail-open to preserve freshness)
      v_has_work := true;
    END;
    IF NOT coalesce(v_has_work, false) THEN
      INSERT INTO public.cron_gate_decisions(jobname, decided_at, decision, hour_et, last_fire_at, fires_today)
        VALUES (p_jobname, v_now, 'skip_no_work', v_hour_et, v_last_fire, v_fires_today);
      RETURN false;
    END IF;
  END IF;

  -- All stages passed → fire
  INSERT INTO public.cron_gate_decisions(jobname, decided_at, decision, hour_et, last_fire_at, fires_today)
    VALUES (p_jobname, v_now, 'fire', v_hour_et, v_last_fire, v_fires_today);
  RETURN true;
END $$;

COMMENT ON FUNCTION public.cron_should_fire IS
  '4-stage gate: budget(cheap) -> interval -> work-check(expensive). Returns true if fire permitted. Logs every decision to cron_gate_decisions for audit/tuning.';

-- ============================================================
-- 5. cron_resume_with_gate() — re-enable a paused cron through the gate
-- ============================================================

CREATE OR REPLACE FUNCTION public.cron_resume_with_gate(p_jobname text)
RETURNS text
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = public, extensions, pg_temp
AS $$
DECLARE
  v_schedule  text;
  v_cmd       text;
  v_wrapped   text;
  v_new_jobid bigint;
  v_inner     text;
BEGIN
  SELECT schedule, command INTO v_schedule, v_cmd
  FROM public.cron_pause_state_20260514 WHERE jobname = p_jobname;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'jobname % not in cron_pause_state_20260514 snapshot', p_jobname;
  END IF;

  -- Validate: command must NOT already be a DO block (would create $body$ nesting issues)
  IF v_cmd ~* '^\s*DO\s+\$' THEN
    RAISE EXCEPTION 'cron_resume_with_gate cannot auto-wrap a DO-block command for %. Manual wrap required. Original command: %', p_jobname, v_cmd;
  END IF;

  -- Convert "SELECT ..." → "PERFORM ..." (so it works inside DO block)
  -- Handle the two common shapes: "SELECT fn();" and "SELECT * FROM fn();"
  v_inner := trim(both ' ;' from v_cmd);
  v_inner := regexp_replace(v_inner, '^\s*SELECT\s+\*\s+FROM\s+', 'PERFORM ', 'i');
  v_inner := regexp_replace(v_inner, '^\s*SELECT\s+',             'PERFORM ', 'i');

  v_wrapped := format(
    $wrap$DO $body$ BEGIN IF NOT public.cron_should_fire(%L) THEN RETURN; END IF; %s; END $body$;$wrap$,
    p_jobname, v_inner);

  -- Drop existing entry (paused or active) before scheduling fresh
  PERFORM cron.unschedule(p_jobname) FROM cron.job WHERE jobname = p_jobname;
  v_new_jobid := cron.schedule(p_jobname, v_schedule, v_wrapped);

  RETURN format('jobid=%s schedule=%I wrapped=true', v_new_jobid, v_schedule);
END $$;

COMMENT ON FUNCTION public.cron_resume_with_gate IS
  'Re-enables a paused cron through the policy gate. Reads original schedule+command from cron_pause_state_20260514, wraps the command in a DO block that calls cron_should_fire(jobname). Rejects already-wrapped DO blocks with clear error.';

-- ============================================================
-- 6. Seed policy table — 6 default categories from the spot-check data
-- ============================================================

INSERT INTO public.cron_policy
  (jobname, peak_hours_et, peak_min_interval_min, offpeak_min_interval_min,
   work_check_sql, daily_max_fires, notes)
VALUES
  -- Vivid + TickPick ingest (morning + early-afternoon retail peak)
  ('vivid_orders_queue_30min',
   ARRAY[7,8,9,10,11,12,13,14,15,16,17,18],
   15, 60,
   'SELECT (SELECT max(ordered_at) FROM public.vivid_orders) > coalesce(public.cron_last_fire(''vivid_orders_queue_30min''), ''1970-01-01''::timestamptz) - interval ''24 hours''',
   60, 'Retail peak 8 AM + 2 PM ET; conserves overnight when no recent activity'),
  ('tickpick_orders_queue_30min',
   ARRAY[7,8,9,10,11,12,13,14,15,16,17,18],
   15, 60,
   'SELECT (SELECT max(ordered_at) FROM public.tickpick_orders) > coalesce(public.cron_last_fire(''tickpick_orders_queue_30min''), ''1970-01-01''::timestamptz) - interval ''24 hours''',
   60, 'Daytime peak ~4 PM ET; sharp drop after 6 PM'),

  -- SG broker + seller ingest (evening + late-night broker activity)
  ('sg_broker_sales_process_30min',
   ARRAY[12,13,14,15,16,17,18,19,20,21,22,23],
   15, 60,
   NULL,
   60, 'Peak 11 PM ET; sales arrive any time so always check'),
  ('sg_seller_process_30min',
   ARRAY[12,13,14,15,16,17,18,19,20,21,22,23],
   15, 60,
   NULL,
   60, 'Mid-day + evening peaks'),

  -- Evo ingest
  ('evo_orders_queue_30min',
   ARRAY[9,10,11,12,13,14,15,16,17,18,19,20,21],
   30, 120,
   'SELECT (SELECT max(evo_created_at) FROM public.evo_orders) > coalesce(public.cron_last_fire(''evo_orders_queue_30min''), ''1970-01-01''::timestamptz) - interval ''24 hours''',
   30, 'B2B inventory ops; spread 10 AM-9 PM ET'),

  -- Heavy sweeps — only fire in true off-peak window, cap daily, skip when caught up
  ('sweep_duplicate_listings_hourly',
   ARRAY[5,6,7],
   60, 1440,
   'SELECT EXISTS (SELECT 1 FROM public.unified_listings WHERE aq_short_event_id IS NOT NULL GROUP BY tevo_event_id, source_key, section, "row", quantity HAVING count(*) > 1 LIMIT 1)',
   3, 'Heavy sweep — only 5-7 AM ET window, max 3 fires/day, skip if no dups exist'),
  ('match_unmatched_orders_sweep_hourly',
   ARRAY[5,6,7],
   60, 1440,
   'SELECT EXISTS (SELECT 1 FROM public.unified_orders WHERE aq_short_event_id IS NULL LIMIT 1)',
   3, 'Heavy sweep — skip if all orders matched (true today after this session)'),
  ('cross_source_match_tick_30min',
   ARRAY[5,6,7],
   30, 720,
   NULL,
   6, 'Has 35s tail latency; constrain to off-peak window + budget'),

  -- Real-time refresh views
  ('latest_event_metrics_refresh_5min',
   ARRAY[7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23],
   5, 30,
   NULL,
   200, 'High-cadence during business hours; sparse overnight'),
  ('dashboard_writes_24h_refresh_60s',
   ARRAY[7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23],
   5, 30,
   NULL,
   200, '0.98s avg; cap to 200/day total'),

  -- Always-on (health/vault)
  ('release_health_check_hourly',
   ARRAY[0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23],
   60, 60, NULL, 24, 'Always-on; one fire per hour exactly')
ON CONFLICT (jobname) DO NOTHING;

-- ============================================================
-- 7. Retrofit ONE example cron — proof of pattern
-- ============================================================
-- sweep_duplicate_listings_hourly is the biggest non-failing CPU consumer
-- (97 sec/day in baseline). Simple SELECT body. Safe choice.

DO $retrofit$
BEGIN
  IF EXISTS (SELECT 1 FROM public.cron_pause_state_20260514 WHERE jobname='sweep_duplicate_listings_hourly') THEN
    PERFORM public.cron_resume_with_gate('sweep_duplicate_listings_hourly');
  END IF;
END $retrofit$;

-- ============================================================
-- 8. Daily prune of cron_gate_decisions (keeps fires, prunes skips >30d)
-- ============================================================
-- 09:01 UTC = 5:01 AM ET — middle of the truly quiet window.

DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM cron.job WHERE jobname='cron_gate_decisions_prune_daily') THEN
    PERFORM cron.schedule(
      'cron_gate_decisions_prune_daily',
      '1 9 * * *',
      $cron$DELETE FROM public.cron_gate_decisions WHERE decided_at < now() - interval '30 days' AND decision <> 'fire';$cron$
    );
  END IF;
END $$;
