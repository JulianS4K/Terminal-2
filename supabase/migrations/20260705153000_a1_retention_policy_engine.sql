-- ============================================================================
-- Migration 20260705153000 — unified retention engine (retention_policy + retention_tick)
--
-- Lane:     A1 (data plane — crons/retention)
-- Touches:  retention_policy (NEW, W), retention_run_log (NEW, W),
--           retention_tick() (NEW fn), record_cron_deadman() (fn replace, +2 watch rows),
--           cron.job (unschedule sweep-old-* ×6; schedule retention_tick_hourly),
--           cron_policy (W: supersede notes + new row),
--           section_metrics + seatgeek_listings_snapshots (NEW captured_at indexes),
--           listings_snapshots / ticketsdata_listings_snapshots / seatgeek_listings_snapshots /
--           section_metrics / event_section_row_snapshots / event_metrics /
--           espn_injuries_snapshots (scoped DELETEs at runtime via retention_tick)
-- Pre-reqs: 20260701235000 (record_cron_deadman + health_check_history),
--           20260702000500 (current record_cron_deadman body being extended)
--
-- APPLY-WINDOW NOTE: §0 builds two plain (non-CONCURRENT) btree indexes —
--   section_metrics (69M rows / 14 GB) + seatgeek_listings_snapshots (18M / 16 GB;
--   currently write-dark). Verified 2026-07-05: NEITHER table has a captured_at-leading
--   index, so retention batches (and the mig 153500 day-window rollup) would seq-scan
--   without them (a 1-day count on section_metrics times out today). Expect a few
--   minutes of SHARE lock each — apply off-peak; section_metrics writers
--   (zone-backfill) queue during the build.
--
-- WHY (operator-directed redesign 2026-07-05; follows audit AUD-16,
-- docs/archive/2026-07-02-sql-crons-jobs-audit.md):
--   The per-table sweep-old-* crons failed silently twice (sweep_old_listings threw
--   `column "id" does not exist` on every run ~05-31→06-17 while listings_snapshots
--   grew to 45 GB; then ALL listing sweeps were toggled off out-of-band during the
--   2026-07-01 scheduler wedge and never re-enabled — listings_snapshots reached
--   75 GB / ~227M rows, oldest row 36d vs the 15d policy). Root causes: N cron jobs
--   with N functions, no single source of truth, out-of-band `cron.alter_job` toggles
--   with no migration trail, and no run-level logging.
--
-- DESIGN:
--   * retention_policy — one row per swept table: keep_days, enabled, batch/budget.
--     The ENABLED FLAG IS THE KILL SWITCH (data change, auditable, survives incidents;
--     no more per-job cron.alter_job toggles).
--   * retention_tick(p_global_budget_seconds) — single runner, hourly. Per policy:
--     unordered ctid-batched deletes (same pattern as sweep-old-section-metrics),
--     loop-level wall-clock budgets at BOTH policy and global level (scheduler-wedge
--     rule, PROJECT_BIBLE §3), per-policy stats + retention_run_log rows, errors
--     recorded per-policy without aborting the tick.
--   * Old sweep-old-* crons unscheduled HERE (migration trail restored); their
--     functions kept for manual use, COMMENTed superseded.
--   * seatgeek_listings_snapshots row seeded DISABLED — operator decision pending
--     (SG listings pollers dark since 2026-06-26; a 30d TTL on a dark table drains
--     it to empty). Flip retention_policy.enabled when the SG path resumes.
--   * When the listings_snapshots partition BLUEPRINT (20260619220000, A1-OPS-18)
--     lands, its policy row should be repointed at partition drops; the policy table
--     stays the single source of truth for the window either way.
--   * Never swept (by design, NOT seeded here): order/sales tables (forever),
--     event_listing_snapshot_daily + venue_section_price_daily (indefinite rollups).
-- ============================================================================

-- ── 0. Support indexes (captured_at-leading; required by batched TTL deletes) ─
-- listings_snapshots (idx_listings_captured) + ticketsdata (idx_td_ls_captured_at)
-- + event_section_row_snapshots (esrs_captured_idx) already have one.
-- event_metrics/espn_injuries are small enough to skip.

CREATE INDEX IF NOT EXISTS idx_section_metrics_captured
  ON public.section_metrics (captured_at);
CREATE INDEX IF NOT EXISTS idx_sg_listings_captured
  ON public.seatgeek_listings_snapshots (captured_at);

-- ── 1. Policy table ──────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS public.retention_policy (
  table_name     text PRIMARY KEY,
  ts_column      text        NOT NULL DEFAULT 'captured_at',
  keep_days      integer     NOT NULL CHECK (keep_days >= 3),
  enabled        boolean     NOT NULL DEFAULT true,
  batch_rows     integer     NOT NULL DEFAULT 50000 CHECK (batch_rows BETWEEN 1000 AND 200000),
  budget_seconds integer     NOT NULL DEFAULT 60    CHECK (budget_seconds BETWEEN 5 AND 600),
  priority       integer     NOT NULL DEFAULT 100,  -- lower runs first
  last_run_at    timestamptz,
  last_deleted   bigint      NOT NULL DEFAULT 0,
  total_deleted  bigint      NOT NULL DEFAULT 0,
  last_error     text,
  notes          text,
  created_at     timestamptz NOT NULL DEFAULT now(),
  updated_at     timestamptz NOT NULL DEFAULT now(),
  meta           jsonb
);

REVOKE ALL ON TABLE public.retention_policy FROM anon, authenticated;
ALTER TABLE public.retention_policy ENABLE ROW LEVEL SECURITY;
DO $p$ BEGIN
  CREATE POLICY "service_role_all" ON public.retention_policy
    TO service_role USING (true) WITH CHECK (true);
EXCEPTION WHEN duplicate_object THEN NULL; END $p$;

COMMENT ON TABLE public.retention_policy IS
  'Single source of truth for TTL retention on snapshot/metric tables. One row per table; '
  'retention_tick() (hourly cron) enforces. enabled=false is THE kill switch — never '
  'cron.alter_job the runner off per-table. Sales/order tables are never listed here '
  '(forever retention by design). Mig 20260705153000.';

-- ── 2. Run log (self-housekept via its own policy row) ──────────────────────

CREATE TABLE IF NOT EXISTS public.retention_run_log (
  id          bigserial PRIMARY KEY,
  run_at      timestamptz NOT NULL DEFAULT now(),
  table_name  text        NOT NULL,
  cutoff      timestamptz,
  deleted     bigint      NOT NULL DEFAULT 0,
  duration_ms integer,
  note        text
);
CREATE INDEX IF NOT EXISTS idx_retention_run_log_run_at ON public.retention_run_log (run_at DESC);

REVOKE ALL ON TABLE public.retention_run_log FROM anon, authenticated;
ALTER TABLE public.retention_run_log ENABLE ROW LEVEL SECURITY;
DO $p$ BEGIN
  CREATE POLICY "service_role_all" ON public.retention_run_log
    TO service_role USING (true) WITH CHECK (true);
EXCEPTION WHEN duplicate_object THEN NULL; END $p$;

-- ── 3. The runner ────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.retention_tick(p_global_budget_seconds integer DEFAULT 240)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_tick_start timestamptz := clock_timestamp();
  v_pol        RECORD;
  v_cutoff     timestamptz;
  v_pol_start  timestamptz;
  v_batch      bigint;
  v_pol_total  bigint;
  v_total      bigint := 0;
  v_colcheck   boolean;
BEGIN
  IF current_user NOT IN ('service_role','postgres','supabase_admin') THEN
    RAISE EXCEPTION 'forbidden: retention_tick is service-only' USING ERRCODE='42501';
  END IF;

  FOR v_pol IN
    SELECT * FROM public.retention_policy WHERE enabled ORDER BY priority, table_name
  LOOP
    EXIT WHEN clock_timestamp() - v_tick_start > make_interval(secs => p_global_budget_seconds);

    -- validate target before touching it (policy rows are data — trust nothing)
    IF to_regclass('public.' || v_pol.table_name) IS NULL THEN
      UPDATE public.retention_policy
         SET last_error = 'table not found', last_run_at = now(), updated_at = now()
       WHERE table_name = v_pol.table_name;
      CONTINUE;
    END IF;
    SELECT EXISTS (
      SELECT 1 FROM information_schema.columns
       WHERE table_schema='public' AND table_name=v_pol.table_name AND column_name=v_pol.ts_column
    ) INTO v_colcheck;
    IF NOT v_colcheck THEN
      UPDATE public.retention_policy
         SET last_error = format('ts_column %s not found', v_pol.ts_column),
             last_run_at = now(), updated_at = now()
       WHERE table_name = v_pol.table_name;
      CONTINUE;
    END IF;

    v_cutoff    := now() - make_interval(days => v_pol.keep_days);
    v_pol_start := clock_timestamp();
    v_pol_total := 0;

    BEGIN
      LOOP
        EXIT WHEN clock_timestamp() - v_pol_start  > make_interval(secs => v_pol.budget_seconds);
        EXIT WHEN clock_timestamp() - v_tick_start > make_interval(secs => p_global_budget_seconds);
        EXECUTE format(
          'WITH del AS (SELECT ctid FROM public.%I WHERE %I < $1 LIMIT $2) '
          'DELETE FROM public.%I WHERE ctid IN (SELECT ctid FROM del)',
          v_pol.table_name, v_pol.ts_column, v_pol.table_name)
        USING v_cutoff, v_pol.batch_rows;
        GET DIAGNOSTICS v_batch = ROW_COUNT;
        v_pol_total := v_pol_total + v_batch;
        EXIT WHEN v_batch = 0;
      END LOOP;

      UPDATE public.retention_policy
         SET last_run_at = now(), last_deleted = v_pol_total,
             total_deleted = total_deleted + v_pol_total,
             last_error = NULL, updated_at = now()
       WHERE table_name = v_pol.table_name;
      INSERT INTO public.retention_run_log (table_name, cutoff, deleted, duration_ms, note)
      VALUES (v_pol.table_name, v_cutoff, v_pol_total,
              (extract(epoch FROM clock_timestamp() - v_pol_start) * 1000)::int,
              CASE WHEN v_pol_total = 0 THEN 'clean' ELSE NULL END);

    EXCEPTION
      WHEN query_canceled THEN
        -- statement_timeout fired mid-policy (WHEN OTHERS would NOT catch this — §3)
        UPDATE public.retention_policy
           SET last_run_at = now(), last_error = 'query_canceled (statement_timeout)',
               updated_at = now()
         WHERE table_name = v_pol.table_name;
        RETURN v_total + v_pol_total;
      WHEN OTHERS THEN
        UPDATE public.retention_policy
           SET last_run_at = now(), last_error = left(SQLERRM, 500), updated_at = now()
         WHERE table_name = v_pol.table_name;
        INSERT INTO public.retention_run_log (table_name, cutoff, deleted, duration_ms, note)
        VALUES (v_pol.table_name, v_cutoff, v_pol_total, NULL, 'ERROR: ' || left(SQLERRM, 300));
    END;

    v_total := v_total + v_pol_total;
  END LOOP;

  RETURN v_total;
END $function$;

REVOKE ALL ON FUNCTION public.retention_tick(integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.retention_tick(integer) TO service_role;
COMMENT ON FUNCTION public.retention_tick(integer) IS
  'Unified TTL enforcement driven by retention_policy. Unordered ctid-batched deletes; '
  'wall-clock budgets per policy AND per tick (scheduler-wedge rule); per-policy errors '
  'recorded, never abort the whole tick. Hourly cron retention_tick_hourly. '
  'Replaces sweep-old-* cron family (mig 20260705153000).';

-- ── 4. Seed the ladder (current operator-set windows; ON CONFLICT keeps live edits) ──

INSERT INTO public.retention_policy
  (table_name, ts_column, keep_days, enabled, batch_rows, budget_seconds, priority, notes)
VALUES
  ('listings_snapshots', 'captured_at', 15, true, 50000, 90, 10,
   'Raw TEvo/EVO listing firehose — 15d (migs 20260603190000/20260605150900). ~36d retained at redesign time; backlog drains over the first days of ticks. Partition BLUEPRINT 20260619220000 (A1-OPS-18) supersedes with partition-drop when it lands.'),
  ('ticketsdata_listings_snapshots', 'captured_at', 30, true, 20000, 60, 20,
   'TD 5-platform raw listings — 30d (wave1 20260531180000). Writers ACTIVE (TM/AXS/SG-burn); audit AUD-16 called for immediate reactivation.'),
  ('section_metrics', 'captured_at', 60, true, 50000, 60, 30,
   'Per-section aggregates — 60d (wave1). Daily per-venue-section medians preserved INDEFINITELY in venue_section_price_daily (mig 20260705153500) before raws age out.'),
  ('event_section_row_snapshots', 'captured_at', 30, true, 50000, 60, 40,
   'Section/row snapshots — 30d (wave1). Replaces cron sweep-old-event-section-rows.'),
  ('event_metrics', 'captured_at', 120, true, 50000, 45, 50,
   'Event-level aggregates — 120d (operator-set, wave1). Was piggybacked inside sweep_old_listings(); now its own policy row.'),
  ('espn_injuries_snapshots', 'captured_at', 90, true, 20000, 30, 60,
   '90d (wave1). Replaces cron sweep-old-espn-injuries.'),
  ('seatgeek_listings_snapshots', 'captured_at', 30, false, 20000, 60, 70,
   'DISABLED pending operator decision (audit AUD-16): SG listings pollers dark since 2026-06-26 — a 30d TTL on a dark table drains it to EMPTY. Flip enabled=true with (or after) the SG-listings resume.'),
  ('retention_run_log', 'run_at', 90, true, 10000, 10, 90,
   'Self-housekeeping for the retention audit log.')
ON CONFLICT (table_name) DO NOTHING;

-- ── 5. Retire the per-table sweep crons (migration trail for the supersede) ──

DO $do$
DECLARE r RECORD;
BEGIN
  FOR r IN SELECT jobid, jobname FROM cron.job
           WHERE jobname IN ('sweep-old-listings','sweep-old-sg-listings','sweep-old-td-listings',
                             'sweep-old-section-metrics','sweep-old-event-section-rows',
                             'sweep-old-espn-injuries')
  LOOP
    PERFORM cron.unschedule(r.jobid);
  END LOOP;
END $do$;

INSERT INTO public.cron_policy (jobname, peak_hours_et, peak_min_interval_min,
  offpeak_min_interval_min, daily_max_fires, enabled, notes)
VALUES
  ('sweep-old-listings',           ARRAY[]::int[], 1440, 1440, 0, false, 'RETIRED 2026-07-05 — superseded by retention_tick_hourly (mig 20260705153000).'),
  ('sweep-old-sg-listings',        ARRAY[]::int[], 1440, 1440, 0, false, 'RETIRED 2026-07-05 — superseded by retention_tick_hourly (mig 20260705153000); SG policy row seeded DISABLED pending operator decision.'),
  ('sweep-old-td-listings',        ARRAY[]::int[], 1440, 1440, 0, false, 'RETIRED 2026-07-05 — superseded by retention_tick_hourly (mig 20260705153000).'),
  ('sweep-old-section-metrics',    ARRAY[]::int[], 1440, 1440, 0, false, 'RETIRED 2026-07-05 — superseded by retention_tick_hourly (mig 20260705153000).'),
  ('sweep-old-event-section-rows', ARRAY[]::int[], 1440, 1440, 0, false, 'RETIRED 2026-07-05 — superseded by retention_tick_hourly (mig 20260705153000).'),
  ('sweep-old-espn-injuries',      ARRAY[]::int[], 1440, 1440, 0, false, 'RETIRED 2026-07-05 — superseded by retention_tick_hourly (mig 20260705153000).')
ON CONFLICT (jobname) DO UPDATE
  SET enabled = false, notes = EXCLUDED.notes, updated_at = now();

DO $c$
DECLARE v_fn text;
BEGIN
  FOREACH v_fn IN ARRAY ARRAY['sweep_old_listings','sweep_old_sg_listings','sweep_old_td_listings',
                              'sweep_old_section_metrics','sweep_old_event_section_rows','sweep_old_espn_injuries']
  LOOP
    BEGIN
      EXECUTE format(
        $q$COMMENT ON FUNCTION public.%I(integer) IS 'SUPERSEDED by retention_tick()/retention_policy (mig 20260705153000). Kept for manual use only.'$q$,
        v_fn);
    EXCEPTION WHEN undefined_function THEN NULL;
    END;
  END LOOP;
END $c$;

-- ── 6. Schedule the runner (SET LOCAL scoped in a txn — no pool leak, §3) ────

SELECT cron.schedule(
  'retention_tick_hourly',
  '44 * * * *',
  $cron$BEGIN; SET LOCAL statement_timeout='480s'; DO $b$ BEGIN
    IF NOT public.cron_should_fire('retention_tick_hourly') THEN RETURN; END IF;
    PERFORM public.retention_tick(240);
  END $b$; COMMIT;$cron$
);

INSERT INTO public.cron_policy (jobname, peak_hours_et, peak_min_interval_min,
  offpeak_min_interval_min, daily_max_fires, work_check_sql, enabled, notes)
VALUES ('retention_tick_hourly', ARRAY[]::int[], 60, 60, 24, 'SELECT true', true,
  'Unified TTL retention runner over retention_policy (kill switch = retention_policy.enabled per table, NOT this row). 240s self-budget, 480s SET LOCAL cap. Mig 20260705153000.')
ON CONFLICT (jobname) DO UPDATE
  SET enabled = true, notes = EXCLUDED.notes, updated_at = now();

-- ── 7. Deadman coverage: retention + section rollup join the watch list ──────
-- Body = 20260702000500 version + 2 rows (retention_tick_hourly, venue_section_rollup_hourly).

CREATE OR REPLACE FUNCTION public.record_cron_deadman()
RETURNS integer
LANGUAGE plpgsql
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_n integer;
BEGIN
  WITH watch(jobname, warn_h, fail_h) AS (VALUES
    ('sg_lifetime_sales_daily',            26.0,  50.0),
    ('listings_deltas_backfill_overnight', 26.0,  50.0),
    ('refresh_movers_agg',                 14.0,  26.0),
    ('discovery_gap_refresh',              26.0,  50.0),
    ('event_snapshot_morning',             26.0,  50.0),
    ('event_snapshot_midday',              26.0,  50.0),
    ('event_snapshot_evening',             26.0,  50.0),
    ('espn-rosters-daily',                 26.0,  50.0),
    ('sg_market_chart_reveal_pull_daily',  26.0,  50.0),
    ('sg_market_chart_rebuild_daily',      26.0,  50.0),
    ('tournament_pull_queue_weekly',      192.0, 360.0),
    ('tournament_pull_process_weekly',    192.0, 360.0),
    ('venue_pull_queue_weekly',           192.0, 360.0),
    ('venue_pull_process_weekly',         192.0, 360.0),
    ('td_pending_sweep',                    3.0,   6.0),
    ('event_section_row_rollup_hourly',     3.0,   6.0),
    ('retention_tick_hourly',               3.0,   6.0),
    ('venue_section_rollup_hourly',         3.0,   6.0)
  ),
  state AS (
    SELECT w.jobname, w.warn_h, w.fail_h,
           j.jobid, COALESCE(j.active, false) AS active,
           (SELECT max(d.start_time) FROM cron.job_run_details d
             WHERE d.jobid = j.jobid AND d.status = 'succeeded') AS last_ok
    FROM watch w LEFT JOIN cron.job j ON j.jobname = w.jobname
  )
  INSERT INTO health_check_history (captured_at, check_class, check_name, status, metric, detail)
  SELECT now(), 'cron_deadman', s.jobname,
         CASE
           WHEN s.jobid IS NULL OR NOT s.active THEN 'off'
           WHEN s.last_ok IS NULL THEN 'fail'
           WHEN now() - s.last_ok < make_interval(hours => s.warn_h::int) THEN 'ok'
           WHEN now() - s.last_ok < make_interval(hours => s.fail_h::int) THEN 'warn'
           ELSE 'fail'
         END,
         round((extract(epoch FROM now() - s.last_ok)/3600.0)::numeric, 1),
         'last success ' || COALESCE(to_char(s.last_ok, 'MM-DD HH24:MI'), 'never')
           || ' · gap ' || COALESCE(round((extract(epoch FROM now()-s.last_ok)/3600.0)::numeric,1)::text,'—')
           || 'h · SLA warn ' || s.warn_h::int || 'h / fail ' || s.fail_h::int || 'h'
           || CASE WHEN s.jobid IS NULL OR NOT s.active THEN ' · job OFF/unscheduled' ELSE '' END
  FROM state s;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n;
END $function$;
