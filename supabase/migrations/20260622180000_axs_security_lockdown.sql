-- ============================================================================
-- Migration 20260622180000 — AXS pipeline security lockdown
--
-- Lane:     A1 (DB-layer security — RLS / SECDEF / RULE-2; CLAUDE.md §2.8 rule 5)
-- Touches:  6 SECDEF AXS mutators        (REVOKE anon/auth EXECUTE + GRANT service_role)
--           14 SECURITY-INVOKER helpers  (pin search_path — clears function_search_path_mutable)
--           internal AXS/TD/price views  (security_invoker=true + REVOKE anon/auth SELECT)
--           mv_event_price_vol matview    (REVOKE anon/auth SELECT — matviews skip the view sweep)
--           7 AXS base tables             (REVOKE anon/auth SELECT — RLS already denies; clears the latent grant)
-- Pre-reqs: none (pure GRANT/REVOKE/ALTER on existing objects; no data change, no DDL on columns)
--
-- WHY (2026-06-22 comprehensive audit / live Supabase advisors):
--   The AXS ingest batch (mig 20260609xx/20260610xx) shipped without the
--   security convention codified in 20260515300000_security_secdef_post_pr101_
--   compliance.sql, reintroducing the exact classes prior sweeps had closed:
--     • 6 SECURITY DEFINER ingest/mutation fns were anon + authenticated
--       EXECUTE-able — the publishable/anon key could invoke ingest/backfill.
--       (They already pin search_path; the missing half is the grant lockdown.)
--     • The v_axs_* / v_td_* / v_event_price_vol views were SECURITY DEFINER
--       (run as owner, RLS-bypass) and anon/authenticated SELECT-able → broker
--       intel leak. Convention is security_invoker=true (per 20260519270000_c1_
--       security_invoker_views_phase_a.sql) + revoke the anon surface.
--     • 7 AXS base tables have RLS ENABLED but 0 policies AND still carry the
--       Supabase default anon/authenticated grant. RLS-on/no-policy already
--       denies anon/auth (they read 0 rows), so revoking the latent grant is a
--       behavior-preserving cleanup that clears the rls_enabled_no_policy /
--       grant advisor. The app reads AXS via service_role (routers/axs.py,
--       server-side) which bypasses RLS — unaffected.
--
-- DELIBERATELY EXCLUDED (NOT a blind flip — owner review):
--   • exos_public_orgs / exos_public_events / exos_public_tiers — these are the
--     INTENTIONAL anon-facing public read boundary for the D4/Exos storefront.
--     Flipping them to security_invoker without a matching anon-SELECT RLS
--     policy on the underlying exos_* tables would return 0 rows to the public
--     site. D4 owns the correct fix (invoker + a published-row anon policy);
--     filed for D4, not changed here.
--   • Cron schedule changes, vault, auth.* — out of scope.
--
-- APPLY: operator/A1-gated per CLAUDE.md §1 (authored only). Post-apply verify:
--   get_advisors(security) AXS items clear; routers/axs.py reads still return
--   data (service_role path); terminal AXS panels render.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. SECDEF AXS mutators — lock EXECUTE to service_role (the CRITICAL fix).
--    These are cron/service_role-only ingest & backfill functions; no anon or
--    authenticated caller is legitimate. Mirrors 20260515300000.
-- ---------------------------------------------------------------------------
DO $lock$
DECLARE
  fn text;
  sigs text[] := ARRAY[
    'public.axs_apply_aq(text)',
    'public.axs_aq_backfill(integer)',
    'public.axs_ingest_performer_events(bigint)',
    'public.axs_ingest_snapshot(bigint, text)',
    'public.axs_probe_step(integer, integer, integer)',
    'public.axs_refresh_performers()'
  ];
BEGIN
  FOREACH fn IN ARRAY sigs LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC, anon, authenticated;', fn);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO service_role;', fn);
  END LOOP;
END
$lock$;

-- ---------------------------------------------------------------------------
-- 2. SECURITY-INVOKER helpers without a pinned search_path — pin it.
--    Lower risk than #1 (they run as the caller, not the owner), but an
--    unpinned search_path is the function_search_path_mutable advisor. Pinning
--    to the same superset the AXS SECDEF fns use is behavior-neutral for these
--    pure text/number helpers.
-- ---------------------------------------------------------------------------
DO $sp$
DECLARE
  fn text;
  sigs text[] := ARRAY[
    'public._digest_cell(numeric, numeric, text, integer)',
    'public._wl_require_email()',
    'public.alert_operator_needs_threshold(text)',
    'public.aq_name_consistent(text, text)',
    'public.axs_artist_url(text)',
    'public.axs_build_event_url(text, text)',
    'public.axs_search_events(text)',
    'public.axs_slugify(text)',
    'public.get_axs_event_price_series(bigint, timestamptz)',
    'public.price_dte_bucket(integer)',
    'public.safe_jsonb(text)',
    'public.td_event_tier(integer)',
    'public.td_is_peak(text, timestamptz)',
    'public.venue_norm(text)'
  ];
BEGIN
  FOREACH fn IN ARRAY sigs LOOP
    EXECUTE format('ALTER FUNCTION %s SET search_path = public, extensions, pg_temp;', fn);
  END LOOP;
END
$sp$;

-- ---------------------------------------------------------------------------
-- 3. Internal broker/AXS/TD/price views — security_invoker=true + revoke the
--    anon/authenticated read surface. The app reads these via service_role
--    (server-side), which bypasses RLS regardless of invoker; browsers never
--    read internal views directly (the *_public RPC whitelist is the consumer
--    boundary, PROJECT_BIBLE §2.6). exos_public_* intentionally EXCLUDED (see header).
-- ---------------------------------------------------------------------------
DO $views$
DECLARE
  v text;
  vs text[] := ARRAY[
    'public.v_axs_listings',
    'public.v_axs_events_classified',
    'public.v_axs_seat_groups',
    'public.v_axs_venues_mapped',
    'public.v_axs_venues_unmapped',
    'public.v_td_unmatched_discovered_events',
    'public.v_td_poll_failures_recent',
    'public.v_event_price_vol',
    'public.v_espn_live_result_price_impact'
  ];
BEGIN
  FOREACH v IN ARRAY vs LOOP
    EXECUTE format('ALTER VIEW %s SET (security_invoker = true);', v);
    EXECUTE format('REVOKE ALL ON %s FROM anon, authenticated;', v);
  END LOOP;
END
$views$;

-- 3b. The two analyst "recent" firehose views: revoke the anon/authenticated
--     read surface only. NOT flipped to security_invoker here — they are
--     consumed by the dedicated `analyst_ro` role (mig 20260619210000) and by
--     service_role; both are trusted, and revoking anon/auth fully neutralizes
--     the anon-exposure the security_definer_view advisor flags.
REVOKE ALL ON public.listings_snapshots_recent          FROM anon, authenticated;
REVOKE ALL ON public.seatgeek_listings_snapshots_recent FROM anon, authenticated;

-- ---------------------------------------------------------------------------
-- 4. Matview — the standard view sweep can't reach materialized views.
--    mv_event_price_vol carries internal price-vol intel; revoke anon/auth.
-- ---------------------------------------------------------------------------
REVOKE ALL ON public.mv_event_price_vol FROM anon, authenticated;

-- ---------------------------------------------------------------------------
-- 5. AXS base tables — revoke the latent default anon/authenticated grant.
--    RLS is already ENABLED with 0 policies, so anon/authenticated already read
--    0 rows; this removes the dangling grant (rls_enabled_no_policy advisor) and
--    leaves service_role (which bypasses RLS) as the sole reader — matching how
--    routers/axs.py actually reads the AXS surface. axs_probe already locked by
--    20260622170000.
-- ---------------------------------------------------------------------------
DO $tbls$
DECLARE
  t text;
  ts text[] := ARRAY[
    'public.axs_events',
    'public.axs_event_snapshots',
    'public.axs_seat_snapshots',
    'public.axs_section_snapshots',
    'public.axs_venues',
    'public.axs_performers',
    'public.axs_event_requests'
  ];
BEGIN
  FOREACH t IN ARRAY ts LOOP
    EXECUTE format('REVOKE ALL ON %s FROM anon, authenticated;', t);
  END LOOP;
END
$tbls$;
