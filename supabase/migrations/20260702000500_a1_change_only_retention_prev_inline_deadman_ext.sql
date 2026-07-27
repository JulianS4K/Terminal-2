-- ============================================================================
-- Migration 20260702000500 — change-only retention (espn_athletes) + inline prev_* at ingest
--                            + deadman coverage extension + SG no-op group paused
--
-- Lane:     A1
-- Touches:  new triggers on espn_athletes + listings_snapshots; record_cron_deadman() (expanded
--           watch list); cron active=false for the 4 SG no-op processors.
-- Pre-reqs: 20260701235000 (deadman), listings_snapshots_event_tgid_captured_idx.
--
-- WHY (operator 2026-07-02 "improve/add as recommended; redundant #1 off; #2 keep but only
-- retain data when it changes"):
--
-- 1) espn_athletes change-only retention. espn-rosters-rotate (every 20s, league round-robin →
--    each league every 2 min) UPSERTs every athlete with last_seen_at=now(), rewriting ~unchanged
--    rows constantly (churn/bloat/WAL). BEFORE UPDATE trigger suppresses the write when nothing
--    but last_seen_at changed AND the heartbeat is <24h old. SAFE: trade/release detection uses
--    espn_athlete_team_history (seen-sets + detected_at cutoff), and NO consumer reads
--    espn_athletes.last_seen_at (verified repo-wide). Verified live: no-op UPDATE writes 0 rows.
--
-- 2) Inline prev_* at ingest — ATTEMPTED AND REVERTED (see the section body below for the
--    full post-mortem): a per-row BEFORE-INSERT probe stalled the EVO ingest firehose for ~5
--    minutes. Deferred to a statement-level transition-table design or an edge-fn-side fill.
--
-- 3) record_cron_deadman(): watch list extended with the 4 weekly pull jobs (warn 8d/fail 15d)
--    and 2 load-bearing hourlies (td_pending_sweep, event_section_row_rollup_hourly, 3h/6h).
--
-- 4) SG no-op group PAUSED (operator "turn off redundant #1"): sg_classify_events_5min,
--    sg_priority_listings_process_5min, sg_priority_sales_process_5min,
--    sg_broker_sales_metrics_refresh_hourly — ~1,050 runs/day re-processing a corpus frozen
--    since 6/26 (SG pollers off). Resume together with the SG group. sg_lifetime_sales_daily
--    stays ACTIVE (operator-requested earlier).
--
-- Idempotent: CREATE OR REPLACE + DROP TRIGGER IF EXISTS + alter_job by name.
-- Already applied to prod · via MCP 2026-07-02
-- ============================================================================

CREATE OR REPLACE FUNCTION public.espn_athletes_suppress_redundant()
RETURNS trigger LANGUAGE plpgsql AS $function$
BEGIN
  IF (to_jsonb(NEW) - 'last_seen_at') = (to_jsonb(OLD) - 'last_seen_at')
     AND OLD.last_seen_at > now() - interval '24 hours' THEN
    RETURN NULL;
  END IF;
  RETURN NEW;
END $function$;

DROP TRIGGER IF EXISTS trg_espn_athletes_suppress_redundant ON public.espn_athletes;
CREATE TRIGGER trg_espn_athletes_suppress_redundant
  BEFORE UPDATE ON public.espn_athletes
  FOR EACH ROW EXECUTE FUNCTION public.espn_athletes_suppress_redundant();

-- [REVERTED 2026-07-02 00:06 UTC] Inline prev_* BEFORE-INSERT trigger on listings_snapshots.
-- Applied at ~00:01, REVERTED at ~00:06 after it stalled EVO ingest: the per-ROW prior-snapshot
-- index probe (~cold random IO on a 37GB table) made the edge fn's per-event batch inserts time
-- out (edge fn caught the errors and returned 200 -> ~5 min of zero rows landing; single-row
-- inserts verified fine both with and without priors, so it was throughput, not correctness).
-- LESSON (PROJECT_BIBLE-worthy): per-row triggers with index probes are unaffordable on the
-- listings firehose (~80k rows/10min). The correct designs are (a) a STATEMENT-level trigger
-- with transition tables doing ONE set-based lateral-join fill per batch, or (b) computing
-- prev_* in the collect-listings edge fn from its own previous fetch. Deferred; the overnight
-- listings_deltas backfill remains the interim populater.
-- The DROP below is the durable record; fn body intentionally not recreated.
DROP TRIGGER IF EXISTS trg_listings_snapshots_fill_prev ON public.listings_snapshots;
DROP FUNCTION IF EXISTS public.listings_snapshots_fill_prev();

CREATE OR REPLACE FUNCTION public.record_cron_deadman()
RETURNS integer
LANGUAGE plpgsql
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_n integer;
BEGIN
  WITH watch(jobname, warn_h, fail_h) AS (VALUES
    ('sg_lifetime_sales_daily',            26.0,  50.0),
    ('listings_deltas_backfill_overnight', 26.0,  50.0),
    ('refresh_movers_agg',                 14.0,  26.0),
    ('discovery_gap_refresh',              26.0,  50.0),
    ('event_snapshot_morning',             26.0,  50.0),
    ('event_snapshot_midday',              26.0,  50.0),
    ('event_snapshot_evening',             26.0,  50.0),
    ('espn-rosters-daily',                 26.0,  50.0),
    ('sg_market_chart_reveal_pull_daily',  26.0,  50.0),
    ('sg_market_chart_rebuild_daily',      26.0,  50.0),
    ('tournament_pull_queue_weekly',      192.0, 360.0),
    ('tournament_pull_process_weekly',    192.0, 360.0),
    ('venue_pull_queue_weekly',           192.0, 360.0),
    ('venue_pull_process_weekly',         192.0, 360.0),
    ('td_pending_sweep',                    3.0,   6.0),
    ('event_section_row_rollup_hourly',     3.0,   6.0)
  ),
  state AS (
    SELECT w.jobname, w.warn_h, w.fail_h,
           j.jobid, COALESCE(j.active, false) AS active,
           (SELECT max(d.start_time) FROM cron.job_run_details d
             WHERE d.jobid = j.jobid AND d.status = 'succeeded') AS last_ok
    FROM watch w LEFT JOIN cron.job j ON j.jobname = w.jobname
  )
  INSERT INTO health_check_history (captured_at, check_class, check_name, status, metric, detail)
  SELECT now(), 'cron_deadman', s.jobname,
         CASE
           WHEN s.jobid IS NULL OR NOT s.active THEN 'off'
           WHEN s.last_ok IS NULL THEN 'fail'
           WHEN now() - s.last_ok < make_interval(hours => s.warn_h::int) THEN 'ok'
           WHEN now() - s.last_ok < make_interval(hours => s.fail_h::int) THEN 'warn'
           ELSE 'fail'
         END,
         round((extract(epoch FROM now() - s.last_ok)/3600.0)::numeric, 1),
         'last success ' || COALESCE(to_char(s.last_ok, 'MM-DD HH24:MI'), 'never')
           || ' · gap ' || COALESCE(round((extract(epoch FROM now()-s.last_ok)/3600.0)::numeric,1)::text,'—')
           || 'h · SLA warn ' || s.warn_h::int || 'h / fail ' || s.fail_h::int || 'h'
           || CASE WHEN s.jobid IS NULL OR NOT s.active THEN ' · job OFF/unscheduled' ELSE '' END
  FROM state s;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n;
END $function$;

DO $do$
DECLARE r RECORD;
BEGIN
  FOR r IN SELECT jobid FROM cron.job
           WHERE jobname IN ('sg_classify_events_5min','sg_priority_listings_process_5min',
                             'sg_priority_sales_process_5min','sg_broker_sales_metrics_refresh_hourly')
  LOOP
    PERFORM cron.alter_job(r.jobid, active:=false);
  END LOOP;
END $do$;
