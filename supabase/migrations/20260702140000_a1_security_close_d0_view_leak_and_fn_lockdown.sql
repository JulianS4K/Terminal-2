-- ============================================================================
-- Migration 20260702140000 · level:security · lane:A1
-- writes: ALTER 14 d0_* views security_invoker=on; REVOKE EXECUTE on 11 fns +
--         GRANT service_role; ALTER search_path on 2 d0 fns; leads RLS policy;
--         check_chat_rate_limit atomicity + chat_rate_limits PK
-- reads:  none (DDL only)
-- pre:    none — idempotent + existence-guarded; authored from the 2026-07-02
--         SQL/crons/jobs audit (docs/archive/2026-07-02-sql-crons-jobs-audit.md):
--         AUD-01, AUD-03, AUD-30, AUD-31, AUD-33.
--
-- ⚠ NOT APPLIED to prod. Authored by the audit lane; A1 applies after review
--   (D-tier / authoring lanes have zero prod-mutation authority — CLAUDE.md §1).
--   Every statement is idempotent and guarded by to_regclass/to_regprocedure so
--   a re-apply is a no-op and a from-scratch replay skips objects that were
--   created out-of-band (AUD-03) and therefore do not exist in a clean DB.
--
-- ─────────────────────────────────────────────────────────────────────────────
-- WHY (each block maps to one confirmed, adversarially-verified finding):
--
-- AUD-01 (HIGH) — the internal d0_* views are SECURITY DEFINER (owner=postgres,
--   security_invoker unset). A read runs as postgres and BYPASSES base-table RLS,
--   so `anon` (the public publishable key in static/terminal/auth.js:19, no login)
--   reads the broker's sale lines + league revenue over PostgREST. Verified live:
--   SET ROLE anon → 805,785 sale lines + ~$170M revenue; direct d0_sales_fact
--   read = 0 rows (RLS default-deny). Same class as mig 20260525170000, whose
--   "Tier-3" follow-up named exactly this fix: security_invoker=true.
--   security_invoker=on makes each view evaluate the CALLER's RLS → anon and any
--   non-@s4kent `authenticated` (d4_bridge has open signup on this project) get 0
--   rows; the terminal's broker data path (get_broker_* SECURITY DEFINER RPCs,
--   run as postgres) is UNAFFECTED, and no repo code reads these views directly
--   (verified: zero references in routers/core/static/*). exos_public_* are the
--   reviewed intentional public boundary and are left untouched.
--
-- AUD-03 (HIGH) + AUD-30 (LOW) — 11 SECURITY DEFINER maintenance/analytics fns
--   are EXECUTE-able by anon+authenticated with no role guard; their bodies
--   DELETE/INSERT on core tables (d0_refresh_sales_fact rebuilds a 6-join over
--   13.2M sales rows). They are cron-driven only (verified: no route/frontend
--   caller), so REVOKE FROM PUBLIC,anon,authenticated + GRANT service_role closes
--   the unauthenticated DoS/priv-esc surface with no legitimate breakage
--   (postgres owner + service_role retain EXECUTE → cron + edge fns still work).
--   REVOKE FROM PUBLIC (not just anon) is required — REVOKE FROM anon leaves the
--   PUBLIC default grant intact (the AUD-30 gotcha on td_credits_this_cycle).
--   The two d0_refresh_* fns also get an explicit search_path (advisor
--   function_search_path_mutable). NOTE: those two + d0_sales_fact + the d0_*
--   views have NO creating migration in the repo (created via out-of-band prod
--   DDL) — codifying them as real CREATE migrations is a separate A1 task
--   (see PR body); this migration only hardens what already exists in prod.
--
-- AUD-31 (MED) — public.leads (name/email/phone PII) is readable by ANY
--   authenticated user via USING(true). Scope it to @s4kent staff, matching the
--   convention on every other sensitive table. (Empty today; d4_bridge open
--   signup on the same project makes the exploit principal producible.)
--
-- AUD-33 (MED) — check_chat_rate_limit is a check-then-insert TOCTOU race on a
--   PK-less table: under READ COMMITTED a synchronized burst from one IP all read
--   a sub-cap count and all insert, bypassing the 6/min cap on the anon-reachable
--   paid-LLM chat fn. Serialize per-IP with a transaction advisory lock; add a PK
--   (advisor no_primary_key). Signature, search_path, and grants are preserved.
-- ============================================================================

-- ── AUD-01: security_invoker on the internal d0_* views (close the anon leak) ──
DO $aud01$
DECLARE v text;
BEGIN
  FOREACH v IN ARRAY ARRAY[
    'd0_league_event_roles','d0_league_events','d0_league_performers',
    'd0_league_price_weighted','d0_league_summary','d0_league_visiting_teams',
    'd0_perf_by_source','d0_perf_home_away','d0_perf_price_stats',
    'd0_perf_price_weighted','d0_perf_sale_lines','d0_perf_sections',
    'd0_perf_top5_sections','d0_refresh_health'
  ] LOOP
    IF to_regclass('public.'||v) IS NOT NULL THEN
      EXECUTE format('ALTER VIEW public.%I SET (security_invoker = true)', v);
    END IF;
  END LOOP;
END $aud01$;

-- ── AUD-03 + AUD-30: lock down cron-only SECDEF maintenance/analytics fns ──
DO $aud03$
DECLARE s text;
BEGIN
  FOREACH s IN ARRAY ARRAY[
    'public.d0_refresh_sales_fact()',
    'public.d0_refresh_sales_fact_active(interval)',
    'public.refresh_concierge_events()',
    'public.refresh_entity_metrics_daily(date)',
    'public.refresh_event_last_seen_from_market(interval)',
    'public.refresh_event_movers_agg(integer)',
    'public.refresh_wc_price_daily(date, date)',
    'public.refresh_world_cup_2026()',
    'public.tag_evo_only_events()',
    'public.td_sg_discover_drain()',
    'public.td_credits_this_cycle()'   -- AUD-30
  ] LOOP
    IF to_regprocedure(s) IS NOT NULL THEN
      EXECUTE format('REVOKE EXECUTE ON FUNCTION %s FROM PUBLIC, anon, authenticated', s);
      EXECUTE format('GRANT  EXECUTE ON FUNCTION %s TO service_role', s);
    END IF;
  END LOOP;

  -- AUD-03: pin search_path on the two orphaned d0 fns (function_search_path_mutable)
  IF to_regprocedure('public.d0_refresh_sales_fact()') IS NOT NULL THEN
    ALTER FUNCTION public.d0_refresh_sales_fact() SET search_path = public, pg_temp;
  END IF;
  IF to_regprocedure('public.d0_refresh_sales_fact_active(interval)') IS NOT NULL THEN
    ALTER FUNCTION public.d0_refresh_sales_fact_active(interval) SET search_path = public, pg_temp;
  END IF;
END $aud03$;

-- ── AUD-31: restrict leads PII to @s4kent staff (was USING(true)) ──
DO $aud31$
BEGIN
  IF to_regclass('public.leads') IS NOT NULL THEN
    DROP POLICY IF EXISTS leads_authenticated_read ON public.leads;
    CREATE POLICY leads_authenticated_read ON public.leads
      FOR SELECT TO authenticated
      USING ( lower(coalesce(auth.email(), '')) LIKE '%@s4kent.com' );
  END IF;
END $aud31$;

-- ── AUD-33: check_chat_rate_limit atomicity + chat_rate_limits primary key ──
DO $aud33$
BEGIN
  IF to_regclass('public.chat_rate_limits') IS NOT NULL THEN
    ALTER TABLE public.chat_rate_limits ADD COLUMN IF NOT EXISTS id bigint GENERATED ALWAYS AS IDENTITY;
    IF NOT EXISTS (
      SELECT 1 FROM pg_constraint
      WHERE conrelid = 'public.chat_rate_limits'::regclass AND contype = 'p'
    ) THEN
      ALTER TABLE public.chat_rate_limits ADD PRIMARY KEY (id);
    END IF;
  END IF;
END $aud33$;

-- CREATE OR REPLACE preserves the existing signature, search_path, security type
-- (INVOKER) and ACL — only the body changes (adds the per-IP advisory lock).
CREATE OR REPLACE FUNCTION public.check_chat_rate_limit(
  p_ip text, p_window_sec integer DEFAULT 60, p_max_calls integer DEFAULT 10)
RETURNS boolean
LANGUAGE plpgsql
SET search_path TO 'public', 'pg_temp'
AS $fn$
declare
  v_count integer;
begin
  -- AUD-33: serialize per-IP so the count->insert is atomic. Was a check-then-
  -- insert TOCTOU race: under READ COMMITTED a synchronized burst from one IP all
  -- read a sub-cap count and all inserted, bypassing the paid-LLM rate cap.
  perform pg_advisory_xact_lock(hashtext('chat_rl:' || p_ip));

  -- prune old rows opportunistically (keep table small)
  delete from chat_rate_limits where ts < now() - interval '1 hour';

  -- count requests from this IP in the window
  select count(*) into v_count
  from chat_rate_limits
  where ip = p_ip and ts > now() - make_interval(secs => p_window_sec);

  if v_count >= p_max_calls then
    return false;
  end if;

  insert into chat_rate_limits (ip) values (p_ip);
  return true;
end;
$fn$;
