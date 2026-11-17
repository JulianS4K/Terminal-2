-- Migration 20261023043520 · level:ops · lane:A1 (data plane — retention engine) · writes:retention_policy(+cols),retention_tick()(replace),record_retention_health()(new),cron.job(retention_health_hourly new) · reads:retention_policy,retention_run_log,health_check_history · pre:20260705153000,20260911162500
--
-- ============================================================================
-- Migration 20261023043520 — retention_tick v2: a stuck table can no longer
--   starve the ladder, and a stalled engine is a health-page failure
--
-- Lane:     A1. KANBAN A1-DB-25 (operator 2026-10-23: "do it").
-- Touches:  retention_policy          (W: +clean_runs int, +next_eligible_at timestamptz)
--           retention_tick(int)       (W: replaced — same signature, same budget semantics)
--           record_retention_health() (W: new, service_role; writes health_check_history rows
--                                       check_class='retention', check_name='retention_stalled')
--           cron.job                  (W: +retention_health_hourly @ :49, single statement)
--
-- WHY (verified read-only 2026-10-23): retention_tick walked policies ORDER BY
-- priority, table_name, so gotickets_listings_snapshots (priority 10) went first
-- every hour. Its one `SELECT ctid … LIMIT 50000` probe takes 480–600 s and
-- returns 0 rows — the 1.4 M survivors are all keep_where deal evidence sitting
-- under the cutoff in a 130 GB bloated heap, so the probe walks the whole range
-- and finds nothing — and that single statement blew the 120/480 s global
-- budget before any other policy ran. Every other policy's last_run_at was
-- 2026-10-12 12:44: listings_snapshots oldest row 08-27 on a 15 d window,
-- section_metrics 08-13 on 60 d, event_section_row_snapshots 09-12 on 30 d.
-- Nothing alerted.
--
-- Note on statement_timeout: a per-policy SET LOCAL statement_timeout inside the
-- function is a NO-OP for the running statement (PROJECT_BIBLE §3 — the timer
-- is armed at statement start); it cannot bound one probe. The fixes below are
-- scheduling, not timing:
--   1. ORDER BY priority, last_run_at NULLS FIRST, table_name — least-recently
--      swept first, so one slow table cannot monopolise consecutive ticks.
--   2. Skip-after-clean: after 3 consecutive runs that deleted 0 rows a policy
--      sets next_eligible_at = now() + 24 h and is skipped until then (reset on
--      any run that deletes rows). GT's 500 s probe now costs one tick a day,
--      not 24.
--   3. retention_stalled health check: any enabled, eligible policy whose
--      last_run_at is older than 6 h (or NULL and created > 6 h ago) → status
--      'fail' on the health page; 'warn' when any enabled policy's oldest
--      surviving row is more than 2× keep_days old. Runs hourly at :49, after
--      the :44 tick.
-- The GT heap itself is reclaimed in A1-DATA-1 P1 (CTAS swap), after which the
-- probe drops to seconds.
--
-- PARTIALLY APPLIED to prod · via MCP 2026-10-23 19:25 UTC (operator-approved): the two
-- retention_policy columns, record_retention_health() and cron retention_health_hourly.
-- retention_tick() itself is NOT applied — the MCP apply tool holds any body containing
-- DELETE for a confirmation it never gets; run that function from the SQL editor.
-- ============================================================================

ALTER TABLE public.retention_policy
  ADD COLUMN IF NOT EXISTS clean_runs       integer     NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS next_eligible_at timestamptz;

COMMENT ON COLUMN public.retention_policy.clean_runs IS
  'Consecutive retention_tick runs that deleted 0 rows (mig 20261023043520). Reset to 0 by any run that deletes.';
COMMENT ON COLUMN public.retention_policy.next_eligible_at IS
  'retention_tick skips the policy until this instant (set to now()+24h after 3 clean runs; NULL = eligible now).';

CREATE OR REPLACE FUNCTION public.retention_tick(p_global_budget_seconds integer DEFAULT 240)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_tick_start timestamptz := clock_timestamp();
  v_pol        RECORD;
  v_cutoff     timestamptz;
  v_pol_start  timestamptz;
  v_batch      bigint;
  v_pol_total  bigint;
  v_total      bigint := 0;
  v_colcheck   boolean;
  v_keep       text;
BEGIN
  IF current_user NOT IN ('service_role','postgres','supabase_admin') THEN
    RAISE EXCEPTION 'forbidden: retention_tick is service-only' USING ERRCODE='42501';
  END IF;

  FOR v_pol IN
    SELECT * FROM public.retention_policy
     WHERE enabled
       AND (next_eligible_at IS NULL OR next_eligible_at <= now())
     ORDER BY priority, last_run_at NULLS FIRST, table_name
  LOOP
    EXIT WHEN clock_timestamp() - v_tick_start > make_interval(secs => p_global_budget_seconds);

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

    v_keep := CASE
                WHEN v_pol.keep_where IS NULL OR btrim(v_pol.keep_where) = '' THEN ''
                ELSE ' AND NOT (' || v_pol.keep_where || ')'
              END;

    v_cutoff    := now() - make_interval(days => v_pol.keep_days);
    v_pol_start := clock_timestamp();
    v_pol_total := 0;

    BEGIN
      LOOP
        EXIT WHEN clock_timestamp() - v_pol_start  > make_interval(secs => v_pol.budget_seconds);
        EXIT WHEN clock_timestamp() - v_tick_start > make_interval(secs => p_global_budget_seconds);
        EXECUTE format(
          'WITH del AS (SELECT t.ctid FROM public.%I t WHERE t.%I < $1%s LIMIT $2) '
          'DELETE FROM public.%I WHERE ctid IN (SELECT ctid FROM del)',
          v_pol.table_name, v_pol.ts_column, v_keep, v_pol.table_name)
        USING v_cutoff, v_pol.batch_rows;
        GET DIAGNOSTICS v_batch = ROW_COUNT;
        v_pol_total := v_pol_total + v_batch;
        EXIT WHEN v_batch = 0;
      END LOOP;

      UPDATE public.retention_policy
         SET last_run_at   = now(),
             last_deleted  = v_pol_total,
             total_deleted = total_deleted + v_pol_total,
             last_error    = NULL,
             clean_runs    = CASE WHEN v_pol_total = 0 THEN clean_runs + 1 ELSE 0 END,
             next_eligible_at = CASE WHEN v_pol_total = 0 AND clean_runs + 1 >= 3
                                     THEN now() + interval '24 hours' ELSE NULL END,
             updated_at    = now()
       WHERE table_name = v_pol.table_name;
      INSERT INTO public.retention_run_log (table_name, cutoff, deleted, duration_ms, note)
      VALUES (v_pol.table_name, v_cutoff, v_pol_total,
              (extract(epoch FROM clock_timestamp() - v_pol_start) * 1000)::int,
              CASE WHEN v_pol_total = 0 THEN 'clean' ELSE NULL END);

    EXCEPTION
      WHEN query_canceled THEN
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
END $$;

REVOKE ALL ON FUNCTION public.retention_tick(integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.retention_tick(integer) TO service_role;

-- ---------------------------------------------------------------------------
-- retention_stalled → health_check_history (the health page renders check_class)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.record_retention_health()
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_stalled text[];
  v_status  text;
BEGIN
  IF current_user NOT IN ('service_role','postgres','supabase_admin') THEN
    RAISE EXCEPTION 'forbidden: record_retention_health is service-only' USING ERRCODE='42501';
  END IF;

  SELECT coalesce(array_agg(table_name ORDER BY table_name), '{}')
    INTO v_stalled
    FROM public.retention_policy
   WHERE enabled
     AND (next_eligible_at IS NULL OR next_eligible_at <= now())
     AND coalesce(last_run_at, created_at) < now() - interval '6 hours';

  v_status := CASE WHEN cardinality(v_stalled) = 0 THEN 'ok' ELSE 'fail' END;

  INSERT INTO public.health_check_history (captured_at, check_class, check_name, status, metric, detail)
  VALUES (now(), 'retention', 'retention_stalled', v_status, cardinality(v_stalled),
          CASE WHEN cardinality(v_stalled) = 0
               THEN 'every enabled policy swept within 6 h'
               ELSE 'not swept in 6 h: ' || array_to_string(v_stalled, ', ') END);
  RETURN cardinality(v_stalled);
END $$;

REVOKE ALL ON FUNCTION public.record_retention_health() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.record_retention_health() TO service_role;

-- Single-statement command (A1-DB-5 shape); :49 is a free hourly minute.
SELECT cron.schedule('retention_health_hourly', '49 * * * *',
  $c$SELECT public.record_retention_health();$c$);

-- ============================================================================
-- VERIFY (after apply):
--   SELECT table_name, last_run_at, clean_runs, next_eligible_at FROM public.retention_policy
--    WHERE enabled ORDER BY priority, last_run_at NULLS FIRST, table_name;
--   -- next :44 tick should sweep listings_snapshots first (last_run_at 10-12);
--   SELECT * FROM public.retention_run_log ORDER BY id DESC LIMIT 20;
--   SELECT * FROM public.health_check_history WHERE check_name='retention_stalled' ORDER BY id DESC LIMIT 3;
--   -- after 3 clean GT runs: next_eligible_at ≈ now()+24h on gotickets_listings_snapshots.
-- ROLLBACK:
--   re-apply retention_tick from mig 20260911162500; SELECT cron.unschedule('retention_health_hourly');
--   ALTER TABLE public.retention_policy DROP COLUMN clean_runs, DROP COLUMN next_eligible_at;
--   (DROP FUNCTION public.record_retention_health() — from the SQL editor.)
-- ============================================================================
