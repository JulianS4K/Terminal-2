-- ============================================================================
-- Migration 20260702140030 — pause the two bot_chat noise-poster crons
--   (prefix bumped +30s off 20260702140000 to clear the timestamp collision with
--    20260702140000_a1_security_close_d0_view_leak_and_fn_lockdown.sql per
--    MIGRATION_CONVENTIONS.md rule #2)
--
-- Lane:     A1 (cron topology) · operator-authorized (julian@s4kent.com, 2026-07-02:
--           "pause only bot chat noise and anything claude bot related")
-- Touches:  cron.job.active + public.cron_policy.enabled for two jobs ONLY. No fn/DDL.
-- Reads:    cron.job (jobid lookup by name), public.cron_policy.
--
-- WHY:
--   The `v_bot_chat_unresolved` monitor had re-accumulated ~1,850 unresolved rows,
--   ~1,666 of them auto-`status` noise, burying ~163 genuinely-aged flag/question
--   items. Two active crons are the sole generators of that noise:
--
--     * compute_movers_index_post_snapshot  → compute_event_movers_index_all()
--         posts one `status` per source×window ("movers(<src>, <win>): 0 events
--         upserted") every run — 30 rows/run, and currently upserting NOTHING
--         (the movers pipeline is frozen per the 2026-07-02 SQL/crons audit),
--         so it is pure noise with zero useful output.
--     * sg_broker_429_health_check_15min    → check_sg_broker_429_health()
--         posts SG_BROKER_429 `flag` rows on a 15-min probe.
--
--   Pausing both stops new noise at the source. The one-time backlog re-sweep and
--   the never-deployed `coordination.bot_chat_aging_7d` monitor are handled
--   separately on this branch.
--
--   NOTE: pausing compute_movers_index_post_snapshot also halts the D0 movers-index
--   refresh — acceptable because it is producing 0 rows today (audit AUD-07); it can
--   be reactivated (with the movers pipeline fix) by reverting this migration.
--
--   Toggled via migration (not out-of-band cron.alter_job) per the 2026-07-02 audit's
--   cross-cutting rule: cron activation state changes only via migration, and both
--   control planes (cron.job.active + cron_policy.enabled) are moved together so they
--   cannot drift (audit AUD-15).
--
-- ## Already applied to prod
-- Applied via mcp apply_migration on 2026-07-02 under the operator directive above.
-- Idempotent: the cron.alter_job toggles and the guarded notes-append re-run as no-ops.
-- ============================================================================

DO $$
DECLARE
  jid   integer;
  jname text;
BEGIN
  FOREACH jname IN ARRAY ARRAY[
    'compute_movers_index_post_snapshot',
    'sg_broker_429_health_check_15min'
  ]
  LOOP
    SELECT jobid INTO jid FROM cron.job WHERE jobname = jname;
    IF jid IS NOT NULL THEN
      PERFORM cron.alter_job(job_id := jid, active := false);
    END IF;
  END LOOP;
END $$;

UPDATE public.cron_policy
   SET enabled = false,
       notes   = CASE WHEN notes LIKE '%PAUSED 2026-07-02 mig%'
                      THEN notes
                      ELSE notes || ' [PAUSED 2026-07-02 mig 20260702140030: bot_chat noise poster, operator-authorized]'
                  END,
       updated_at = now()
 WHERE jobname IN ('compute_movers_index_post_snapshot','sg_broker_429_health_check_15min');
