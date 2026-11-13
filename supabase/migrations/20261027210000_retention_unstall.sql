-- Migration 20261027210000 · level:ops · lane:A1 (data plane — retention engine) · writes:retention_tick()(replace),retention_policy(2 rows),cron_policy(1 row) · reads:retention_policy,retention_run_log · pre:20261023043520
--
-- KANBAN A1-DB-25 — retention engine stalled since 2026-10-12 (operator 2026-10-27: "start on A1-DB-25").
--
-- 20261023043520 was only PARTLY applied: the clean_runs/next_eligible_at columns,
-- record_retention_health() and cron retention_health_hourly are live, but retention_tick()
-- itself never was. The old body still walks ORDER BY priority, so the two priority-10 tables
-- eat every tick: gotickets_listings_snapshots probes 380-890 s for 0 rows (every survivor is
-- keep_where deal evidence; poller off since 09-27) and listings_snapshots needs ~370 s per
-- 50 k batch (~135 rows/s on a 67 GB heap with 5 indexes). retention_stalled has been 'fail'
-- every hour for 11 policies.
--
-- 1. retention_tick: the v2 body from 20261023043520, but ordered least-recently-swept FIRST
--    (last_run_at NULLS FIRST, then priority). Ordering by priority first would still let the
--    two slow priority-10 tables starve priorities 20-100 every tick; round-robin by staleness
--    guarantees each enabled policy a turn.
-- 2. listings_snapshots batch_rows 50 000 -> 10 000: the per-policy budget is only checked
--    between batches, so a batch must fit inside it (~75 s at the measured rate).
-- 3. gotickets_listings_snapshots parked 7 days (next_eligible_at). Nothing is writing to it
--    and nothing in it is deletable; the 130 GB heap is reclaimed by the A1-DATA-1 CTAS swap,
--    after which the probe is cheap and the park can lapse.
SET LOCAL lock_timeout = '10s';

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
     ORDER BY last_run_at NULLS FIRST, priority, table_name
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

UPDATE public.retention_policy SET batch_rows = 10000, updated_at = now()
 WHERE table_name = 'listings_snapshots' AND batch_rows > 10000;

UPDATE public.retention_policy
   SET next_eligible_at = now() + interval '7 days', updated_at = now(),
       notes = notes || ' PARKED 2026-10-27 (A1-DB-25): no writer since 09-27 and every surviving row is keep_where evidence, so each sweep cost 6-15 min for 0 rows. Reclaim via A1-DATA-1 CTAS swap.'
 WHERE table_name = 'gotickets_listings_snapshots' AND next_eligible_at IS NULL;

-- 4. cron gate: with a 60-min minimum interval every other hourly fire was 'skip_offpeak' —
--    the fire is logged a few ms after :44:00, so the next :44 check sees 59m59.9s. 55 min.
UPDATE public.cron_policy
   SET peak_min_interval_min = 55, offpeak_min_interval_min = 55, updated_at = now(),
       notes = notes || ' 2026-10-27 (A1-DB-25): 60 -> 55 min; a 60-min gate skipped every other hourly fire (fire logged ms after :44:00).'
 WHERE jobname = 'retention_tick_hourly' AND offpeak_min_interval_min = 60;

-- VERIFY: next :44 tick sweeps the 10-12 policies first;
--   SELECT table_name, last_run_at, last_deleted, clean_runs, next_eligible_at FROM retention_policy WHERE enabled ORDER BY last_run_at;
--   SELECT status, detail FROM health_check_history WHERE check_name='retention_stalled' ORDER BY id DESC LIMIT 1;
