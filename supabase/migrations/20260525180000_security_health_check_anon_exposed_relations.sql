-- ============================================================================
-- Migration 20260525180000 · level:security · lane:Security
-- writes: new diagnostic fn public._health_check_anon_exposed_relations()
-- reads:  pg_class, pg_namespace (catalog only)
-- pre:    none (standalone helper; no existing object modified)
--
-- B1 sweep 2026-05-25 follow-up. Closes the monitoring blindspot found while
-- scoping the anon-readable view leak (PR #350): release_health_check's
-- `security_definer_views` check only looks at relkind='v' and flags ALL
-- security-definer views regardless of whether anon can actually read them —
-- so it (a) MISSES anon-readable MATERIALIZED views entirely
-- (latest_event_metrics, v_dashboard_writes_24h were leaking, unflagged), and
-- (b) NOISES on intentional owner-run views (exos_public_*).
--
-- This standalone detector reports the ACTUAL leak condition:
--   relkind IN ('v','m')  -- views + materialized views
--   AND security_invoker is NOT set (definer → runs as owner, bypasses RLS)
--   AND anon holds SELECT (reachable over PostgREST with the publishable key)
--   AND not in the intentional-public allowlist (exos_public_*).
--
-- WHY STANDALONE (not folded into release_health_check): the prod
-- release_health_check() body is BEHIND the on-disk migration chain — it lacks
-- the cron_heartbeat (PR #176), bot_chat_aging_7d, and pg_net categories that
-- are codified in later migrations but not yet applied (2026-05-13 lockdown).
-- Re-emitting it here would risk regressing those unapplied categories when the
-- operator applies migrations in order (release-discipline §10 R2). Shipping a
-- standalone fn (mirrors A1's _health_check_pg_net_errors pattern) sidesteps
-- that; integration is a one-line append done in the NEXT coordinated
-- release_health_check revision (see KANBAN B1-NEXT):
--     RETURN QUERY SELECT * FROM public._health_check_anon_exposed_relations();
--
-- Column shape MATCHES release_health_check's TABLE(...) so the append is drop-in.
-- SECURITY INVOKER (default): pure catalog reads, no privileged data — runs fine
-- as whatever role calls it. REVOKE PUBLIC + GRANT service_role per §6 posture.
--
-- ## Regression risk
-- None — additive. No existing fn/view/cron/grant touched.
--
-- ## Already applied to prod
-- NOT YET. Operator authorizes prod apply (2026-05-13 lockdown).
-- ============================================================================

CREATE OR REPLACE FUNCTION public._health_check_anon_exposed_relations()
RETURNS TABLE(check_class text, check_name text, status text, metric numeric, detail text)
LANGUAGE sql
STABLE
SET search_path TO 'public', 'pg_temp'
AS $function$
  WITH bad AS (
    SELECT c.relkind, c.relname
    FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public'
      AND c.relkind IN ('v','m')
      AND NOT EXISTS (
        SELECT 1 FROM unnest(coalesce(c.reloptions, ARRAY[]::text[])) opt
        WHERE opt = 'security_invoker=true'
      )
      AND has_table_privilege('anon', c.oid, 'SELECT')
      AND c.relname NOT IN ('exos_public_events','exos_public_orgs','exos_public_tiers')
  )
  SELECT 'views'::text,
         'anon_exposed_definer_relations'::text,
         CASE WHEN count(*) = 0 THEN 'ok'
              WHEN count(*) <= 5 THEN 'warn'
              ELSE 'fail' END,
         count(*)::numeric,
         coalesce(string_agg(relkind::text || ':' || relname, ', ' ORDER BY relname), 'none')
    FROM bad;
$function$;

REVOKE EXECUTE ON FUNCTION public._health_check_anon_exposed_relations() FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public._health_check_anon_exposed_relations() TO service_role;
