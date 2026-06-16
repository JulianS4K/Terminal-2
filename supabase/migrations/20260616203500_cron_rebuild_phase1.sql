-- Migration 20260616203500 · lane:D0 · APPLIED LIVE 2026-06-16 by operator directive · writes(cron): pause broken jobs, retune Vivid + SeatGeek cadence, add espn-live-score-poll · writes(DDL): espn_has_live_tracked_game(), v_espn_live_result_price_impact · reads: cron.job, espn_*, team_xref, v_events_5w, event_metrics · pre:20260616201700_td_pause_crons_budget_split · auth:operator-requested 2026-06-16 ("lets rebuild the cron structure and plan")
--
-- Cron rebuild — phase 1. Operator decisions (2026-06-16):
--   ESPN     : keep collection + NEW near-real-time live-score poll (this file)
--   Weather  : unchanged
--   Vivid    : orders pull HOURLY (was every 30 min)
--   SeatData : unchanged
--   EVO      : unchanged (keep polling every US event)
--   SeatGeek : halve all polling-pipeline cadences (seller account kept)
--   Broken   : pause the failing/runaway jobs for now
--   FRED+alerts: keep in background (compute_alerts_tick stays paused as broken)
--   TicketsData: remains paused (separate rebuild); AXS untouched (separate pool)
-- ─────────────────────────────────────────────────────────────────────────────

-- 1. Pause broken / runaway jobs (24h run history: high failure or overlap).
DO $$
DECLARE r record;
BEGIN
  FOR r IN SELECT jobid FROM cron.job WHERE active = true AND jobname IN (
    'tevo_blindspot_mv_refresh',        -- 119/144 failed (600s timeout)
    'compute_alerts_tick_15min',        -- 86/96 failed (120s timeout)
    'orphan_event_backfill_queue_15min',-- 55/96 failed (120s timeout)
    'zone-backfill-isolated-10min'      -- runaway: one run ~5.9h, self-overlapping
  ) LOOP
    PERFORM cron.alter_job(r.jobid, active := false);
  END LOOP;
END $$;

-- 2. Vivid orders: every 30 min -> hourly.
SELECT cron.alter_job((SELECT jobid FROM cron.job WHERE jobname='vivid_orders_queue_30min'),   schedule := '16 * * * *');
SELECT cron.alter_job((SELECT jobid FROM cron.job WHERE jobname='vivid_orders_process_30min'), schedule := '26 * * * *');

-- 3. SeatGeek polling pipeline: halve cadence (seller account included; analytics
--    and sales-metrics rollups left as-is).
SELECT cron.alter_job((SELECT jobid FROM cron.job WHERE jobname='sg_listings_poll_owned_1min'),       schedule := '*/4 * * * *');
SELECT cron.alter_job((SELECT jobid FROM cron.job WHERE jobname='sg_priority_listings_process_5min'), schedule := '*/4 * * * *');
SELECT cron.alter_job((SELECT jobid FROM cron.job WHERE jobname='sg_sales_poll_5min'),                schedule := '1-59/4 * * * *');
SELECT cron.alter_job((SELECT jobid FROM cron.job WHERE jobname='sg_priority_sales_process_5min'),    schedule := '1-59/4 * * * *');
SELECT cron.alter_job((SELECT jobid FROM cron.job WHERE jobname='sg_seller_listings_queue_30min'),    schedule := '*/4 * * * *');
SELECT cron.alter_job((SELECT jobid FROM cron.job WHERE jobname='sg_seller_process_30min'),           schedule := '1-59/4 * * * *');
SELECT cron.alter_job((SELECT jobid FROM cron.job WHERE jobname='sg_seller_orders_queue_30min'),      schedule := '2 * * * *');
SELECT cron.alter_job((SELECT jobid FROM cron.job WHERE jobname='sg_seller_sync_map_15min'),          schedule := '*/30 * * * *');
SELECT cron.alter_job((SELECT jobid FROM cron.job WHERE jobname='sg_wc_listings_catchup'),            schedule := '*/2 * * * *');
SELECT cron.alter_job((SELECT jobid FROM cron.job WHERE jobname='sg_force_track_refresh'),            schedule := '7-59/30 * * * *');
SELECT cron.alter_job((SELECT jobid FROM cron.job WHERE jobname='sg_canonical_v2_pull_refresh_30min'),schedule := '12 * * * *');

-- 4. ESPN near-real-time live-score feature.
-- 4a. Gate: any ESPN-referenced (team_xref) team in a live, non-final game window?
CREATE OR REPLACE FUNCTION public.espn_has_live_tracked_game()
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $fn$
  SELECT EXISTS (
    SELECT 1 FROM public.espn_event_date_lookup l
    WHERE l.game_at_utc BETWEEN now() - interval '6 hours' AND now() + interval '15 minutes'
      AND coalesce(l.status_short,'') !~* 'final|ft|post|cancel|postpon|delay'
      AND ( l.home_team_id IN (SELECT espn_team_id FROM public.team_xref)
         OR l.away_team_id IN (SELECT espn_team_id FROM public.team_xref) )
  );
$fn$;
REVOKE ALL ON FUNCTION public.espn_has_live_tracked_game() FROM anon, public;
COMMENT ON FUNCTION public.espn_has_live_tracked_game() IS
  'True when an ESPN-referenced (team_xref) team has an in-window, non-final game. Gates espn-live-score-poll.';

-- 4b. Poller: every minute, only acts when a tracked team is live. Reuses
--     espn-collect?scope=gameday (ESPN free API, no paid credits).
SELECT cron.schedule('espn-live-score-poll', '* * * * *', $cron$
  DO $b$ BEGIN
    IF NOT public.espn_has_live_tracked_game() THEN RETURN; END IF;
    PERFORM public._cron_invoke_edge_fn(
      'https://hzrizjeaxlqcxfrtczpq.supabase.co/functions/v1/espn-collect?scope=gameday',
      '{}'::jsonb);
  END $b$;
$cron$);

-- 4c. Correlation view: a tracked team's current/recent (12h) game joined to its
--     FUTURE events + latest price snapshot — to watch score/result vs price.
CREATE OR REPLACE VIEW public.v_espn_live_result_price_impact AS
WITH tracked_games AS (
  SELECT DISTINCT ON (s.espn_event_id)
    s.espn_event_id, s.espn_league, s.state, s.status_short,
    s.home_team_id, s.away_team_id, s.home_score, s.away_score,
    s.home_win_prob, s.captured_at
  FROM public.espn_event_snapshots s
  WHERE s.captured_at > now() - interval '12 hours'
    AND ( s.home_team_id IN (SELECT espn_team_id FROM public.team_xref)
       OR s.away_team_id IN (SELECT espn_team_id FROM public.team_xref) )
  ORDER BY s.espn_event_id, s.captured_at DESC
),
team_in_game AS (
  SELECT g.*, tx.tevo_performer_id, tx.tevo_name,
    CASE WHEN g.home_team_id = tx.espn_team_id THEN 'home' ELSE 'away' END AS side
  FROM tracked_games g
  JOIN public.team_xref tx ON tx.espn_team_id IN (g.home_team_id, g.away_team_id)
),
latest_price AS (
  SELECT DISTINCT ON (event_id) event_id, captured_at, getin_price, retail_median, tickets_count
  FROM public.event_metrics
  ORDER BY event_id, captured_at DESC
)
SELECT
  tig.tevo_performer_id, tig.tevo_name AS team, tig.side,
  tig.espn_event_id, tig.espn_league, tig.state, tig.status_short,
  tig.home_score, tig.away_score, tig.home_win_prob,
  tig.captured_at AS game_captured_at,
  fe.event_id AS future_event_id, fe.what AS future_event, fe.when_local AS future_event_at,
  lp.getin_price, lp.retail_median, lp.tickets_count, lp.captured_at AS price_captured_at
FROM team_in_game tig
JOIN public.v_events_5w fe
  ON fe.who_performer_id = tig.tevo_performer_id AND fe.when_local::timestamptz > now()
LEFT JOIN latest_price lp ON lp.event_id = fe.event_id;
REVOKE ALL ON public.v_espn_live_result_price_impact FROM anon, public;
COMMENT ON VIEW public.v_espn_live_result_price_impact IS
  'Per tracked team in a current/recent (12h) game: its future events + latest price snapshot. For watching game result vs future-date price impact.';
