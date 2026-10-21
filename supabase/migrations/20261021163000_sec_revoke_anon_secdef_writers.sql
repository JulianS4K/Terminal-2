-- Migration 20261021163000 · level:security · lane:A1 (DB security; Auditor cross-cut per PROJECT_BIBLE §2.8.3) · writes:none (grants only) · reads:pg_proc · pre:none
--
-- ============================================================================
-- Migration 20261021163000 — revoke anon/authenticated EXECUTE on 32 SECDEF writer fns
--
-- Lane:     A1 (DB security) · filed from the 2026-10-21 read-only audit (KANBAN A1-DB-12)
-- Touches:  GRANT/REVOKE only — no table rows, no function bodies change.
--           32 SECURITY DEFINER functions (list below) → service_role only.
--           7 staff/session-gated RPCs the browser calls with a user session →
--           revoke from anon only (authenticated keeps EXECUTE).
-- Pre-reqs: none. Idempotent (re-apply is a no-op). Reversible by re-GRANT.
--
-- WHY: two compounding facts found 2026-10-21:
--   1. `pg_default_acl` for role postgres in schema public grants EXECUTE to anon
--      and authenticated on EVERY new function, so a migration that forgets the
--      §2.8 REVOKE ships an anon-callable function. 202 of 960 SECDEF fns are
--      anon-executable today.
--   2. The §2.8 body guard `IF current_user NOT IN ('service_role','postgres',
--      'supabase_admin')` is a no-op: inside a SECURITY DEFINER function
--      `current_user` is the function OWNER (postgres), so the branch never
--      fires regardless of who called it. 143 fns carry it; 30 of them are
--      anon-executable and therefore callable by anyone holding the public anon
--      key. Among them: functions that fire pg_net HTTP requests to TEvo and the
--      S4K CRM using vault credentials (`tevo_venue_*_enqueue`,
--      `s4kcs_orders_queue`), and heavy rebuilds (`scan_listing_deals`,
--      `deal_price_train_build`, `rebuild_*_baseline`) = quota-burn + DoS vector.
--   REVOKE is the only effective gate. Nothing in static/, routers/, core/ or
--   supabase/functions calls any of the 32 with the anon or a user key (verified
--   by grep 2026-10-21); their only callers are pg_cron and service-role code.
--
-- Rollback: GRANT EXECUTE ON FUNCTION <sig> TO anon, authenticated; for any fn
--   a surface turns out to need (and add that surface to the list below).
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Service-role-only: every overload of each name (by name so new overloads
--    added later under the same name are caught on re-apply).
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_names text[] := ARRAY[
    -- unguarded writers (no body guard at all)
    's4kcs_orders_queue', 's4kcs_orders_process',
    'paciolan_apply_aq', 'paciolan_enqueue_due',
    -- guard-only (no-op guard, see WHY) — cron/service-role callers only
    'aq_link_gotickets_by_event_match', 'aq_link_gotickets_from_catalogue',
    'aq_link_tevo_from_sibling_rows',
    'deal_price_adjust_refresh', 'deal_price_train_build',
    'evaluate_tracked_deals', 'event_catalogue_drift_scan',
    'event_date_reconcile_queue', 'event_date_reconcile_tick',
    'gotickets_backfill_tevo_from_hub', 'mapping_health_check', 'pg_net_reap',
    'rebuild_section_sale_baseline', 'rebuild_section_sale_baseline_cz',
    'rebuild_zone_price_baseline', 'refresh_performer_eol_calibration',
    's4kcs_venue_alias_derive', 'scan_listing_deals', 'snapshot_deal_models',
    'tevo_venue_alias_adopt',
    'tevo_venue_daily_enqueue', 'tevo_venue_daily_harvest',
    'tevo_venue_events_enqueue', 'tevo_venue_events_harvest',
    'tevo_venue_search_enqueue', 'tevo_venue_search_harvest',
    'track_current_deals'
  ];
  r record;
  n int := 0;
BEGIN
  FOR r IN
    SELECT p.oid::regprocedure AS sig
    FROM pg_proc p
    JOIN pg_namespace ns ON ns.oid = p.pronamespace
    WHERE ns.nspname = 'public' AND p.proname = ANY (v_names)
  LOOP
    EXECUTE format('REVOKE EXECUTE ON FUNCTION %s FROM PUBLIC, anon, authenticated', r.sig);
    EXECUTE format('GRANT  EXECUTE ON FUNCTION %s TO service_role', r.sig);
    n := n + 1;
  END LOOP;
  RAISE NOTICE '20261021163000: % function overloads set to service_role-only', n;
END $$;

-- ---------------------------------------------------------------------------
-- 2. Browser-called, session-gated RPCs: drop anon only. The terminal
--    (static/terminal/event.js, alerts.js) and fantasy (static/fantasy/
--    fantasy.js) call these with a signed-in session (role = authenticated);
--    their bodies gate on auth.uid() / @s4kent.com email. anon never gets rows
--    from them, so the grant was pure surface area.
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_names text[] := ARRAY[
    'get_event_evo_orders_full', 'get_event_cross_broker_orders_full',
    'get_event_sg_seller_orders_full',
    'fantasy_create_league', 'fantasy_create_demo_league',
    'list_user_alerts', 'set_user_alert_active'
  ];
  r record;
BEGIN
  FOR r IN
    SELECT p.oid::regprocedure AS sig
    FROM pg_proc p
    JOIN pg_namespace ns ON ns.oid = p.pronamespace
    WHERE ns.nspname = 'public' AND p.proname = ANY (v_names)
  LOOP
    EXECUTE format('REVOKE EXECUTE ON FUNCTION %s FROM PUBLIC, anon', r.sig);
    EXECUTE format('GRANT  EXECUTE ON FUNCTION %s TO authenticated, service_role', r.sig);
  END LOOP;
END $$;

-- Post-apply check (expect 0):
--   SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
--   WHERE n.nspname='public' AND p.prosecdef
--     AND p.prosrc LIKE '%current_user NOT IN%'
--     AND has_function_privilege('anon', p.oid, 'EXECUTE');
