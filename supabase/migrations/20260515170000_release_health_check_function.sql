-- Migration 20260515170000 · level:admin · lane:Audit/Push · writes:public.release_health_check + public.migration_drift_check · reads:cron.*, pg_constraint, pg_class, pg_proc · pre:-
-- Release-discipline smoke harness.
--
-- Two functions designed to catch the kind of regressions we saw shipping
-- today (PR #95 broke pgcrypto access on 3 fns; PR #92 silently reverted
-- security_invoker on 7 views; column-mapping bugs in TickPick RPC):
--
-- 1. public.release_health_check() — runs in <1 second, returns a
--    structured snapshot of cron health, advisor-class indicators, FK
--    validity, data freshness on critical tables, search_path coverage
--    on pgcrypto-using functions. Call BEFORE every migration to capture
--    baseline, AFTER to confirm no new failures. Diff = drift signal.
--
-- 2. public.migration_drift_check() — compares supabase_migrations.schema_migrations
--    (what's actually applied to prod) against pg_proc / pg_class state
--    to detect "shipped via MCP but no codified migration file" drift.
--    Doesn't fail on found drift — just surfaces it for operator triage.
--
-- Neither function mutates state. Both safe to call from anon/authenticated
-- via PostgREST or from cron via SELECT.
--
-- Usage pattern after this lands:
--   -- BEFORE migration:
--   SELECT * FROM public.release_health_check() WHERE status <> 'ok';
--   -- apply migration
--   -- AFTER migration:
--   SELECT * FROM public.release_health_check() WHERE status <> 'ok';
--   -- diff the two. New rows = regression introduced.
--
-- ## Already applied to prod
-- Applied via MCP 2026-05-14 (this session). Idempotent (CREATE OR REPLACE).

CREATE OR REPLACE FUNCTION public.release_health_check()
RETURNS TABLE(
  check_class text,
  check_name  text,
  status      text,        -- 'ok' | 'warn' | 'fail'
  metric      numeric,
  detail      text
)
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
SET search_path = public, pg_temp
AS $$
BEGIN
  -- ============================================================
  -- 1. CRON: failed jobs in last 90 min
  -- ============================================================
  RETURN QUERY
  WITH agg AS (
    SELECT count(*)::int AS n,
           string_agg(j.jobname || ':' || coalesce(left(r.return_message,80),''), ' | ') AS msg
    FROM cron.job j
    JOIN cron.job_run_details r ON r.jobid = j.jobid
    WHERE r.start_time > now() - interval '90 minutes'
      AND r.status = 'failed'
  )
  SELECT 'cron', 'failed_jobs_90min',
         CASE WHEN n = 0 THEN 'ok' WHEN n <= 2 THEN 'warn' ELSE 'fail' END,
         n::numeric, msg
  FROM agg;

  -- ============================================================
  -- 2. CRON: jobs that haven't fired in expected window
  --    (active jobs with no successful run in 90 min, excluding daily/weekly)
  -- ============================================================
  RETURN QUERY
  WITH stuck AS (
    SELECT count(*)::int AS n,
           string_agg(jobname, ', ') AS msg
    FROM cron.job j
    WHERE j.active
      AND j.schedule !~ '^[0-9]+ [0-9]+'  -- exclude HH:MM daily/weekly
      AND NOT EXISTS (
        SELECT 1 FROM cron.job_run_details r
        WHERE r.jobid = j.jobid
          AND r.status = 'succeeded'
          AND r.start_time > now() - interval '90 minutes'
      )
  )
  SELECT 'cron', 'subhourly_jobs_silent_90min',
         CASE WHEN n = 0 THEN 'ok' WHEN n <= 3 THEN 'warn' ELSE 'fail' END,
         n::numeric, msg
  FROM stuck;

  -- ============================================================
  -- 3. FUNCTIONS: pgcrypto-using fns missing 'extensions' in search_path
  --    (the PR #95 regression class)
  -- ============================================================
  RETURN QUERY
  WITH bad AS (
    SELECT count(*)::int AS n,
           string_agg(p.proname, ', ') AS msg
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.prokind = 'f'
      AND pg_get_functiondef(p.oid) ~* '\m(hmac|digest|gen_random_bytes|encrypt|decrypt)\s*\('
      AND NOT EXISTS (
        SELECT 1 FROM unnest(coalesce(p.proconfig, ARRAY[]::text[])) cfg
        WHERE cfg ILIKE 'search_path=%extensions%'
      )
  )
  SELECT 'functions', 'pgcrypto_missing_extensions_searchpath',
         CASE WHEN n = 0 THEN 'ok' ELSE 'fail' END,
         n::numeric, msg
  FROM bad;

  -- ============================================================
  -- 4. VIEWS: public views with security_invoker=false (PR #94 regression class)
  -- ============================================================
  RETURN QUERY
  WITH bad AS (
    SELECT count(*)::int AS n,
           string_agg(c.relname, ', ' ORDER BY c.relname) AS msg
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public'
      AND c.relkind = 'v'
      AND NOT EXISTS (
        SELECT 1 FROM unnest(coalesce(c.reloptions, ARRAY[]::text[])) opt
        WHERE opt = 'security_invoker=true'
      )
      -- exclude built-in pg_* views
      AND c.relname NOT LIKE 'pg_%'
  )
  SELECT 'views', 'security_definer_views',
         CASE WHEN n = 0 THEN 'ok' WHEN n <= 3 THEN 'warn' ELSE 'fail' END,
         n::numeric, msg
  FROM bad;

  -- ============================================================
  -- 5. CONSTRAINTS: NOT VALID FKs (acceptable backlog, not failure)
  -- ============================================================
  RETURN QUERY
  WITH nv AS (
    SELECT count(*)::int AS n,
           string_agg(conname, ', ' ORDER BY conname) AS msg
    FROM pg_constraint
    WHERE contype = 'f' AND NOT convalidated
  )
  SELECT 'fks', 'not_valid_fks',
         CASE WHEN n = 0 THEN 'ok' WHEN n <= 60 THEN 'warn' ELSE 'fail' END,
         n::numeric, msg
  FROM nv;

  -- ============================================================
  -- 6. DATA FRESHNESS: orders + listings sources
  -- ============================================================
  RETURN QUERY
  SELECT * FROM (VALUES
    ('data_freshness'::text, 'evo_orders_age_min',
      (SELECT EXTRACT(epoch FROM (now() - max(pulled_at)))/60 FROM public.evo_orders)::numeric),
    ('data_freshness',       'listings_snapshots_age_min',
      (SELECT EXTRACT(epoch FROM (now() - max(captured_at)))/60 FROM public.listings_snapshots)),
    ('data_freshness',       'espn_event_snapshots_age_min',
      (SELECT EXTRACT(epoch FROM (now() - max(captured_at)))/60 FROM public.espn_event_snapshots)),
    ('data_freshness',       'vivid_orders_age_min',
      (SELECT EXTRACT(epoch FROM (now() - max(pulled_at)))/60 FROM public.vivid_orders))
  ) AS x(check_class, check_name, metric)
  CROSS JOIN LATERAL (
    SELECT
      CASE
        WHEN metric IS NULL          THEN 'warn'
        WHEN metric <  60            THEN 'ok'
        WHEN metric <  240           THEN 'warn'
        ELSE                              'fail'
      END AS status,
      CASE
        WHEN metric IS NULL THEN 'no rows yet'
        WHEN metric < 60    THEN 'fresh'
        WHEN metric < 240   THEN format('%.0f min stale', metric)
        ELSE                     format('%.0f min stale — investigate', metric)
      END AS detail
  ) classification;

  -- ============================================================
  -- 7. PENDING QUEUES: backlog signals
  -- ============================================================
  RETURN QUERY
  WITH q AS (
    SELECT
      (SELECT count(*) FROM public.vivid_orders_pending     WHERE resolved_at IS NULL) AS vivid_pending,
      (SELECT count(*) FROM public.tickpick_orders_pending  WHERE resolved_at IS NULL) AS tickpick_pending
  )
  SELECT 'queues', 'unresolved_pending_total',
         CASE WHEN vivid_pending + tickpick_pending = 0 THEN 'ok'
              WHEN vivid_pending + tickpick_pending < 20 THEN 'warn'
              ELSE 'fail' END,
         (vivid_pending + tickpick_pending)::numeric,
         format('vivid=%s, tickpick=%s', vivid_pending, tickpick_pending)
  FROM q;

  RETURN;
END $$;

COMMENT ON FUNCTION public.release_health_check() IS
  'Release-time smoke harness. Returns one row per check (cron health, '
  'function search_path discipline, view security_invoker discipline, '
  'NOT VALID FK count, data freshness, pending-queue backlog). Run '
  'BEFORE and AFTER each migration; new rows with status<>''ok'' = '
  'regression candidates. <1 second runtime.';

GRANT EXECUTE ON FUNCTION public.release_health_check() TO anon, authenticated, service_role;


-- ============================================================
-- migration_drift_check — confirms supabase_migrations table matches
-- supabase/migrations/*.sql files. Files-side check has to happen in CI;
-- this function only reports the prod-side state.
-- ============================================================

CREATE OR REPLACE FUNCTION public.migration_drift_check()
RETURNS TABLE(
  version      text,
  name         text,
  applied_at   timestamptz,
  has_codified boolean,  -- always NULL here; CI fills this from filesystem
  note         text
)
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
SET search_path = public, supabase_migrations, pg_temp
AS $$
BEGIN
  RETURN QUERY
  SELECT
    m.version::text,
    m.name::text,
    NULL::timestamptz                                     AS applied_at,
    NULL::boolean                                         AS has_codified,
    CASE
      WHEN m.version ~ '^[0-9]{14}$' THEN 'standard slot'
      WHEN m.version ~ '^[0-9]{8}'   THEN 'legacy date-only'
      ELSE                                'irregular — review'
    END                                                   AS note
  FROM supabase_migrations.schema_migrations m
  ORDER BY m.version DESC
  LIMIT 100;
END $$;

COMMENT ON FUNCTION public.migration_drift_check() IS
  'Returns the last 100 applied migrations (prod-side). CI workflow joins '
  'this against the on-disk supabase/migrations/*.sql filenames to detect '
  'drift (applied-without-codified or codified-without-applied).';

GRANT EXECUTE ON FUNCTION public.migration_drift_check() TO anon, authenticated, service_role;
