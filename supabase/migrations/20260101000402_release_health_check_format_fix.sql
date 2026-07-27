-- Migration 20260515290000 · level:admin · lane:Audit/Push · writes:release_health_check() fn · pre:20260515280000
-- Fix pre-existing bug flagged earlier this session: format('%.0f', ...) is not
-- valid PostgreSQL format() syntax (that's printf). Triggered whenever any
-- data_freshness metric crosses 60 min — which started happening as soon as
-- ingest crons were paused on 2026-05-14. Without this fix, release_health_check()
-- itself throws an error and we can't read the rest of the checks.
--
-- Replacement: round(x.metric)::text || ' min stale' — same display, valid SQL.
--
-- ## Already applied to prod  Applied via MCP 2026-05-15.
CREATE OR REPLACE FUNCTION public.release_health_check()
 RETURNS TABLE(check_class text, check_name text, status text, metric numeric, detail text)
 LANGUAGE plpgsql STABLE SET search_path TO 'public', 'pg_temp'
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

  RETURN;
END $function$;
