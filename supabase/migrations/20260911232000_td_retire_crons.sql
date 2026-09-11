-- ============================================================================
-- Migration 20260911232000 — retire the TicketsData crons (upstream dead, operator call)
--
-- Lane:     A1 (crons + ingest)
-- Touches:  cron.job (W), integration_policy (W), n2s_td_enqueue (replaced)
-- Pre-reqs: 20260630160000–250000 (TD sourcing model), 20260527100000 (TD crons)
--
-- TD is retired (operator, 2026-09-11). The upstream has been returning 100%
-- failures since 2026-09-09: v_td_poll_health shows 15,846 attempts and ZERO
-- successes across SH/TP/TM/GT in 24h. The sequence in td_poll_failures was
-- quota-exhaustion 403s from 09-09 22:28, then from 09-10 00:04 every platform
-- flipped to 'access_denied — xref deactivated' (32,900+ rows), because the
-- drain's 403 handler deactivates the event's xref row — so a plan-level 403
-- mass-deactivated 6,000+ xrefs. td_listings freshness has been 'fail' since,
-- newest row 09-09 10:04.
--
-- Meanwhile these jobs were still consuming 14.8% of ALL cron slot time
-- (435 of 2,938 slot-minutes per 6h, 998 runs) to produce nothing, on a
-- scheduler that is currently shedding jobs with 'job startup timeout'. This
-- is the single cheapest capacity win available.
--
-- Retirement, not deletion: no TD table, row, or xref is touched. Every
-- function stays. Re-enable = re-schedule these jobnames and flip the policy
-- flag back, once the upstream contract is resolved.
--
-- NOT touched (name matches but different vendor / no TD call):
--   seatdata_poll_twice_daily, resolve-aq-seatdata-link-hourly  — SeatData
--   axs-sg-url-anchor-backfill                                  — local UPDATE
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Kill switch, so any surviving TD code path self-gates
-- ---------------------------------------------------------------------------
INSERT INTO public.integration_policy(key, enabled, reason, updated_by, updated_at)
VALUES ('ticketsdata_retired', true,
        'TD retired by operator 2026-09-11: upstream 100% failure since 09-09 '
        '(quota 403 -> mass xref deactivation). Crons unscheduled in '
        'migration 20260911232000. Flip enabled=false to resume.',
        '20260911232000', now())
ON CONFLICT (key) DO UPDATE SET
  enabled    = EXCLUDED.enabled,
  reason     = EXCLUDED.reason,
  updated_by = EXCLUDED.updated_by,
  updated_at = now();

-- ---------------------------------------------------------------------------
-- 2. Unschedule the TD jobs
-- ---------------------------------------------------------------------------
DO $do$
DECLARE
  v_job text;
BEGIN
  FOREACH v_job IN ARRAY ARRAY[
    -- queue drains / normalisers
    'td_pull_drain', 'td_normalize_drain', 'td_pending_sweep',
    -- per-platform enqueue (both the live tier path and the gated peak path)
    'td_tier_enqueue_sh', 'td_tier_enqueue_vd', 'td_tier_enqueue_gt',
    'td_tier_enqueue_tm', 'td_tier_enqueue_tp',
    'td_enqueue_peak_sh', 'td_enqueue_peak_vd', 'td_enqueue_peak_gt',
    'td_enqueue_peak_tm',
    -- discovery + enrolment
    'td_gt_discover', 'td_gt_discover_drain', 'td_gt_automap_check',
    'td_tm_discover', 'td_tm_discover_drain',
    'td_sg_discover_daily', 'td_sg_discover_drain_daily',
    'td_watchlist_refresh', 'td_gt_tm_enroll_from_match_hourly',
    'axs-enroll-gt-tm',
    -- one-off reconciler left scheduled
    'td-reconcile-knicks-finals-daily',
    -- TD /match (12 credits + a Market-Intel report per call). This is the
    -- only writer of sh_event_id; with TD dead it cannot fill anything, so it
    -- retires with the rest. Re-scheduling it is part of any TD resume.
    'sg-match-map-tick'
  ] LOOP
    IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = v_job) THEN
      PERFORM cron.unschedule(v_job);
    END IF;
  END LOOP;
END
$do$;

UPDATE public.cron_policy
   SET enabled = false,
       notes   = coalesce(notes, '') ||
                 ' [RETIRED 20260911232000 — TD upstream dead; crons unscheduled.]',
       updated_at = now()
 WHERE jobname LIKE 'td\_%' OR jobname IN ('sg-match-map-tick', 'td_match_fill_enqueue');

-- ---------------------------------------------------------------------------
-- 3. Stop the N2S path feeding a queue nothing drains
--
-- n2s_pull_events() calls n2s_td_enqueue() for every event it touches. With
-- td_pull_drain unscheduled that INSERT would grow td_pull_queue without bound.
-- Gate it on the kill switch; the signature and return shape are unchanged so
-- the caller needs no edit.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.n2s_td_enqueue(
  p_max           integer  DEFAULT 200,
  p_recent_fired  interval DEFAULT '00:30:00'::interval)
RETURNS TABLE(events_enqueued integer, budget_ok boolean)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  v_n integer := 0; v_ok boolean;
BEGIN
  -- TD retired: enqueueing here would just grow td_pull_queue forever, since
  -- td_pull_drain is unscheduled (20260911232000).
  IF COALESCE((SELECT ip.enabled FROM public.integration_policy ip
                WHERE ip.key = 'ticketsdata_retired'), false) THEN
    RETURN QUERY SELECT 0, false;
    RETURN;
  END IF;

  SELECT public.td_budget_ok() INTO v_ok;

  WITH want AS (
    SELECT DISTINCT n.tevo_event_id AS eid
      FROM public.n2s_items n
     WHERE NOT n.is_terminal
       AND n.tevo_event_id IS NOT NULL
       AND n.event_dt::date >= current_date
     ORDER BY 1
     LIMIT p_max
  ),
  cand AS (
    SELECT x.event_id, x.platform, x.event_url
      FROM public.ticketsdata_event_xref x
      JOIN want w ON w.eid = x.event_id
     WHERE x.event_url IS NOT NULL
       AND COALESCE(x.active, true)
       AND NOT EXISTS (
         SELECT 1 FROM public.td_pull_queue q
          WHERE q.event_id = x.event_id AND q.platform = x.platform
            AND (q.resolved_at IS NULL OR q.fired_at > now() - p_recent_fired))
  ),
  ins AS (
    INSERT INTO public.td_pull_queue (event_id, platform, event_url, interval_tag)
    SELECT event_id, platform, event_url, 'n2s_ondemand' FROM cand
    RETURNING 1
  )
  SELECT count(*)::int INTO v_n FROM ins;

  RETURN QUERY SELECT v_n, v_ok;
END
$fn$;

COMMENT ON FUNCTION public.n2s_td_enqueue(integer, interval)
  IS 'Enqueues N2S events for a TicketsData pull. No-ops while '
     'integration_policy.ticketsdata_retired is enabled (TD retired 2026-09-11) '
     'so it cannot grow td_pull_queue with no drain scheduled.';
