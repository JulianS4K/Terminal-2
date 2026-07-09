-- ============================================================================
-- Migration 20260709220000 — Expand Ticketmaster coverage: raise /match report cap + enqueue throughput
--
-- Lane:     A1 (data plane — TicketsData TM coverage)
-- Touches:  td_reports_budget_ok() [600→1200], td_match_cron_budget_ok() [600→1200],
--           cron_policy row 'td_match_fill_enqueue' (interval 240→90),
--           cron 'td_match_fill_enqueue' (fill batch 3→4).
-- Reads/writes on run: td_match_enqueue path → td_match_queue, td_match_results, ticketsdata_event_xref.
-- Pre-reqs: 20260704160040 (td_gt_tm_enroll_from_match + cap 300→600), 20260609120000 (td_reports_budget_ok,
--           td_match_enqueue), td_reports_this_month(), td_budget_ok().
-- Auth:     operator directive 2026-07-09 (julian@s4kent.com — "expand tm coverage").
--
-- WHY ────────────────────────────────────────────────────────────────────────
-- TM coverage is stuck at ~155 active xref rows (vs ~2,500 SH/VD). TM event ids come almost
-- entirely from /match (authoritative tm_url per matched event) — the by-performer td_tm_discover
-- path is hardcoded to Yankees/Knicks and needs non-derivable TM artist ids. Two binding constraints,
-- both lifted here:
--   1. REPORT CAP. /match is gated by td_reports_budget_ok() < 600, and we were at 501/600 for the
--      month — nearly out. Raise 600 → 1,200 (60% of the 2,000/mo report plan; 800 reserved for manual).
--      /match is the sole scalable source of TM/GT/TP ids AND the sh/vivid backfill filler, so this
--      grows TM proportionally. Cost: ≤1,200 × 12 = 14,400 credits/mo ≈ 6% of the 225k cycle pool;
--      still hard-bounded by td_budget_ok() (td_match_enqueue checks it), so it cannot over-burn.
--   2. ENQUEUE THROUGHPUT. td_match_fill_enqueue's cron_policy interval was 240 min (4h) — so despite
--      its every-2h schedule it fired ~6×/day × batch 3 ≈ 18/day, far too slow for the ~2,536-event
--      fill backlog. Lower the interval to 90 min and raise the fill batch 3 → 4 (≈48/day capacity), so
--      the 1,200/mo report cap — not the enqueue rate — is the binding limit and the backlog gets worked.
--
-- Expected: at the measured ~25% tm_url yield (112 upcoming tm_urls / 450 upcoming matched), ~1,200
-- matches/mo → ~300 new TM events/mo. The existing hourly td_gt_tm_enroll_from_match() cron auto-enrolls
-- them into ticketsdata_event_xref — no extra wiring. GT/TP and the sh/vivid mapping backlog benefit too.
--
-- Idempotent (CREATE OR REPLACE + UPDATE + cron.schedule upsert) -> apply-before-PR under operator
-- direction; re-apply is a no-op.
-- Rollback: reset both caps to 600, cron_policy interval to 240, fill batch to 3.
-- ============================================================================

-- 1. Report cap 600 → 1,200 (the gate td_match_enqueue actually checks).
CREATE OR REPLACE FUNCTION public.td_reports_budget_ok()
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT public.td_reports_this_month() < 1200;  -- 1,200/2,000 plan reports → automated cap (2026-07-09)
$function$;

-- Keep the cron-budget helper in lockstep (raised alongside the cap in 20260704160040).
CREATE OR REPLACE FUNCTION public.td_match_cron_budget_ok()
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT public.td_budget_ok() AND public.td_reports_this_month() < 1200;
$function$;

REVOKE ALL ON FUNCTION public.td_reports_budget_ok()    FROM anon, public;
REVOKE ALL ON FUNCTION public.td_match_cron_budget_ok() FROM anon, public;
GRANT EXECUTE ON FUNCTION public.td_reports_budget_ok()    TO service_role, authenticated;
GRANT EXECUTE ON FUNCTION public.td_match_cron_budget_ok() TO service_role, authenticated;

-- 2a. Loosen the enqueue interval throttle (was 240 min → fired ~6×/day).
UPDATE public.cron_policy
SET peak_min_interval_min   = 90,
    offpeak_min_interval_min = 90,
    updated_at = now()
WHERE jobname = 'td_match_fill_enqueue';

-- 2b. Raise the fill batch 3 → 4 (schedule unchanged: :17 every 2h; interval gate now allows each fire).
SELECT cron.schedule(
  'td_match_fill_enqueue',
  '17 */2 * * *',
  $c$DO $body$ BEGIN
    IF NOT public.cron_should_fire('td_match_fill_enqueue') THEN RETURN; END IF;
    PERFORM public.td_match_enqueue('fill', 4);
  END $body$;$c$
);

-- 3. Enroll any tm_url/gt_url already sitting in td_match_results now (free — reads our tables).
SELECT public.td_gt_tm_enroll_from_match();
