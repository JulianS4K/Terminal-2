-- Migration 20261021163500 · level:security · lane:A1 (DB security; Auditor cross-cut per PROJECT_BIBLE §2.8.3) · writes:none (grants + RLS flags only) · reads:none · pre:none
--
-- ============================================================================
-- Migration 20261021163500 — close authenticated reads on 5 order/P&L views; RLS on 8 tables
--
-- Lane:     A1 (DB security) · 2026-10-21 audit rows KANBAN A1-DB-1, A1-DB-2, A1-DB-3
-- Touches:  unified_orders, v_n2s_orders, v_n2s_orders_live, v_sub_orders,
--           v_gt_credit_health                       (REVOKE from anon/authenticated)
--           v_reddit_news_ticker                     (keep SELECT; drop DML grants)
--           espn_athlete_brand, athlete_pages, athlete_external_ids,
--           athlete_wikipedia, deal_price_train, deal_price_train_state,
--           deal_price_adjust, zone_price_observations (ENABLE RLS + REVOKE)
-- Pre-reqs: none. Idempotent. Reversible (re-GRANT / DISABLE RLS).
--
-- WHY (views): the five views are SECURITY DEFINER-style (no security_invoker),
--   carry no per-user filter, and `authenticated` holds SELECT — so ANY signed-in
--   account reads every order with buyer/seller/client names and N2S cover P&L
--   over PostgREST. Today all 11 auth users are @s4kent.com staff, but the auth
--   pool is shared with Exos (D4), which will open public sign-up. Supersedes
--   v1 KANBAN B1-NEXT-60. Readers verified 2026-10-21: `unified_orders` ←
--   core/d0_orders.py and `v_n2s_orders` ← routers/broker.py, both through the
--   SERVICE-ROLE client (unaffected); the other three have no reader in the
--   repo. No browser code reads any of them (grep static/ + supabase/functions).
--
-- WHY (tables): the 8 tables are the only RLS-OFF public tables that still carry
--   anon/authenticated grants (Supabase advisor 0013). Readers/writers are all
--   SECDEF builder fns and pg_cron (owner postgres bypasses RLS) — no direct
--   `.from()` read from a browser or the backend. Same shape as
--   20260605150200_sec_p0_rls_exposed_tables.sql: ENABLE RLS, no policies
--   (deny-by-default), REVOKE the grants. If a public athlete page later needs
--   `athlete_*`, add a narrow `FOR SELECT TO anon USING (true)` policy on that
--   table only.
-- ============================================================================

-- 1. Order / P&L views → service_role only
REVOKE ALL ON public.unified_orders     FROM PUBLIC, anon, authenticated;
REVOKE ALL ON public.v_n2s_orders       FROM PUBLIC, anon, authenticated;
REVOKE ALL ON public.v_n2s_orders_live  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON public.v_sub_orders       FROM PUBLIC, anon, authenticated;
REVOKE ALL ON public.v_gt_credit_health FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.unified_orders, public.v_n2s_orders, public.v_n2s_orders_live,
                public.v_sub_orders, public.v_gt_credit_health TO service_role;

-- 2. Public news ticker: read-only is the intent; anon held INSERT/UPDATE/DELETE
REVOKE INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER
  ON public.v_reddit_news_ticker FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.v_reddit_news_ticker TO anon, authenticated;

-- 3. RLS-off tables with client grants → RLS on, grants off
DO $$
DECLARE
  t text;
BEGIN
  FOREACH t IN ARRAY ARRAY[
    'espn_athlete_brand', 'athlete_pages', 'athlete_external_ids', 'athlete_wikipedia',
    'deal_price_train', 'deal_price_train_state', 'deal_price_adjust',
    'zone_price_observations'
  ] LOOP
    EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', t);
    EXECUTE format('REVOKE ALL ON public.%I FROM PUBLIC, anon, authenticated', t);
  END LOOP;
END $$;

-- Post-apply checks (expect 0 rows each):
--   SELECT relname FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
--   WHERE n.nspname='public' AND relname IN ('unified_orders','v_n2s_orders',
--     'v_n2s_orders_live','v_sub_orders','v_gt_credit_health')
--     AND (has_table_privilege('anon',c.oid,'SELECT') OR has_table_privilege('authenticated',c.oid,'SELECT'));
--   SELECT relname FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
--   WHERE n.nspname='public' AND relkind='r' AND NOT relrowsecurity
--     AND (has_table_privilege('anon',c.oid,'SELECT') OR has_table_privilege('authenticated',c.oid,'SELECT'));
