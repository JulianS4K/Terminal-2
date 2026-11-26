-- Migration 20261125205000 · level:data-collection · lane:a1 (TicketsData budget) · writes:td_credits_today(),td_daily_budget_ok() · reads:ticketsdata_credit_usage,axs_watch_config
--
-- ============================================================================
-- Migration 20261125205000 — the TicketsData daily limit resets at midnight
--   Eastern and comes from the 250,000-credit cycle, not a flat 7,500
--
-- Lane:     a1 (TicketsData budget)
-- Touches:  td_credits_today() (REPLACE), td_daily_budget_ok() (REPLACE).
--           Reads ticketsdata_credit_usage, axs_watch_config via axs_watch_budget().
-- Pre-reqs: the AXS watch (20261124190000) for axs_watch_budget()
--
-- READ-ONLY UPSTREAM (RULE 2): nothing here calls a market.
--
-- Operator 2026-11-25: "Limit resets midnight est", and earlier "Keep into
-- account 250k axs poll limit" / "sit that into daily limit".
--
-- ── Two faults, both measured on 2026-11-25 ────────────────────────────────
-- 1. THE DAY BOUNDARY WAS UTC. td_credits_today() counted
--    (called_at AT TIME ZONE 'UTC')::date = CURRENT_DATE, so the budget rolled
--    over at 00:00Z — 7pm Eastern, the middle of the operator's evening. At
--    20:45Z today the UTC-day count was 7,123 credits while the Eastern-day
--    count was 5,560: the gate was tripped on one boundary and not on the other.
-- 2. THE LIMIT WAS A FLAT 7,500, SET BEFORE THE WATCH EXISTED. With the 1.276
--    weighting it tripped at about 5,878 real credits a day. From 11-18 to 11-23
--    the whole TicketsData spend was 51-65 credits a day, so 7,500 was never
--    reached. The watch went live on 11-24 and spends about 7,320 a day on its
--    own, so from its first full day the gate tripped every afternoon — at about
--    17:10Z today — and axs_export_tick() has returned budget_blocked ever since,
--    stopping a catalogue feed that costs 52 credits a day, 0.6% of the spend.
--    Meanwhile the cycle itself had 21% of its 250,000 credits going unused.
--
-- ── What this does ─────────────────────────────────────────────────────────
-- The day is now America/New_York, so the limit resets at midnight Eastern (DST
-- included, since the zone is named rather than a fixed offset).
--
-- The limit is now the cycle, paced: axs_watch_budget()->>'daily_cap', which is
-- floor((pool_remaining - reserve_credits) / days_left) over
-- axs_watch_config.monthly_credits = 250,000, reserve 5,000, cycle_reset_day 18.
-- Today that is 10,310. So there is ONE budget rather than two that disagree,
-- and it tracks the 250k by construction: spending cannot run the cycle dry
-- early, and a day's allowance rises as unspent credits accumulate.
--
-- The 1.276 weighting is kept as the margin for credits charged but not yet
-- recorded. At 7,320 reads plus 52 catalogue credits that is 9,407 against
-- 10,310 — it passes with about 9% to spare, and because the cadence after mig
-- 20261125204500 is flat (305 events x 24 reads), the daily spend is predictable
-- rather than ladder-dependent.
--
-- WHAT THIS DOES NOT DO. It does not remove any consumer. Sixteen functions
-- check td_budget_ok(); over the seven days to 2026-11-25 only three endpoints
-- spent anything — /fetch (the watch, 7,243), /events?mode=all (the catalogue,
-- 386) and /match (the sub finder, 144). n2s_td_enqueue and the eleven
-- td_*_discover functions spent nothing at all, so they are already dormant and
-- fencing them would free about 72 credits a day out of 10,310. The operator's
-- instruction on removing them arrived truncated ("Remove td fr"), so nothing is
-- fenced here; the sub finder keeps its /match credits.
--
-- ── THE WATCH'S OWN COUNTER HAD TO MOVE WITH IT ───────────────────────────
-- axs_watch_budget() counts fired_today over the UTC day. Moving only the credit
-- gate to Eastern would leave the two disagreeing for the five hours between
-- 00:00Z and 05:00Z: fired_today resets to 0, so the watch believes it has a
-- fresh day's cap, while td_credits_today() still carries the Eastern day's
-- spend and the gate still refuses — the watch would fire into a closed gate for
-- five hours every night. So fired_today moves to the Eastern day too, and the
-- operator's "Limit resets midnight est" means one boundary for both.
-- ============================================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.td_credits_today()
 RETURNS integer
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  -- The day is Eastern, not UTC: the limit resets at midnight Eastern
  -- (mig 20261125205000, operator "Limit resets midnight est"). Naming the zone
  -- rather than an offset keeps it right across DST.
  SELECT COALESCE(SUM(credits), 0)::integer
  FROM public.ticketsdata_credit_usage
  WHERE (called_at AT TIME ZONE 'America/New_York')::date
        = (now() AT TIME ZONE 'America/New_York')::date;
$function$;

CREATE OR REPLACE FUNCTION public.td_daily_budget_ok()
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  -- The day's allowance is the 250,000-credit cycle paced over the days left,
  -- not a flat 7,500 (mig 20261125205000). greatest(..., 1) keeps the gate from
  -- dividing by a zero cap if the pool is ever read as exhausted.
  SELECT (public.td_credits_today()::numeric * 1.276)
         < greatest((public.axs_watch_budget()->>'daily_cap')::numeric, 1);
$function$;

-- The day's cap and the day's fires now share one boundary: midnight Eastern.
-- Only the `today` CTE changes; everything else is the form from mig 20261124190000.
CREATE OR REPLACE FUNCTION public.axs_watch_budget()
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  WITH cfg AS (SELECT * FROM public.axs_watch_config),
  reading AS (SELECT u.quota_remaining, u.called_at
                FROM public.ticketsdata_credit_usage u
               WHERE u.quota_remaining IS NOT NULL AND u.called_at > now() - interval '6 hours'
               ORDER BY u.called_at DESC LIMIT 1),
  reset AS (SELECT CASE WHEN extract(day FROM current_date) < cfg.cycle_reset_day
                        THEN make_date(extract(year FROM current_date)::int, extract(month FROM current_date)::int, cfg.cycle_reset_day)
                        ELSE (make_date(extract(year FROM current_date)::int, extract(month FROM current_date)::int, cfg.cycle_reset_day) + interval '1 month')::date END AS next_reset
              FROM cfg),
  pool AS (SELECT coalesce((SELECT r.quota_remaining FROM reading r),
                           cfg.monthly_credits - (SELECT coalesce(sum(u.credits), 0) FROM public.ticketsdata_credit_usage u
                                                   WHERE u.called_at >= (reset.next_reset - interval '1 month'))) AS remaining,
                  (SELECT r.called_at FROM reading r) AS read_at
             FROM cfg, reset),
  -- the Eastern day, to match td_credits_today() (mig 20261125205000)
  today AS (SELECT count(*) AS fired FROM public.axs_watch_poll w
             WHERE w.fired_at >= date_trunc('day', now() AT TIME ZONE 'America/New_York') AT TIME ZONE 'America/New_York')
  SELECT jsonb_build_object(
           'pool_remaining', pool.remaining, 'pool_read_at', pool.read_at,
           'next_reset', reset.next_reset, 'days_left', greatest(reset.next_reset - current_date, 1),
           'daily_cap', coalesce(cfg.daily_cap_override,
                                 greatest(floor((pool.remaining - cfg.reserve_credits)::numeric / greatest(reset.next_reset - current_date, 1))::integer, 0)),
           'fired_today', today.fired,
           'in_flight', (SELECT count(*) FROM public.axs_watch_poll w WHERE w.checked_at IS NULL AND w.fired_at > now() - cfg.stale_after),
           'enabled', cfg.enabled)
    FROM cfg, reset, pool, today
$function$;

COMMIT;
