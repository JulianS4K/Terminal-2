-- Migration 20260703142000 · lane:A1 (data plane — TicketsData tiered polling)
--   writes on run: cron.job (active=true on td_tier_enqueue_gt/tm/tp)
--   pre: 20260609150000 (td_tier_enqueue_* + td_poll_policy, seeded DISABLED)
--   auth: operator directive 2026-07-03 (julian@s4kent.com — "poll all those events
--         per our polling rules with td")
--
-- ## Applied to prod 2026-07-03 via MCP (idempotent + reversible). Codification.
--
-- WHY ────────────────────────────────────────────────────────────────────────
-- The tiered per-platform enqueue crons (td_tier_enqueue_*, mig 20260609150000)
-- were seeded pg_cron-DISABLED "until the owned-book onboarding begins". SH and VD
-- were already switched on; GT/TM/TP were policy-enabled (cron_policy.enabled=true)
-- but still pg_cron-inactive, so they never fired — those platforms weren't polling
-- per the td_poll_policy tier rules. With the target set expanded to ~1,500 events
-- (mig 20260703140000) the operator is onboarding the full tiered polling, so this
-- activates GT/TM/TP. AXS stays OFF (TicketsData has not shipped AXS).
--
-- Cost stays bounded by td_daily_budget_ok() (credits_today×1.276 < 40000 pre-2026-07-09,
-- 8000 after) + td_pull_drain rate limiting; td_tier_enqueue also self-gates on
-- cron_should_fire + per-event tier cadence, and won't double-enqueue (NOT EXISTS on
-- the pending queue). Rollback: SELECT cron.alter_job(jobid, active:=false) for each.
-- ─────────────────────────────────────────────────────────────────────────────

DO $$ DECLARE j bigint; BEGIN
  FOR j IN SELECT jobid FROM cron.job
           WHERE jobname IN ('td_tier_enqueue_gt','td_tier_enqueue_tm','td_tier_enqueue_tp')
  LOOP
    PERFORM cron.alter_job(j, active := true);
  END LOOP;
END $$;
