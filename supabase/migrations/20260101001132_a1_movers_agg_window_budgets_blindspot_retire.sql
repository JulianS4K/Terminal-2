-- ============================================================================
-- Migration 20260701224500 — movers-agg per-window budgets + retire vestigial blindspot refresh
--
-- Lane:     A1
-- Touches:  cron 'refresh_movers_agg' (command); cron 'tevo_blindspot_metrics_refresh_12h' (active=false).
-- Pre-reqs: refresh_event_movers_agg(int); postgres-role statement_timeout=900s (mig 20260701213000).
--
-- WHY (operator 2026-07-01 "investigate 3 and 4"):
--   refresh_movers_agg (the heaviest legit job: Tier-1 event_movers_agg cache feeding the movers
--   index) looped 5 windows [7,15,30,180,365] inside ONE DO statement -> a single shared 900s
--   budget (observed avg ~615s, max 806s — too tight), and because EXCEPTION WHEN OTHERS cannot
--   trap query_canceled (§3 landmine), a timeout mid-loop killed ALL remaining windows. Split into
--   per-window top-level statements: each window now gets its OWN 900s budget and a timeout in one
--   window no longer kills the rest. The cron_should_fire gate is evaluated ONCE and carried via a
--   session GUC (per-statement gate calls could self-suppress on the gate's min-interval).
--
--   tevo_blindspot_metrics_refresh_12h (100% fail) is VESTIGIAL: its fn only (a) refreshes
--   latest_event_metrics — already refreshed 72x/day by latest_event_metrics_refresh_5min — and
--   (b) counts v_tevo_blindspot_movers into a DISCARDED return value (that count is what timed
--   out). The Discovery blindspot panels read live RPCs (get_blind_spots_tevo_selling /
--   get_sg_blindspot_evo_tracking); nothing consumes this job. Retired (active=false, reversible).
--
-- Idempotent: cron.alter_job by name. Re-apply is a no-op.
-- Already applied to prod · via MCP 2026-07-01
-- ============================================================================

DO $do$
BEGIN
  PERFORM cron.alter_job(
    (SELECT jobid FROM cron.job WHERE jobname='refresh_movers_agg'),
    command := $cmd$SELECT set_config('app.movers_go', public.cron_should_fire('refresh_movers_agg')::text, false);
SELECT public.refresh_event_movers_agg(7)   WHERE current_setting('app.movers_go') = 'true';
SELECT public.refresh_event_movers_agg(15)  WHERE current_setting('app.movers_go') = 'true';
SELECT public.refresh_event_movers_agg(30)  WHERE current_setting('app.movers_go') = 'true';
SELECT public.refresh_event_movers_agg(180) WHERE current_setting('app.movers_go') = 'true';
SELECT public.refresh_event_movers_agg(365) WHERE current_setting('app.movers_go') = 'true';$cmd$);

  PERFORM cron.alter_job(
    (SELECT jobid FROM cron.job WHERE jobname='tevo_blindspot_metrics_refresh_12h'),
    active := false);
END $do$;
