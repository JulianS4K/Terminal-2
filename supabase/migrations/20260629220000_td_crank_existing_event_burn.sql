-- Migration 20260629220000 · lane:A1 (DB + cron — TicketsData burn config) · writes (DDL):td_daily_budget_ok(),td_monthly_budget_ok(),td_budget_ok(); on run:td_poll_policy,cron_policy,crons td_tier_enqueue_{sh,vd,gt,tm}/td_pull_drain/td_normalize_drain · reads:ticketsdata_credit_usage · pre:20260627* · auth:operator-approved 2026-06-29 (julian@s4kent.com — burn ~240k prepaid TicketsData credits by July 9, keep 20% reserve; "hit the existing events more often")
--
-- WHY: ~240k prepaid TicketsData credits expire July 9 (use-it-or-lose-it). At the prior
-- cadence (hot=12h refresh, enqueue twice-hourly, drain 5/min, daily cap 6k) burn was ~295/day.
-- Crank polling of the ~223 already-tracked events (SH/VD/GT/TM/TP) to spend the pool, while
-- holding back 20% via a pool floor. No new scope/sources — frequency only.
--
-- WHAT:
-- 1. Raise the internal caps (daily 6k→50k, monthly 180k→600k) so cadence — not the cap —
--    governs. Reserve is enforced by the floor below, not the calendar caps.
-- 2. RESERVE FLOOR in td_budget_ok(): stop ALL TD polling once the upstream pool
--    (ticketsdata_credit_usage.quota_remaining, latest) drops to ≤ 48,000 (~20% of ~240k).
--    Every TD enqueue/pull/discover gates on td_budget_ok, so this is the hard 20% hold-back.
-- 3. Shorten per-tier poll intervals (td_poll_policy, non-AXS): hot/warm 15m, cool 30m,
--    cold 60m, frozen 120m (peak).
-- 4. Lower the enqueue min-interval floor (cron_policy) 15m→5m and run the enqueue crons
--    every 5 min (staggered), so the shorter poll intervals actually take effect.
-- 5. Lift drain throughput: td_pull_drain 5→20/min (28.8k/day ceiling), normalize 50→100.
--
-- PROJECTED: ~223 events × ~15–30m cadence ≈ ~15–21k credits/day; reaches the 48k floor
-- (≈80% burned) around July 8–9, then auto-halts holding the 20% reserve. AXS rides the same
-- pool separately (~230/day, single-threaded scraper — cannot absorb a large share).
-- SAFETY: ~15/min sustained to ticketsdata.com is within the prepaid plan's implied rate.
-- Fully reversible (restore intervals/caps/schedules; drop the floor clause).
-- ROLLBACK: caps→6k/180k; td_budget_ok→daily AND monthly (no floor); poll_policy→prior
-- (720/888/1440/4320/10080); cron_policy enqueue→15m; enqueue crons→twice-hourly; drains→5/50.

CREATE OR REPLACE FUNCTION public.td_daily_budget_ok() RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public','pg_temp'
AS $$ SELECT public.td_credits_today() < 50000; $$;

CREATE OR REPLACE FUNCTION public.td_monthly_budget_ok() RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public','pg_temp'
AS $$ SELECT public.td_credits_this_month() < 600000; $$;

CREATE OR REPLACE FUNCTION public.td_budget_ok() RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public','pg_temp'
AS $$
  SELECT public.td_daily_budget_ok() AND public.td_monthly_budget_ok()
     AND COALESCE((SELECT u.quota_remaining FROM public.ticketsdata_credit_usage u
                   WHERE u.quota_remaining IS NOT NULL ORDER BY u.called_at DESC LIMIT 1), 1000000) > 48000;
$$;

UPDATE public.td_poll_policy SET
  peak_min = CASE tier WHEN 'hot' THEN 15 WHEN 'warm' THEN 15 WHEN 'cool' THEN 30 WHEN 'cold' THEN 60 WHEN 'frozen' THEN 120 ELSE peak_min END,
  offpeak_min = CASE tier WHEN 'hot' THEN 15 WHEN 'warm' THEN 20 WHEN 'cool' THEN 45 WHEN 'cold' THEN 90 WHEN 'frozen' THEN 180 ELSE offpeak_min END
WHERE platform <> 'AXS';

UPDATE public.cron_policy SET peak_min_interval_min = 5, offpeak_min_interval_min = 5
WHERE jobname IN ('td_tier_enqueue_sh','td_tier_enqueue_vd','td_tier_enqueue_gt','td_tier_enqueue_tm');

SELECT cron.schedule('td_tier_enqueue_sh','0-59/5 * * * *', $$SELECT public.td_tier_enqueue('SH')$$);
SELECT cron.schedule('td_tier_enqueue_vd','1-59/5 * * * *', $$SELECT public.td_tier_enqueue('VD')$$);
SELECT cron.schedule('td_tier_enqueue_gt','2-59/5 * * * *', $$SELECT public.td_tier_enqueue('GT')$$);
SELECT cron.schedule('td_tier_enqueue_tm','3-59/5 * * * *', $$SELECT public.td_tier_enqueue('TM')$$);
SELECT cron.schedule('td_pull_drain','* * * * *', $$DO $b$ BEGIN PERFORM public.td_pull_drain(20); END $b$;$$);
SELECT cron.schedule('td_normalize_drain','*/2 * * * *', $$DO $b$ BEGIN PERFORM public.td_normalize_drain(100); END $b$;$$);
