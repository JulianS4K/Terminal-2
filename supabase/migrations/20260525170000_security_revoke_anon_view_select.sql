-- ============================================================================
-- Migration 20260525170000 · level:security · lane:Security
-- writes: REVOKE ALL ... FROM anon on 12 security-definer views
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
-- These 12 are SECURITY DEFINER (no security_invoker=true), so a read runs as
-- the view OWNER and BYPASSES underlying-table RLS — anon (the publishable key,
-- shipped in frontend JS, no login required) reads the full result set over
-- PostgREST: GET /rest/v1/<view>.  anon also has schema USAGE on public.
--
-- FINDINGS CLOSED HERE
-- -------------------------------------------------------------------------
-- SEC-HIGH (3 order views) — PII + financials readable by anyone with the
--   public anon key, no login:
--     * unified_orders          — buyer_name, seller_name, client_name,
--                                  gross_value, quantity, event_name/date ...
--     * unified_orders_by_event — per-event order rollups (sale counts/values)
--     * order_status_coverage   — order volume/recency by source+status
-- SEC-MED (9 broker-intelligence views) — competitive market intel that the
--   §D1 wall reserves for brokers (authenticated @s4kent), leaking to anon:
--     v_event_price_arbitrage, v_event_velocity_windows, v_returning_entities,
--     v_aq_match_quality, v_orphan_seatgeek_data, v_sg_blindspot_movers,
--     v_tevo_blindspot_movers, v_sg_broker_429_health,
--     v_sg_broker_429_starved_events
--
-- The inherited write grants (INSERT/UPDATE/DELETE/TRUNCATE) are inert today —
-- all 12 are non-updatable views (UNION / aggregate / join / DISTINCT ON / WITH)
-- so writes error — but REVOKE ALL clears them anyway (defense-in-depth).
--
-- SAFE — no anon-key frontend consumes any of these 12:
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
-- PostgREST anon callers — intentionally lose access to these 12 views.
--   Re-probe after apply: SET ROLE anon; SELECT FROM public.unified_orders LIMIT 1; -> permission denied.
--
-- ## Already applied to prod
-- NOT YET. Operator authorizes prod apply (2026-05-13 lockdown). Some views are
-- D2/D0/D3-owned; REVOKE-from-anon is the least-invasive hardening (no view-logic
-- or authenticated-access change) — owning lanes flagged in the PR for sign-off.
-- ============================================================================

-- --- SEC-HIGH: order views (PII + financials) -------------------------------
REVOKE ALL ON public.unified_orders          FROM anon;
REVOKE ALL ON public.unified_orders_by_event FROM anon;
REVOKE ALL ON public.order_status_coverage   FROM anon;

-- --- SEC-MED: broker market-intelligence views (§D1 wall: broker-only) -------
REVOKE ALL ON public.v_event_price_arbitrage        FROM anon;
REVOKE ALL ON public.v_event_velocity_windows       FROM anon;
REVOKE ALL ON public.v_returning_entities           FROM anon;
REVOKE ALL ON public.v_aq_match_quality             FROM anon;
REVOKE ALL ON public.v_orphan_seatgeek_data         FROM anon;
REVOKE ALL ON public.v_sg_blindspot_movers          FROM anon;
REVOKE ALL ON public.v_tevo_blindspot_movers        FROM anon;
REVOKE ALL ON public.v_sg_broker_429_health         FROM anon;
REVOKE ALL ON public.v_sg_broker_429_starved_events FROM anon;

-- --- Tier-2 (event metadata) — DO NOT UNCOMMENT until D0/D1 confirm no anon
--     public/SEO event page reads these. Fully reversible (GRANT SELECT TO anon).
-- REVOKE ALL ON public.espn_injury_snapshot_latest FROM anon;
-- REVOKE ALL ON public.seatgeek_event_latest       FROM anon;
-- REVOKE ALL ON public.v_event_full_sports         FROM anon;
-- REVOKE ALL ON public.v_event_full_v2             FROM anon;
