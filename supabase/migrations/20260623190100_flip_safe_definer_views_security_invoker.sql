-- ============================================================================
-- Migration 20260623190100 — flip/lock the 6 safe SECURITY DEFINER views
--
-- Lane:     A1 (DB security). PR-reviewed.
-- Touches:  ALTER VIEW security_invoker on 6 views (W),
--           REVOKE anon/authenticated on 2 ops views (W).
-- Pre-reqs: 20260515170000 (release_health_check), 20260621180156 (last view flip).
-- Apply:    APPLIED to prod 2026-06-23 (operator-authorized). All 6 flips verified
--           live on 2026-07-02 (security_invoker=on for every view below).
--
-- ── git⇄prod reconciliation (why this file is flips-only) ────────────────────
--   The original 2026-06-23 apply also CREATE-OR-REPLACE'd release_health_check()
--   to (a) recognize all PG boolean spellings for security_invoker (on/true/1/yes)
--   and (b) whitelist the exos_public_% anon boundary. That full-function body has
--   since been superseded on prod — release_health_check has been re-issued live
--   (deadman checks, D0-gate coupling, source-freshness SLA) with NO migration
--   recording those later revisions. Merging the 6/23 snapshot would plant a STALE
--   release_health_check as the repo's newest definition (no merged migration
--   corrects it), i.e. introduce git⇄prod drift. So the function redefinition is
--   pruned here; only the durable, still-live DDL state (the view flips + REVOKEs)
--   is kept. Reconciling release_health_check itself to its live body is a separate
--   task (dump the live definition into a fresh migration).
--
-- ── WHAT REMAINS (all verified live 2026-07-02) ─────────────────────────────
--   6 genuine SECURITY DEFINER views that are safe to flip to security_invoker:
--     · 4 service_role-only (no anon/authenticated grant) — flip is a behavioral
--       no-op (service_role bypasses RLS + holds full grants), clears the check:
--         listings_snapshots_recent, seatgeek_listings_snapshots_recent,
--         v_bot_chat_unresolved, v_event_listing_trends
--     · 2 ops-internal views wrongly granted to anon with NO app/FE consumer
--       (repo grep = docs only) whose base tables RLS-deny anon anyway — REVOKE
--       the stray grant, THEN flip (only service_role remains → safe hardening):
--         v_sg_token_budget (base sg_broker_pending USING false),
--         v_ticketsdata_credit_usage_daily (base = service_role only)
-- ============================================================================

-- ── PART A: flip the 4 service_role-only genuine-definer views (safe — no
--    anon/authenticated consumer; service_role bypasses RLS).
ALTER VIEW public.listings_snapshots_recent          SET (security_invoker = true);
ALTER VIEW public.seatgeek_listings_snapshots_recent SET (security_invoker = true);
ALTER VIEW public.v_bot_chat_unresolved              SET (security_invoker = true);
ALTER VIEW public.v_event_listing_trends             SET (security_invoker = true);

-- ── PART B: ops-internal views wrongly exposed to anon — revoke the unnecessary
--    grant (no app/FE consumer; verified via repo grep), then flip. Hardening.
REVOKE ALL ON public.v_sg_token_budget                FROM anon, authenticated;
REVOKE ALL ON public.v_ticketsdata_credit_usage_daily FROM anon, authenticated;
ALTER VIEW public.v_sg_token_budget                SET (security_invoker = true);
ALTER VIEW public.v_ticketsdata_credit_usage_daily SET (security_invoker = true);

-- ── VERIFICATION (run after apply) ──────────────────────────────────────────
--   SELECT relname FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
--    WHERE n.nspname='public' AND c.relkind='v'
--      AND relname IN ('listings_snapshots_recent','seatgeek_listings_snapshots_recent',
--                      'v_bot_chat_unresolved','v_event_listing_trends',
--                      'v_sg_token_budget','v_ticketsdata_credit_usage_daily')
--      AND NOT EXISTS (SELECT 1 FROM unnest(c.reloptions) o
--                      WHERE split_part(o,'=',1)='security_invoker'
--                        AND lower(split_part(o,'=',2)) IN ('true','on','1','yes'));
--   -- expect: 0 rows (all six carry security_invoker).
-- ============================================================================
