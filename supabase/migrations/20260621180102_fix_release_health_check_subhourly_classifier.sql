-- ============================================================================
-- Migration 20260621180102 — fix release_health_check() sub-hourly classifier
--
-- Lane:     A1 (data plane / release-health harness)
-- Touches:  public.release_health_check (W, CREATE OR REPLACE)
-- Pre-reqs: 20260515170000 (function exists), later format/aging edits folded in
-- Apply:    APPLIED to prod 2026-06-21 (operator-authorized, full permissions).
--           Verified: subhourly_jobs_silent_90min fail->warn, metric 5->1.
--
-- WHY:
--   The `subhourly_jobs_silent_90min` check mis-classifies daily / multi-hour
--   jobs as "silent sub-hourly" and tips the harness into FAIL, which the C1
--   checkpoint runbook uses to HOLD all PR merges. Verified 2026-06-21: of the
--   5 jobs flagged, 4 were false positives —
--     listings_deltas_backfill_overnight  '30-44 4 * * *'  (daily 04:30)
--     sg_canonical_link_overnight         '46-59 4 * * *'  (daily 04:46)
--     collect-listings-7-30d              '10 */4 * * *'    (every 4h)
--     collect-listings-30-60d             '15 */12 * * *'   (every 12h)
--   Only sweep_duplicate_listings_hourly '15 * * * *' was a real failure (and
--   it is already counted by failed_jobs_90min).
--
-- ROOT CAUSE:
--   The exclusion predicate `schedule !~ '^[0-9]+ [0-9]+'` only excludes literal
--   `MM HH ...` daily schedules. It does NOT exclude range minutes ('30-44 4'),
--   or stepped hours ('10 */4', '15 */12') — so those non-sub-hourly jobs are
--   treated as expected-every-90-min and flagged the moment they're between runs.
--
-- FIX:
--   Replace the brittle regex with a field-aware classifier. A job is
--   "expected to fire within any 90-min window" only if it is pg_cron interval
--   syntax ('N seconds'/'N minutes'), OR a 5-field cron whose hour, day-of-month,
--   month, and day-of-week fields are all unrestricted ('*'). Everything else
--   (hour-restricted, stepped-hour, range-minute-on-fixed-hour) is correctly
--   excluded. No other check is changed.
--
-- VERIFICATION (run after apply):
--   SELECT * FROM public.release_health_check()
--    WHERE check_name='subhourly_jobs_silent_90min';
--   -- expect only genuinely-hourly-or-faster silent jobs in `detail`;
--   -- the 4 daily/multi-hour false positives must NOT appear.
-- ============================================================================

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
    WHERE j.active
      AND (
        -- pg_cron interval syntax ('N seconds' / 'N minutes') — always sub-90min
        j.schedule ~ '^\s*\d+\s+(seconds?|minutes?)\s*$'
        OR (
          -- 5-field cron able to fire every hour of every day:
          -- hour, day-of-month, month, day-of-week must all be unrestricted.
          split_part(j.schedule, ' ', 2) = '*'   -- hour
          AND split_part(j.schedule, ' ', 3) = '*'   -- day-of-month
          AND split_part(j.schedule, ' ', 4) = '*'   -- month
          AND split_part(j.schedule, ' ', 5) = '*'   -- day-of-week
        )
      )
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

  RETURN;
END $function$;
