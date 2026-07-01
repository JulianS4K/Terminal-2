-- ============================================================================
-- Migration 20260630300000 — cron resource hardening (timeout pattern + lock_timeout + de-cluster)
--
-- Lane:     A1
-- Touches:  cron commands for the 10 jobs using the no-op `SET LOCAL statement_timeout` pattern;
--           lock_timeout on the mutation-heavy sweeps/backfill; reschedule the fixed-:25 cluster.
-- Pre-reqs: none (cron.alter_job only). Maintains the existing per-source / collector_cadence structure.
--
-- WHY (operator 2026-06-30 "cron logic improvements for Supabase resources/limits/failure conditions"):
--   Binding limit = cron.max_running_jobs=32 (use_background_workers=off; max_connections=160 is NOT the
--   constraint). Default statement_timeout=120s; lock_timeout=0 (unbounded). Failure signals: 120s
--   statement-timeouts on heavy jobs + ~25 "job startup timeout" slot-exhaustion skips/24h clustered at :25.
--
--   PART A — fix the no-op timeout. 10 active crons raise their budget via `DO $$ ... SET LOCAL
--     statement_timeout ... $$`, which does NOTHING: the DO statement's 120s timer is armed before the inner
--     SET LOCAL runs and is never re-armed. Rewrite each as a standalone `SET statement_timeout=<claimed>`
--     prepended BEFORE the DO block (a SET as its own top-level statement DOES apply to the next statement),
--     and strip the dead inner SET LOCAL. Preserves each body/guard verbatim.
--   PART B — fail-fast on locks. Add `SET lock_timeout='10s'` to the mutation-heavy sweeps/backfill so a
--     lock wait aborts fast instead of burning the full statement_timeout while holding one of 32 slots.
--   PART C — de-cluster :25. Move the 4 fixed-:25 jobs to quiet neighbors (:23/:27/:53) to thin the
--     saturated minute (recurring */5,*/10 jobs that also hit :25 are left; Part A frees their slots faster).
--
-- Idempotent: Part A's loop only matches jobs that still contain `SET LOCAL statement_timeout` (removed on
-- first run); reschedules are by-name set-values. Re-apply is a no-op.
-- ============================================================================

-- PART A + B: convert no-op SET LOCAL -> effective SET statement_timeout (+ lock_timeout for mutators).
DO $do$
DECLARE
  r RECORD; v_to text; v_body text; v_prefix text;
  mutators text[] := ARRAY[
    'sweep-old-sg-listings','sweep_duplicate_listings_hourly','sweep_terminal_event_listings_hourly',
    'midnight-catchup-sweep','orphan_event_backfill_queue_15min'];
BEGIN
  FOR r IN SELECT jobid, jobname, command FROM cron.job
           WHERE active AND command ~* 'SET\s+LOCAL\s+statement_timeout'
  LOOP
    v_to     := substring(r.command from 'SET\s+LOCAL\s+statement_timeout\s*=\s*''([^'']*)''');
    v_body   := regexp_replace(r.command,
                  'SET\s+LOCAL\s+statement_timeout\s*=\s*''[^'']*''\s*;?', '', 'gi');
    v_prefix := 'SET statement_timeout=''' || coalesce(v_to,'120s') || '''; ';
    IF r.jobname = ANY(mutators) THEN
      v_prefix := v_prefix || 'SET lock_timeout=''10s''; ';
    END IF;
    PERFORM cron.alter_job(job_id := r.jobid, command := v_prefix || v_body);
  END LOOP;
END $do$;

-- PART C: de-cluster the fixed-:25 jobs.
DO $do$
BEGIN
  PERFORM cron.alter_job((SELECT jobid FROM cron.job WHERE jobname='td_pending_sweep'),
                         schedule := '23 * * * *');
  PERFORM cron.alter_job((SELECT jobid FROM cron.job WHERE jobname='wiki_pending_sweep_daily'),
                         schedule := '23 3 * * *');
  PERFORM cron.alter_job((SELECT jobid FROM cron.job WHERE jobname='sweep-old-section-metrics'),
                         schedule := '27 3,9,15,21 * * *');
  PERFORM cron.alter_job((SELECT jobid FROM cron.job WHERE jobname='venue_geocode_process_5min'),
                         schedule := '23,53 * * * *');
END $do$;
