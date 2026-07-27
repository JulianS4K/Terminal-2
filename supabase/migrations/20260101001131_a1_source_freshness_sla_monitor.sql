-- ============================================================================
-- Migration 20260701221500 — per-source metric-freshness SLA monitor
--
-- Lane:     A1
-- Touches:  new fn public.record_source_freshness(); cron 'health_monitor_5min' command
--           (appends the freshness recorder after health_tick(); health_tick untouched).
-- Pre-reqs: health_check_history; get_health_dashboard (renders checks[] by check_class);
--           idx_listings_captured, idx_td_ls_captured_at, idx_sg_listings_captured,
--           idx_sg_sales_pulled_at (mig 20260701194500).
--
-- WHY (operator 2026-07-01 "unify metric freshness SLAs"): a source went silently stale for
-- 2.5 days (SG) with no alarm — nothing watched newest-row age per source. Every 5 min this
-- writes a 'source_freshness' row per source into health_check_history, so the D0 health page
-- renders per-source staleness cards with 24h/7d uptime AND the overall banner trips on a
-- stale source automatically.
--
-- Status: poller cron inactive -> 'off' (operator-intentional, does NOT trip overall);
-- else age<warn -> ok, <fail -> warn, else fail. metric = age in minutes.
-- SLAs: evo_listings 10/30m · evo_event_metrics 20/60m · zone_section 45/180m ·
--       td_listings 8h/26h (off-peak quiet ~7h) · axs 12h/36h · sg 90m/6h (currently off).
-- section_metrics deliberately NOT probed (57M rows, no leading captured_at index);
-- zone_metrics is its proxy (same writer).
--
-- First live snapshot immediately caught a real issue: axs_events FAIL (newest 06-29, ~2 days —
-- the TD/AXS upstream maintenance outage). Working as intended.
--
-- Idempotent: CREATE OR REPLACE + cron.alter_job by name; the seed INSERT re-runs harmlessly
-- (one extra snapshot row). Re-apply is a no-op in effect.
-- Already applied to prod · via MCP 2026-07-01
-- ============================================================================

CREATE OR REPLACE FUNCTION public.record_source_freshness()
RETURNS integer
LANGUAGE plpgsql
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_n integer;
BEGIN
  WITH src(check_name, poller, newest, warn_min, fail_min) AS (VALUES
    ('evo_listings',        'evo_listings_poll_2min',
       (SELECT max(captured_at) FROM listings_snapshots),                    10.0,   30.0),
    ('evo_event_metrics',   'latest_event_metrics_refresh_5min',
       (SELECT max(captured_at) FROM latest_event_metrics),                  20.0,   60.0),
    ('zone_section_metrics','zone-backfill-isolated-10min',
       (SELECT max(captured_at) FROM zone_metrics),                          45.0,  180.0),
    ('td_listings',         'td_pull_drain',
       (SELECT max(captured_at) FROM ticketsdata_listings_snapshots),       480.0, 1560.0),
    ('axs_events',          'axs-probe-drain',
       (SELECT max(captured_at) FROM axs_event_snapshots),                  720.0, 2160.0),
    ('sg_listings',         'sg_listings_poll_owned_1min',
       (SELECT max(captured_at) FROM seatgeek_listings_snapshots),           90.0,  360.0),
    ('sg_sales',            'sg_sales_poll_5min',
       (SELECT max(pulled_at) FROM seatgeek_sales_snapshots),                90.0,  360.0)
  )
  INSERT INTO health_check_history (captured_at, check_class, check_name, status, metric, detail)
  SELECT now(), 'source_freshness', s.check_name,
         CASE
           WHEN NOT COALESCE((SELECT j.active FROM cron.job j WHERE j.jobname = s.poller), false)
             THEN 'off'
           WHEN s.newest IS NULL THEN 'fail'
           WHEN now() - s.newest < make_interval(mins => s.warn_min::int) THEN 'ok'
           WHEN now() - s.newest < make_interval(mins => s.fail_min::int) THEN 'warn'
           ELSE 'fail'
         END,
         round((extract(epoch FROM now() - s.newest)/60.0)::numeric, 1),
         'newest ' || COALESCE(to_char(s.newest, 'MM-DD HH24:MI'), 'never')
           || ' · age ' || COALESCE(round((extract(epoch FROM now()-s.newest)/60.0)::numeric)::text, '—')
           || 'm · SLA warn ' || s.warn_min::int || 'm / fail ' || s.fail_min::int || 'm'
           || CASE WHEN NOT COALESCE((SELECT j.active FROM cron.job j WHERE j.jobname = s.poller), false)
                   THEN ' · poller OFF (intentional)' ELSE '' END
  FROM src s;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n;
END $function$;

DO $do$
BEGIN
  PERFORM cron.alter_job(
    (SELECT jobid FROM cron.job WHERE jobname='health_monitor_5min'),
    command := $cmd$ DO $b$ BEGIN IF NOT public.cron_should_fire('health_monitor_5min') THEN RETURN; END IF; PERFORM public.health_tick(); PERFORM public.record_source_freshness(); END $b$; $cmd$);
END $do$;

SELECT public.record_source_freshness();
