-- Migration 20260515340000 · level:security · lane:Security · writes:release_health_check() rewrite (CREATE OR REPLACE) · reads:bot_chat, v_bot_chat_unresolved, pg_proc, pg_class, pg_constraint, cron.job · pre:20260515170000,20260515290000,20260515330000
--
-- B1 monitoring charter — bundles two pending integrations into one
-- `release_health_check()` rewrite:
--
--   1. coordination.bot_chat_aging_7d — designed in docs/release-discipline.md §9
--      (lines 142-144) as a future category. B1 owns p0_security/flag resolution;
--      the aging signal is core to that duty.
--
--   2. pg_net.error_rate_60min — A1 shipped `_health_check_pg_net_errors()` as a
--      standalone helper in 20260515330000 with an open follow-up to integrate.
--      Bundling here saves a slot and keeps the function rewrite atomic.
--
-- Function is SECINVOKER (LANGUAGE plpgsql STABLE; no SECURITY DEFINER) — so
-- BOT_HIERARCHY.md §6 convention does not apply. The existing 7 categories are
-- preserved byte-for-byte; only the two new RETURN QUERY blocks are appended.
--
-- ## Sequencing
-- C1 PR #114 (open at authoring time, 2026-05-15) is part of a Cluster D-1 thread
-- that may reshape v_bot_chat_unresolved view semantics or add new event_type
-- values (e.g. 'checkpoint'). This migration queries v_bot_chat_unresolved with
-- an event_type filter so:
--   (a) view changes by C1 are picked up automatically
--   (b) the filter limits to "needs action" types — won't double-count
--       informational rows (change_log, status, sync, broadcast).
--
-- ## Regression risk
-- cron.failed_jobs_90min  — none (no cron edits).
-- queues.* / data_freshness.* / fks.* — none (categories preserved).
-- Net: function signature and column shape unchanged; downstream callers
-- (release-discipline.md pre/post-migration smoke discipline, CI sync-check)
-- continue to work.
--
-- ## Already applied to prod
-- NOT YET. Operator must authorize prod apply per 2026-05-13 lockdown.
-- Apply via mcp__bccd...__apply_migration with this file's contents.

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

  -- NEW: coordination.bot_chat_aging_7d (B1 monitoring charter)
  -- Designed in docs/release-discipline.md §9. Queries v_bot_chat_unresolved
  -- (forward-compatible with C1's PR #114 view rewrite) filtered to actionable
  -- event_types only.
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

  -- NEW: pg_net.error_rate_60min (integration of A1's _health_check_pg_net_errors)
  -- A1 shipped the helper in 20260515330000; this RETURN QUERY plugs it into
  -- the standard smoke harness.
  RETURN QUERY SELECT * FROM public._health_check_pg_net_errors();

  RETURN;
END $function$;
