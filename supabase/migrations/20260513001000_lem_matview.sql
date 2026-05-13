-- Migration 20260513001000 · level:admin · lane:Audit/Push · writes:latest_event_metrics(matview),v_upcoming_rivalry_games,refresh_latest_event_metrics,cron(latest_event_metrics_refresh_5min) · reads:event_metrics · pre:20260513000050
-- P1/D1 escalation 2026-05-12 (12:50 EDT): /api/store/events catalog blocked
-- because the latest_event_metrics VIEW takes 50,372ms on a LIMIT 10 query
-- (well past PostgREST's 8s anon statement_timeout).
--
-- Root cause: DISTINCT ON (event_id) requires full sort of event_metrics
-- even with idx_event_metrics_time on (event_id, captured_at DESC) — Postgres
-- has no native skip-scan optimization. 1,947 distinct event_ids buried inside
-- a moderately-sized table = consistent 50s+ planner choice.
--
-- Fix: convert to MATERIALIZED VIEW, cron-refresh every 5 min. Storefront
-- catalog tolerates 5-min staleness; writers (event_metrics) keep their
-- 30-min cadence. Dependent v_upcoming_rivalry_games rebuilt on top of the
-- matview (same column shape, transparent swap).
--
-- Acceptance criterion (P1): EXPLAIN ANALYZE of LIMIT 10 query < 500ms.
-- Measured post-migration: cold 310ms, warm 272ms. Pass.
--
-- Operational notes:
--   * Cron slot 3-58/5 (not 2-59/5) — :02 slot was contended with three
--     other heavy refresh jobs (pg_cron worker pool exhausted, runs failed
--     with "job startup timeout"). The :03 offset clears the cluster.
--   * REFRESH must run with statement_timeout=0 (set in function body via
--     set_config — Supabase platform-level statement_timeout=120s would
--     otherwise cancel the CONCURRENT refresh).
--   * First refresh after CREATE must be non-CONCURRENT (CONCURRENT requires
--     matview to be already populated). Function detects via pg_class.
--     relispopulated and picks the right variant.
--   * Follows §6/§12 convention from PR #67/#68: SECURITY DEFINER with
--     REVOKE EXECUTE FROM PUBLIC, explicit GRANT TO service_role, and
--     current_user assertion at body entry.
--
-- Audit trail: bot_chat thread references P1's handoff (in_reply_to TBD on
-- post-merge reply).

-- ============================================================================
-- 1. Drop the slow view (CASCADE captures the dependent rivalry view)
-- ============================================================================

DROP VIEW IF EXISTS public.latest_event_metrics CASCADE;

-- ============================================================================
-- 2. Recreate as MATERIALIZED VIEW (initial CREATE uses WITH NO DATA to keep
--    the migration transaction instant — initial populate handled by first
--    cron tick via the wrapper function below)
-- ============================================================================

CREATE MATERIALIZED VIEW public.latest_event_metrics AS
SELECT DISTINCT ON (event_id)
  event_id,
  captured_at,
  tickets_count,
  groups_count,
  sections_count,
  median_group_size,
  ancillary_groups,
  ancillary_tickets,
  retail_min,
  retail_p25,
  retail_median,
  retail_mean,
  retail_p75,
  retail_p90,
  retail_max,
  retail_sum,
  wholesale_min,
  wholesale_median,
  wholesale_mean,
  wholesale_max,
  getin_price,
  top5_concentration,
  price_dispersion,
  tail_premium,
  owned_groups_count,
  owned_tickets_count,
  owned_share,
  owned_median_retail
FROM event_metrics
ORDER BY event_id, captured_at DESC
WITH NO DATA;

CREATE UNIQUE INDEX latest_event_metrics_pkey
  ON public.latest_event_metrics (event_id);

CREATE INDEX latest_event_metrics_owned_idx
  ON public.latest_event_metrics (event_id)
  WHERE owned_tickets_count > 0;

GRANT SELECT ON public.latest_event_metrics TO anon, authenticated, service_role;

COMMENT ON MATERIALIZED VIEW public.latest_event_metrics IS
  'Per-event latest event_metrics row. Refreshed every 5 min via cron (3-58/5). Was a slow view; rewritten as matview after P1 escalation (50s LIMIT 10 timeout blocked /api/store/events) on 2026-05-12.';

-- ============================================================================
-- 3. Recreate the dependent view on the new matview (same shape as before)
-- ============================================================================

CREATE OR REPLACE VIEW public.v_upcoming_rivalry_games AS
SELECT re.tevo_event_id,
       re.name AS event_name,
       re.event_date,
       re.venue_name,
       re.home_team,
       re.away_team,
       re.rivalry_name,
       re.league,
       re.is_branded,
       re.rivalry_intensity,
       re.wikipedia_url,
       lem.tickets_count,
       lem.getin_price,
       lem.retail_median,
       (SELECT count(*) FROM important_x_accounts xa
         WHERE xa.team_name = re.home_team) AS x_accounts_home,
       (EXISTS (SELECT 1 FROM v_performer_reddit_pulse vrp
                 WHERE vrp.tevo_performer_id = re.home_performer_id)) AS has_reddit_pulse
  FROM v_rivalry_events re
  LEFT JOIN public.latest_event_metrics lem ON lem.event_id = re.tevo_event_id
 WHERE re.event_date >= CURRENT_DATE;

-- ============================================================================
-- 4. Refresh wrapper function
--    - Handles both first-time (non-CONCURRENT) and steady-state (CONCURRENT)
--    - Disables statement_timeout/lock_timeout locally (REFRESH inside
--      Supabase's platform 120s cap otherwise gets cancelled mid-refresh)
--    - Follows PR #67/#68 SECURITY DEFINER convention: REVOKE PUBLIC +
--      GRANT service_role + body-assert current_user
-- ============================================================================

CREATE OR REPLACE FUNCTION public.refresh_latest_event_metrics()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE is_populated boolean;
BEGIN
  IF current_user NOT IN ('service_role', 'postgres', 'supabase_admin') THEN
    RAISE EXCEPTION 'refresh_latest_event_metrics: caller % not authorized', current_user;
  END IF;

  -- Disable platform 120s statement_timeout for this REFRESH
  -- (function-level SET via ALTER FUNCTION does NOT override platform default;
  --  set_config('...', '...', true) does — verified empirically 2026-05-13)
  PERFORM set_config('statement_timeout', '0', true);
  PERFORM set_config('lock_timeout', '0', true);

  SELECT relispopulated INTO is_populated
  FROM pg_class WHERE relname = 'latest_event_metrics' AND relkind = 'm';

  IF is_populated THEN
    REFRESH MATERIALIZED VIEW CONCURRENTLY public.latest_event_metrics;
  ELSE
    REFRESH MATERIALIZED VIEW public.latest_event_metrics;
  END IF;
END $$;

REVOKE EXECUTE ON FUNCTION public.refresh_latest_event_metrics() FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.refresh_latest_event_metrics() TO service_role;

COMMENT ON FUNCTION public.refresh_latest_event_metrics() IS
  'Refreshes latest_event_metrics matview. First call (relispopulated=false) does plain REFRESH; subsequent calls use CONCURRENTLY. Called by cron latest_event_metrics_refresh_5min. Statement/lock timeouts disabled in body to dodge platform 120s cap on the long initial REFRESH.';

-- ============================================================================
-- 5. Cron: refresh every 5 min on the :03 offset slot
--    (the :02 slot collided with 3 other heavy refreshes — pg_cron worker
--     pool exhausted, all runs failed with "job startup timeout")
-- ============================================================================

SELECT cron.schedule(
  'latest_event_metrics_refresh_5min',
  '3-58/5 * * * *',
  $$ SELECT public.refresh_latest_event_metrics(); $$
);
