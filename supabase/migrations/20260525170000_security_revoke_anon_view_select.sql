-- ============================================================================
-- Migration 20260525170000 · level:security · lane:Security
-- writes: REVOKE ALL ... FROM anon on 12 security-definer views + 2 matviews
-- reads:  pg_class, information_schema (audit only)
-- pre:    none (idempotent REVOKE; authenticated/service_role untouched)
--
-- B1 sweep 2026-05-25 (operator "FULL KGB ... entry points and data leaks").
-- release_health_check().views.security_definer_views = 19 (fail). Triaging the
-- 19 surfaced a LIVE anon data leak that PR #298 did not cover: #298 swept anon
-- EXECUTE on functions + one table, but NOT view SELECT grants. The harness's
-- table-RLS check also does not cover views (views have no RLS — their boundary
-- is grant + security_invoker).
--
-- ROOT CAUSE — the same Supabase default-grant gotcha as #298, on VIEWS:
-- every new public view is auto-GRANTed ALL privileges to anon + authenticated.
-- These 14 are SECURITY DEFINER (no security_invoker=true), so a read runs as
-- the view OWNER and BYPASSES underlying-table RLS — anon (the publishable key,
-- shipped in frontend JS, no login required) reads the full result set over
-- PostgREST: GET /rest/v1/<view>.  anon also has schema USAGE on public.
--
-- EMPIRICALLY CONFIRMED (SET ROLE anon; SELECT ...): all 14 objects below are
-- owned by `postgres` (rolbypassrls=true) and are SECURITY DEFINER
-- (security_invoker is NOT set), so an anon read runs as postgres and BYPASSES
-- underlying-table RLS — anon sees every row. Live counts at audit time:
--   v_event_price_arbitrage = 3681 anon rows; latest_event_metrics = 1411.
-- (By contrast, all 140 anon-readable BASE TABLES have RLS ON, and the ~130
--  security_invoker=true views evaluate anon's RLS against them — those do NOT
--  leak. The definer objects below are the bounded leak surface.)
--
-- FINDINGS CLOSED HERE  (14 objects = 12 views + 2 matviews)
-- -------------------------------------------------------------------------
-- SEC-MED, LIVE — broker market-intelligence the §D1 wall reserves for
--   authenticated brokers (@s4kent), readable by anyone with the public anon
--   key, no login. Confirmed returning thousands of rows:
--     v_event_price_arbitrage, v_event_velocity_windows, v_returning_entities,
--     v_aq_match_quality, v_orphan_seatgeek_data, v_sg_blindspot_movers,
--     v_tevo_blindspot_movers, v_sg_broker_429_health,
--     v_sg_broker_429_starved_events,
--     latest_event_metrics (matview, 1411 rows), v_dashboard_writes_24h (matview)
-- SEC-HIGH, LATENT — order views: PII-bearing (buyer_name, seller_name,
--   client_name, gross_value, quantity) and anon-readable, but currently yield
--   0 rows (source order tables empty/filtered at audit time). Re-activates to
--   a live PII leak the moment orders flow — fix now:
--     unified_orders, unified_orders_by_event, order_status_coverage
--
-- The 2 matviews (latest_event_metrics, v_dashboard_writes_24h) are flagged by
-- NEITHER release_health_check category (security_definer_views is relkind='v';
-- the table-RLS check skips matviews) — found via a full anon-readable-surface
-- enumeration, not the harness.  mv_sg_blindspot_movers already has anon=false.
--
-- The inherited write grants (INSERT/UPDATE/DELETE/TRUNCATE) are inert — all 12
-- views are non-updatable (is_updatable=NO, verified) and matview writes need
-- privilege anon lacks — but REVOKE ALL clears them anyway (defense-in-depth).
--
-- NOTE: this REVOKE does NOT change release_health_check.security_definer_views
-- (that counts security_invoker absence, not anon grants; these views are
-- INTENTIONALLY owner-run). Verify via the anon-read probe below, not that row.
--
-- SAFE — no anon-key frontend consumes any of these 14:
--   * D2 ops dashboard (d2_dashboard/static/dashboard.js) initialises supabase-js
--     with the anon key as the apikey header but REQUIRES login and sends
--     Authorization: Bearer <user access_token> — its reads execute as
--     `authenticated`, which RETAINS ALL grants here. Unaffected.
--   * D1 storefront reads via /api/store/* (FastAPI, service_role server-side),
--     not direct anon PostgREST. Unaffected.
--   * service_role (edge fns / FastAPI / crons) RETAINS ALL. Unaffected.
--   Repo grep (*.js/ts/html) finds zero anon-client references to these views.
--
-- NOT CLOSED HERE (filed as follow-ups — see PR body):
--   * Tier-2 (SEC-MED, D0/D1 lane): 4 event-metadata views still anon-readable
--     — espn_injury_snapshot_latest, seatgeek_event_latest, v_event_full_sports,
--     v_event_full_v2. Low sensitivity; NOT revoked here to avoid breaking an
--     unaudited public/SEO event page. Owners confirm no anon-page dependency,
--     then uncomment the Tier-2 block below (one line each, fully reversible).
--   * Tier-3 (SEC-MED, D2/D0 lane): even post-revoke, ANY authenticated user
--     (not only @s4kent) reads these — proper fix is security_invoker=true + RLS
--     or an auth.jwt() email gate on the order/intel views. Owning-lane work.
--
-- INTENTIONALLY UNTOUCHED — exos_public_events / exos_public_orgs /
--   exos_public_tiers are the reviewed owner-run public boundary (anon=SELECT
--   only, scoped by 20260524160000_exos_security_hardening). Correct as-is.
--
-- ## Regression risk
-- cron.failed_jobs_90min — none (no function/cron touched).
-- PostgREST authenticated/service_role callers — unaffected (grants retained).
-- PostgREST anon callers — intentionally lose access to these 14 objects.
--   Re-probe after apply: SET ROLE anon; SELECT FROM public.v_event_price_arbitrage LIMIT 1; -> permission denied.
--
-- ## Already applied to prod
-- NOT YET. Operator authorizes prod apply (2026-05-13 lockdown). Some views are
-- D2/D0/D3-owned; REVOKE-from-anon is the least-invasive hardening (no view-logic
-- or authenticated-access change) — owning lanes flagged in the PR for sign-off.
-- ============================================================================

-- --- SEC-HIGH (latent: 0 rows now, PII-bearing): order views ----------------
REVOKE ALL ON public.unified_orders          FROM anon;
REVOKE ALL ON public.unified_orders_by_event FROM anon;
REVOKE ALL ON public.order_status_coverage   FROM anon;

-- --- SEC-MED (LIVE): broker market-intelligence views (§D1 wall: broker-only) -
REVOKE ALL ON public.v_event_price_arbitrage        FROM anon;  -- 3681 anon rows @ audit
REVOKE ALL ON public.v_event_velocity_windows       FROM anon;
REVOKE ALL ON public.v_returning_entities           FROM anon;
REVOKE ALL ON public.v_aq_match_quality             FROM anon;
REVOKE ALL ON public.v_orphan_seatgeek_data         FROM anon;
REVOKE ALL ON public.v_sg_blindspot_movers          FROM anon;
REVOKE ALL ON public.v_tevo_blindspot_movers        FROM anon;
REVOKE ALL ON public.v_sg_broker_429_health         FROM anon;
REVOKE ALL ON public.v_sg_broker_429_starved_events FROM anon;

-- --- SEC-MED (LIVE): materialized views — uncovered by both health-check
--     categories (relkind='m'); found via full anon-surface enumeration --------
REVOKE ALL ON public.latest_event_metrics   FROM anon;  -- 1411 anon rows @ audit
REVOKE ALL ON public.v_dashboard_writes_24h FROM anon;

-- --- Tier-2 (event metadata) — DO NOT UNCOMMENT until D0/D1 confirm no anon
--     public/SEO event page reads these. Fully reversible (GRANT SELECT TO anon).
-- REVOKE ALL ON public.espn_injury_snapshot_latest FROM anon;
-- REVOKE ALL ON public.seatgeek_event_latest       FROM anon;
-- REVOKE ALL ON public.v_event_full_sports         FROM anon;
-- REVOKE ALL ON public.v_event_full_v2             FROM anon;
