-- Migration 20260616201700 · lane:D0 (author) · APPLIED LIVE 2026-06-16 by operator directive · writes(DDL):td_monthly_budget_ok(), td_daily_budget_ok() · writes(cron):pauses all prior non-AXS TicketsData crons · reads:cron.job · spends:nothing (pause + cap, reduces spend) · pre:20260609140000_td_budget_caps_raise_250k_plan · auth:operator-requested 2026-06-16 ("pause all prior tickets data crons and assume this plan for now, mark that 150000 is strictly for AXS and 100k is for rest combined")
--
-- WHY ───────────────────────────────────────────────────────────────────────
-- Operator reset of the TicketsData (non-AXS) pull regime. Going-forward plan:
-- only pull SH/VD/GT/TM for (a) events <=30d out where we own tickets, (b) ALL
-- World Cup games, (c) ALL US Open tennis games. TickPick (TP) is dropped
-- entirely; Ticketmaster (TM) is kept only where it actually returns data.
-- The new reduced cron set is NOT built here ("assume this plan for now") — this
-- migration only (1) PAUSES the entire prior TD cron regime so nothing pulls
-- under the old rules, and (2) marks the new credit-budget split.
--
-- BUDGET SPLIT (operator 2026-06-16) ────────────────────────────────────────
--   AXS .................... 150,000  (STRICT, AXS-only)
--   Rest (SH/VD/GT/TM) .....  100,000  (combined; TP off)
-- AXS runs on a SEPARATE pool: it is pulled by axs_probe_step() (cron
-- axs-probe-drain) and its quota is tracked provider-side
-- (axs_event_snapshots.quota_remaining). AXS does NOT write to
-- ticketsdata_credit_usage, so the td_*_budget_ok gates below govern the
-- NON-AXS "rest" pool only. The 150k AXS figure is recorded here as the
-- governing allocation; there is no in-DB gate for it yet (build a
-- axs_*_budget_ok gate if hard enforcement is wanted — would need an AXS
-- credit log, since today only the provider's quota_remaining is observed).
--
-- NON-AXS cap: monthly 180,000 -> 100,000 ; daily 6,000 -> 4,000 (smoothing
-- cap coherent with 100k/mo). MTD non-AXS spend at cutover was ~5.2k, so the
-- new cap takes effect with full headroom.
-- ─────────────────────────────────────────────────────────────────────────────

-- 1. Pause the entire prior non-AXS TicketsData cron regime (enqueue, tier,
--    drain, normalize, discover, match, watchlist, sweeps, knicks reconcile).
--    AXS (axs-probe-drain) and all non-TD pipelines (SeatGeek, SeatData, EVO,
--    AQ resolvers) are intentionally left running.
DO $$
DECLARE r record; n int := 0;
BEGIN
  FOR r IN
    SELECT jobid FROM cron.job
    WHERE active = true
      AND ( jobname LIKE 'td\_%' ESCAPE '\'
            OR jobname IN ('td-reconcile-knicks-finals-daily','sweep-old-td-listings') )
  LOOP
    PERFORM cron.alter_job(r.jobid, active := false);
    n := n + 1;
  END LOOP;
  RAISE NOTICE 'Paused % prior non-AXS TicketsData crons', n;
END $$;

-- 2. Mark the "100k for the rest combined" non-AXS pool.
CREATE OR REPLACE FUNCTION public.td_monthly_budget_ok()
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $function$ SELECT public.td_credits_this_month() < 100000; $function$;
REVOKE ALL ON FUNCTION public.td_monthly_budget_ok() FROM anon, public;
COMMENT ON FUNCTION public.td_monthly_budget_ok() IS
  'True if MTD recorded non-AXS TicketsData credits < 100,000 (operator split 2026-06-16: 100k for SH/VD/GT/TM combined, TP off; AXS funded separately at 150k, tracked provider-side).';

CREATE OR REPLACE FUNCTION public.td_daily_budget_ok()
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $function$ SELECT public.td_credits_today() < 4000; $function$;
REVOKE ALL ON FUNCTION public.td_daily_budget_ok() FROM anon, public;
COMMENT ON FUNCTION public.td_daily_budget_ok() IS
  'True if today''s recorded non-AXS TicketsData credits < 4,000 (smoothing cap under the 100k/mo non-AXS pool, operator 2026-06-16).';
