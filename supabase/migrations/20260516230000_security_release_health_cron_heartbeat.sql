-- Migration 20260516230000 · level:security · lane:Security · writes:_health_check_cron_heartbeat() new fn + release_health_check() rewrite (CREATE OR REPLACE) · reads:cron.job, cron.job_run_details · pre:20260515170000,20260515290000,20260515330000
-- (Note: prior B1 migration 20260515340000 was authored but never applied to prod. This migration
-- is a SUPERSET that includes 340000's bot_chat_aging_7d + pg_net rows AND the new heartbeat row,
-- so it applies cleanly from either base state. After this migration applies, prod RHC has 13 rows
-- across 8 categories: cron (3 — failed_jobs_90min + subhourly_silent + heartbeat_stale_jobs),
-- functions, views, fks, data_freshness (4), queues, coordination (bot_chat_aging_7d), pg_net.)
--
-- B1 follow-up to bot_chat 251 (D0 audit proposed B1.2: "Add per-cron heartbeat
-- to release_health_check() so silent-success doesn't hide stalled crons").
--
-- Originating finding: 4 collect-listings windowed crons (1-7d, 7-30d, 30-60d,
-- 60d+) appeared to D0 audit as 0-firings/7d. B1 verification surfaced these
-- as 1-firing-each-today (created today; will fire normally on `5,17` schedule
-- going forward). The audit pattern itself is correct: daily-cadence crons
-- that silently fail to fire are invisible to existing release_health_check
-- rows (`cron.failed_jobs_90min` + `cron.subhourly_jobs_silent_90min` only
-- catch sub-hourly crons + explicit failures).
--
-- This migration adds a per-cron heartbeat detector:
--   - For each ACTIVE cron job, compute the median interval between successful
--     runs over the last 7 days (self-tuning baseline)
--   - Flag any cron whose `now() - last_success > 3× median_interval` as stale
--   - 5× or higher → fail; 3-5× → warn; otherwise → ok
--   - Self-tuning means daily-cadence crons get checked daily; hourly hourly.
--
-- ## Function ownership / auth pattern
--
-- Matches A1's `_health_check_pg_net_errors()` pattern (SECDEF + STABLE +
-- search_path explicit + no REVOKE — accessible from anon via release_health_check
-- composition). The §6 body guard is intentionally omitted because:
--   1. Function returns aggregate-only metrics (no row-level / business data).
--   2. Only reads cron metadata (no escalation surface).
--   3. release_health_check() is SECINVOKER; if this helper REVOKED anon, RHC
--      composition would break for anon callers.
-- For consistency, B1 will file a §6 retrofit follow-up alongside the existing
-- B1-NEXT-29 retrofit on `_health_check_pg_net_errors()` if operator wants
-- defense-in-depth on these helpers as a class.
--
-- ## Composition into release_health_check()
--
-- Rewrite of release_health_check() to add one more RETURN QUERY block at the
-- end (after the bot_chat_aging_7d + pg_net.error_rate_60min that B1 added in
-- 20260515340000). All 8 existing categories preserved byte-for-byte.
--
-- ## Regression risk
-- cron.failed_jobs_90min — none (no cron edits).
-- functions.pgcrypto_missing_extensions_searchpath — none (search_path set).
-- views.security_definer_views — none.
-- data_freshness.* — none.
-- New `cron.heartbeat_stale_jobs` row will report current state on first call.
--
-- ## Already applied to prod
-- NOT YET. Operator must authorize prod apply per 2026-05-13 lockdown.
-- Apply via mcp__bccd...__apply_migration with this file's contents.

-- ============================================================
-- SECTION 1 — New helper: _health_check_cron_heartbeat()
-- ============================================================

CREATE OR REPLACE FUNCTION public._health_check_cron_heartbeat()
RETURNS TABLE(check_class text, check_name text, status text, metric numeric, detail text)
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path TO 'public', 'cron', 'pg_temp'
AS $function$
  WITH per_job AS (
    SELECT j.jobid, j.jobname, j.schedule,
           (SELECT max(d.start_time) FROM cron.job_run_details d
             WHERE d.jobid = j.jobid AND d.status = 'succeeded') AS last_success,
           (SELECT percentile_cont(0.5) WITHIN GROUP (
                     ORDER BY EXTRACT(epoch FROM (start_time - prev_start)))
              FROM (
                SELECT start_time,
                       LAG(start_time) OVER (ORDER BY start_time) AS prev_start
                  FROM cron.job_run_details
                 WHERE jobid = j.jobid AND status = 'succeeded'
                   AND start_time > now() - interval '7 days'
              ) t
             WHERE prev_start IS NOT NULL
           ) AS median_interval_sec
      FROM cron.job j
     WHERE j.active = true
  ),
  stale AS (
    SELECT jobname,
           EXTRACT(epoch FROM (now() - last_success)) / NULLIF(median_interval_sec, 0) AS multiples_behind
      FROM per_job
     WHERE last_success IS NOT NULL
       AND median_interval_sec IS NOT NULL
       AND median_interval_sec > 0
       AND EXTRACT(epoch FROM (now() - last_success)) > 3 * median_interval_sec
  ),
  agg AS (
    SELECT count(*) FILTER (WHERE multiples_behind >= 5)                 AS critical,
           count(*) FILTER (WHERE multiples_behind >= 3 AND multiples_behind < 5) AS warn,
           string_agg(jobname || ' (' || round(multiples_behind::numeric, 1) || 'x behind)',
                      ', ' ORDER BY multiples_behind DESC) AS detail
      FROM stale
  )
  SELECT 'cron'::text,
         'heartbeat_stale_jobs'::text,
         CASE WHEN critical > 0 THEN 'fail'
              WHEN warn > 0     THEN 'warn'
                                ELSE 'ok' END,
         (critical + warn)::numeric,
         coalesce(detail,
                  'all active crons firing within 3x median interval (last 7d baseline)')
    FROM agg;
$function$;

COMMENT ON FUNCTION public._health_check_cron_heartbeat() IS
  'Per-cron heartbeat: flags active crons whose last_success > 3x the median '
  'inter-run interval observed over the last 7d. Self-tuning (no schedule '
  'parsing needed). 5x+ behind = fail; 3-5x = warn. Catches daily-cadence '
  'crons that fail silently — a gap in cron.subhourly_jobs_silent_90min '
  'which only watches sub-hourly schedules. Added by B1 2026-05-16 per '
  'bot_chat-251 D0 audit proposal B1.2.';

-- ============================================================
-- SECTION 2 — Compose into release_health_check()
-- ============================================================
--
-- Preserves the existing 9 categories byte-for-byte (the 7 from 20260515170000
-- + bot_chat_aging_7d + pg_net.error_rate_60min from 20260515340000) and
-- appends one more RETURN QUERY for the new heartbeat row.

CREATE OR REPLACE FUNCTION public.release_health_check()
RETURNS TABLE(check_class text, check_name text, status text, metric numeric, detail text)
LANGUAGE plpgsql
STABLE
SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
  RETURN QUERY
  WITH agg AS (
    SELECT count(*)::int AS n,
           string_agg(j.jobname || ':' || coalesce(left(r.return_message,80),''), ' | ') AS msg
    FROM cron.job j JOIN cron.job_run_details r ON r.jobid = j.jobid
    WHERE r.start_time > now() - interval '90 minutes' AND r.status = 'failed'
  )
  SELECT 'cron'::text, 'failed_jobs_90min'::text,
         CASE WHEN n = 0 THEN 'ok' WHEN n <= 2 THEN 'warn' ELSE 'fail' END,
         n::numeric, msg FROM agg;

  RETURN QUERY
  WITH stuck AS (
    SELECT count(*)::int AS n, string_agg(jobname, ', ') AS msg
    FROM cron.job j
    WHERE j.active AND j.schedule !~ '^[0-9]+ [0-9]+'
      AND NOT EXISTS (
        SELECT 1 FROM cron.job_run_details r
        WHERE r.jobid = j.jobid AND r.status = 'succeeded'
          AND r.start_time > now() - interval '90 minutes'
      )
  )
  SELECT 'cron'::text, 'subhourly_jobs_silent_90min'::text,
         CASE WHEN n = 0 THEN 'ok' WHEN n <= 3 THEN 'warn' ELSE 'fail' END,
         n::numeric, msg FROM stuck;

  RETURN QUERY
  WITH bad AS (
    SELECT count(*)::int AS n, string_agg(p.proname, ', ') AS msg
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.prokind = 'f'
      AND pg_get_functiondef(p.oid) ~* '\m(hmac|digest|gen_random_bytes|encrypt|decrypt)\s*\('
      AND NOT EXISTS (
        SELECT 1 FROM unnest(coalesce(p.proconfig, ARRAY[]::text[])) cfg
        WHERE cfg ILIKE 'search_path=%extensions%'
      )
  )
  SELECT 'functions'::text, 'pgcrypto_missing_extensions_searchpath'::text,
         CASE WHEN n = 0 THEN 'ok' ELSE 'fail' END,
         n::numeric, msg FROM bad;

  RETURN QUERY
  WITH bad AS (
    SELECT count(*)::int AS n, string_agg(c.relname, ', ' ORDER BY c.relname) AS msg
    FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public' AND c.relkind = 'v'
      AND NOT EXISTS (
        SELECT 1 FROM unnest(coalesce(c.reloptions, ARRAY[]::text[])) opt
        WHERE opt = 'security_invoker=true'
      )
      AND c.relname NOT LIKE 'pg_%'
  )
  SELECT 'views'::text, 'security_definer_views'::text,
         CASE WHEN n = 0 THEN 'ok' WHEN n <= 3 THEN 'warn' ELSE 'fail' END,
         n::numeric, msg FROM bad;

  RETURN QUERY
  WITH nv AS (
    SELECT count(*)::int AS n, string_agg(conname, ', ' ORDER BY conname) AS msg
    FROM pg_constraint WHERE contype = 'f' AND NOT convalidated
  )
  SELECT 'fks'::text, 'not_valid_fks'::text,
         CASE WHEN n = 0 THEN 'ok' WHEN n <= 60 THEN 'warn' ELSE 'fail' END,
         n::numeric, msg FROM nv;

  RETURN QUERY
  SELECT x.check_class, x.check_name,
    CASE
      WHEN x.metric IS NULL          THEN 'warn'
      WHEN x.metric <  60            THEN 'ok'
      WHEN x.metric <  240           THEN 'warn'
      ELSE                                'fail'
    END,
    x.metric,
    CASE
      WHEN x.metric IS NULL THEN 'no rows yet'
      WHEN x.metric < 60    THEN 'fresh'
      WHEN x.metric < 240   THEN round(x.metric)::text || ' min stale'
      ELSE                       round(x.metric)::text || ' min stale - investigate'
    END
  FROM (VALUES
    ('data_freshness'::text, 'evo_orders_age_min'::text,
      (SELECT EXTRACT(epoch FROM (now() - max(pulled_at)))/60 FROM public.evo_orders)::numeric),
    ('data_freshness',       'listings_snapshots_age_min',
      (SELECT EXTRACT(epoch FROM (now() - max(captured_at)))/60 FROM public.listings_snapshots)),
    ('data_freshness',       'espn_event_snapshots_age_min',
      (SELECT EXTRACT(epoch FROM (now() - max(captured_at)))/60 FROM public.espn_event_snapshots)),
    ('data_freshness',       'vivid_orders_age_min',
      (SELECT EXTRACT(epoch FROM (now() - max(pulled_at)))/60 FROM public.vivid_orders))
  ) AS x(check_class, check_name, metric);

  RETURN QUERY
  WITH q AS (
    SELECT
      (SELECT count(*) FROM public.vivid_orders_pending     WHERE resolved_at IS NULL) AS vivid_pending,
      (SELECT count(*) FROM public.tickpick_orders_pending  WHERE resolved_at IS NULL) AS tickpick_pending
  )
  SELECT 'queues'::text, 'unresolved_pending_total'::text,
         CASE WHEN vivid_pending + tickpick_pending = 0 THEN 'ok'
              WHEN vivid_pending + tickpick_pending < 20 THEN 'warn' ELSE 'fail' END,
         (vivid_pending + tickpick_pending)::numeric,
         format('vivid=%s, tickpick=%s', vivid_pending, tickpick_pending)
  FROM q;

  -- bot_chat aging (from 20260515340000)
  RETURN QUERY
  WITH a AS (
    SELECT count(*)::int AS n,
           string_agg(id::text || ':' || event_type, ', ' ORDER BY created_at) AS msg
      FROM public.v_bot_chat_unresolved
     WHERE event_type IN ('p0_security','flag','question')
       AND created_at < now() - interval '7 days'
  )
  SELECT 'coordination'::text, 'bot_chat_aging_7d'::text,
         CASE WHEN n = 0 THEN 'ok' WHEN n <= 5 THEN 'warn' ELSE 'fail' END,
         n::numeric,
         coalesce(msg, format('%s actionable items unresolved >7 days (warn at >0, fail at >5)', n))
    FROM a;

  -- pg_net error rate (from 20260515340000, integrating A1's helper)
  RETURN QUERY SELECT * FROM public._health_check_pg_net_errors();

  -- NEW (this migration): per-cron heartbeat
  RETURN QUERY SELECT * FROM public._health_check_cron_heartbeat();

  RETURN;
END $function$;
