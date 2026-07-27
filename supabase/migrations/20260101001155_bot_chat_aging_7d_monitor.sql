-- ============================================================================
-- Migration 20260702140100 — deploy coordination.bot_chat_aging_7d monitor
--
-- Lane:     A1 / B1 monitoring · operator-authorized (2026-07-02)
-- Touches:  public.release_health_check() (CREATE OR REPLACE).
-- Reads:    v_bot_chat_unresolved (added block only); existing base categories unchanged.
--
-- WHY:
--   The bot_chat aging deadman was designed in docs/release-discipline.md §9 and
--   drafted in migration 20260515340000, but that migration was never applied
--   (its own header says "NOT YET"). Live release_health_check() returns 10 rows
--   with no `coordination` class. This adds the missing category so any
--   flag/question/p0_security unresolved >7 days surfaces in the standard smoke
--   harness (warn at >0, fail at >5).
--
--   NOTE: This is rebuilt from the CURRENT live function body (fetched 2026-07-02),
--   NOT the 2026-05-15 draft — the live body has since diverged (improved
--   subhourly-silent regex; security_definer_views now excludes exos_public_%).
--   Applying the stale draft would regress those. Only the one new RETURN QUERY
--   block (bot_chat_aging_7d) is appended; every existing category is byte-for-byte
--   the live version. The pg_net.error_rate_60min block from the old draft is
--   intentionally NOT included here (out of scope for this branch; the helper
--   public._health_check_pg_net_errors() exists and can be wired separately).
--
-- ## Already applied to prod
-- Applied via mcp apply_migration on 2026-07-02 under the operator directive.
-- Idempotent (CREATE OR REPLACE).
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
        j.schedule ~ '^\s*\d+\s+(seconds?|minutes?)\s*$'
        OR (
          split_part(j.schedule, ' ', 2) = '*'
          AND split_part(j.schedule, ' ', 3) = '*'
          AND split_part(j.schedule, ' ', 4) = '*'
          AND split_part(j.schedule, ' ', 5) = '*'
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
        WHERE split_part(opt, '=', 1) = 'security_invoker'
          AND lower(split_part(opt, '=', 2)) IN ('true','on','1','yes')
      )
      AND c.relname NOT LIKE 'pg_%'
      AND c.relname NOT LIKE 'exos_public_%'
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

  -- NEW: coordination.bot_chat_aging_7d — the aging deadman (release-discipline.md §9).
  -- Queries v_bot_chat_unresolved (C1-owned; auto-excludes status-replied parents),
  -- filtered to actionable event_types only so informational rows don't count.
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

  RETURN;
END $function$;
