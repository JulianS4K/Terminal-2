-- 20260519270000_c1_security_invoker_views_phase_a.sql
--
-- Cluster 1 (Phase A) from C1's Supabase Action Center brief 2026-05-18.
-- Clears 12 of 13 `security_definer_view` advisor ERRORs on `public.*` views.
-- Postgres 17 supports `security_invoker` as a view reloption.
--
-- DEFERRED (Phase B, separate migration):
--   `v_event_full_sports` reads `public.listings_snapshots`, which has
--   ONLY an `anon USING (true)` policy and NO policy for `authenticated`.
--   Flipping `v_event_full_sports` to invoker would silently empty results
--   for any authenticated direct-view consumer. Resolving requires either
--   (a) adding a d0_s4kent_read policy on listings_snapshots (surface
--   expansion — operator/B1 sign-off needed), or (b) accepting the ERROR.
--
-- RISK CHECK (verified 2026-05-18 against prod):
--   For each of the 12 views, every underlying base table has:
--     - SELECT granted to both anon and authenticated
--     - >=1 SELECT policy for both anon and authenticated
--   So security_invoker flip preserves anon + authenticated read paths.
--   service_role (which most cron / RPC paths run as) bypasses RLS entirely.
--
-- KNOWN BREAK (acceptable):
--   `coworker_readonly` role has SELECT grants but NO policies on the
--   base tables. After flip, direct view reads under coworker_readonly
--   will return empty. C1's brief did not enumerate coworker_readonly as
--   a watched consumer; operator confirms before apply.

ALTER VIEW public.unified_orders                 SET (security_invoker = on);
ALTER VIEW public.unified_orders_by_event        SET (security_invoker = on);
ALTER VIEW public.v_event_full_v2                SET (security_invoker = on);
ALTER VIEW public.v_event_velocity_windows       SET (security_invoker = on);
ALTER VIEW public.v_event_price_arbitrage        SET (security_invoker = on);
ALTER VIEW public.seatgeek_event_latest          SET (security_invoker = on);
ALTER VIEW public.v_orphan_seatgeek_data         SET (security_invoker = on);
ALTER VIEW public.v_sg_broker_429_health         SET (security_invoker = on);
ALTER VIEW public.v_sg_broker_429_starved_events SET (security_invoker = on);
ALTER VIEW public.v_aq_match_quality             SET (security_invoker = on);
ALTER VIEW public.espn_injury_snapshot_latest    SET (security_invoker = on);
ALTER VIEW public.order_status_coverage          SET (security_invoker = on);

-- Phase B will add v_event_full_sports once listings_snapshots policy is settled.

-- ============================================================
-- Post-apply verification
-- ============================================================
-- 1) All 12 views show has_invoker=true:
-- SELECT c.relname,
--        coalesce((SELECT bool_or(opt='security_invoker=true')
--                  FROM unnest(c.reloptions) opt), false) AS has_invoker
-- FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
-- WHERE n.nspname='public'
--   AND c.relname IN ('unified_orders','unified_orders_by_event','v_event_full_v2',
--                     'v_event_velocity_windows','v_event_price_arbitrage','seatgeek_event_latest',
--                     'v_orphan_seatgeek_data','v_sg_broker_429_health','v_sg_broker_429_starved_events',
--                     'v_aq_match_quality','espn_injury_snapshot_latest','order_status_coverage');
--
-- 2) Sample a representative authed-callable view: should still return rows
-- SET LOCAL role authenticated;
-- SET LOCAL request.jwt.claims TO '{"email":"<test>@s4kent.com"}';
-- SELECT count(*) FROM public.v_event_full_v2 LIMIT 1;
-- RESET role;
--
-- 3) Re-run get_advisors(security): expect 12 fewer `security_definer_view` ERRORs.
