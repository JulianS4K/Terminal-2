-- Migration 20261021174000 · level:admin · lane:A1 (cron owner; D4/Exos source lives in JulianS4K/EXP) · writes:cron.job (16 active flags) · reads:none · pre:none
--
-- ============================================================================
-- Migration 20261021174000 — pause every Exos cron while Exos is pre-launch
--
-- Lane:     A1 (crons) · operator-directed 2026-10-21, two steps:
--           "exos was moved to separate git so you can ignore for now, but turn
--           off since they do nothing" → the 2 always-failing jobs; then
--           "Yes — pause all 14 too" for the rest. KANBAN A1-DB-14.
-- Touches:  cron.job: active := false on all 16 active Exos jobs (list below).
--           Not unscheduled — commands, schedules and cron_policy rows stay
--           for EXP to re-enable.
-- Pre-reqs: none. Reversible: cron.alter_job(<jobid>, active := true).
--
-- Already applied to prod · via MCP 2026-10-21 under operator direction, in two
--   steps (schema_migrations rows `20261021174000_exos_dead_crons_off` = 253 + 669,
--   `20261021174500_exos_all_crons_off` = the other 14; this single file is the
--   idempotent union). Verified post-apply: 0 active Exos jobs, 16 inactive;
--   total active crons 211 → 194.
--
-- WHY: in the 24 h to 2026-10-21 17:00 UTC
--   * 253 exos-mail-drain-2min called `exos-mail-drain` 670× → 670 × HTTP 500
--     ("server misconfigured: RESEND_API_KEY / EXOS_MAIL_FROM unset"; secrets
--     never set — v1 KANBAN D4-OPS-8/19). `exos_mail` has 0 rows ever.
--   * 669 exos-wallet-push-5min called `exos-wallet/push` 288× → 288 × 503
--     ("wallet not configured").
--   * The other 14 complete but have nothing to process (Exos is pre-launch:
--     11 auth users, all staff; no live events) — ~5,000 cron runs/day on the
--     launcher that is already the bottleneck (A1-DB-5), for nothing.
--
-- Re-enable (from EXP, once Exos goes live and the mail/wallet config exists):
--   SELECT cron.alter_job(jobid, active := true) FROM cron.job
--   WHERE jobname IN (<the 16 names below>);
-- ============================================================================

DO $$
DECLARE
  v_names text[] := ARRAY[
    -- step 1 (always failing)
    'exos-mail-drain-2min', 'exos-wallet-push-5min',
    -- step 2 (completing, but nothing to do pre-launch)
    'exos_expire_holds', 'exos_send_event_reminders', 'exos_send_checkout_reminders',
    'exos_send_mail_followups', 'exos-reconcile-checkouts-15min', 'exos-webhook-drain-3min',
    'exos-geocode-refresh-daily', 'exos-payouts-daily', 'exos-eventbrite-sync-2min',
    'exos-channel-split-hourly', 'exos-s4k-feed-1min', 'exos-integrations-sync-2min',
    'exos-sms-drain-1min', 'exos-channel-sync-2min'
  ];
  r record;
  n int := 0;
BEGIN
  FOR r IN SELECT jobid FROM cron.job WHERE jobname = ANY (v_names) AND active LOOP
    PERFORM cron.alter_job(r.jobid, active := false);
    n := n + 1;
  END LOOP;
  RAISE NOTICE '20261021174000: % Exos cron jobs deactivated', n;
END $$;

-- Post-apply check (expect 0):
--   SELECT count(*) FROM cron.job WHERE active AND (jobname ILIKE '%exos%' OR command ILIKE '%exos%');
