-- ============================================================================
-- Migration 20260623190100 — security_definer_views: fix the check + flip/lock
--                            the views that are safe to act on
--
-- Lane:     A1 (DB security) — health-check fn is shared with B1; PR-reviewed.
-- Touches:  public.release_health_check() (W, CREATE OR REPLACE — views check only),
--           ALTER VIEW security_invoker on 6 views (W),
--           REVOKE anon/authenticated on 2 ops views (W).
-- Pre-reqs: 20260515170000 (release_health_check), 20260621180156 (last view flip).
-- Apply:    APPLIED to prod 2026-06-23 (operator-authorized). Verified:
--           security_definer_views 23(fail) -> 2(warn) = {unified_listings,
--           v_event_full_sports}; the 4 flips + 2 revoke/flip succeeded.
--           Behavioral-but-verified — see per-view evidence below; shared seams
--           still flagged for the C1 decision on the remaining 2.
--
-- ── PROBLEM ─────────────────────────────────────────────────────────────────
--   release_health_check() → views.security_definer_views = FAIL, metric 23.
--   Investigation (live prod, 2026-06-23) splits the 23 into THREE groups:
--
--   GROUP A — 12 FALSE POSITIVES (check bug). These views ARE invoker-secured
--     but store the option as `security_invoker=on` (PG's boolean spelling),
--     while the check matches the literal string 'security_invoker=true'. PG
--     accepts on/true/1/yes; the check only recognizes `true`. (The 5 views the
--     06-21 migration flipped with `= true` store as `=true` and pass; older
--     views set with `= on` store as `=on` and wrongly trip.) → fixed in PART 1.
--
--   GROUP B — 6 GENUINE definers that are SAFE to act on → PART 2/PART 3.
--     · 4 service_role-only (no anon/authenticated grant): flipping is a no-op
--       behaviorally (service_role bypasses RLS + has full grants):
--         listings_snapshots_recent, seatgeek_listings_snapshots_recent,
--         v_bot_chat_unresolved, v_event_listing_trends
--     · 2 ops-internal views wrongly granted to anon, with NO app/FE consumer
--       (grep of *.py/*.js/*.ts/*.html = docs only) and base tables that RLS-deny
--       anon: v_sg_token_budget (base sg_broker_pending USING false),
--       v_ticketsdata_credit_usage_daily (base ticketsdata_credit_usage =
--       service_role only). → REVOKE the unnecessary anon/authenticated grant,
--       THEN flip (only service_role remains → safe). Hardening + clears check.
--
--   GROUP C — 5 GENUINE definers that are INTENTIONAL public-read boundaries
--     (SECDEF by necessity — base tables RLS-deny anon, so they CANNOT be flipped
--     without breaking anon):
--       · exos_public_events / exos_public_orgs / exos_public_tiers — the D4
--         Bridge public storefront reads these with the ANON key
--         (d4_bridge/src/lib/{events,orgs}.ts, server.ts). Curated anon
--         projections of RLS-protected exos_* tables. → whitelisted in PART 1
--         (pattern exos_public_%) — same spirit as the existing pg_% exclusion.
--       · unified_listings, v_event_full_sports — anon-exposed curated cross-
--         source views; base tables (listings_snapshots, espn_news, ticketsdata_*)
--         RLS-deny / don't-grant anon, so flipping empties/errors them for anon.
--         NOT touched here: each needs an explicit A1/C1 decision —
--           (a) confirmed-intentional anon boundary → add to the PART-1 allowlist; OR
--           (b) unintended exposure (esp. unified_listings may surface ticketsdata
--               to anon — cf. PROJECT_BIBLE §2.6 broker/wholesale read boundary)
--               → REVOKE anon instead.
--         Left flagged on purpose so the decision is explicit, not silent.
--
--   NET after this migration: metric 23 (fail) → 2 (warn) = exactly
--   {unified_listings, v_event_full_sports}, the two views that need a human call.
-- ============================================================================

-- ── PART 1: fix the views check (recognize on/true/1/yes; whitelist exos_public_)
CREATE OR REPLACE FUNCTION public.release_health_check()
 RETURNS TABLE(check_class text, check_name text, status text, metric numeric, detail text)
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
  RETURN QUERY
  WITH agg AS (
    SELECT count(*)::int AS n,
           string_agg(j.jobname || ':' || coalesce(left(r.return_message,80),''), ' | ') AS msg
    FROM cron.job j JOIN cron.job_run_details r ON r.jobid = j.jobid
    WHERE r.start_time > now() - interval '90 minutes' AND r.status = 'failed'
  )
  SELECT 'cron'::text, 'failed_jobs_90min'::text,
         CASE WHEN n = 0 THEN 'ok' WHEN n <= 2 THEN 'warn' ELSE 'fail' END,
         n::numeric, msg FROM agg;

  RETURN QUERY
  WITH stuck AS (
    SELECT count(*)::int AS n, string_agg(jobname, ', ') AS msg
    FROM cron.job j
    WHERE j.active
      AND (
        j.schedule ~ '^\s*\d+\s+(seconds?|minutes?)\s*$'
        OR (
          split_part(j.schedule, ' ', 2) = '*'
          AND split_part(j.schedule, ' ', 3) = '*'
          AND split_part(j.schedule, ' ', 4) = '*'
          AND split_part(j.schedule, ' ', 5) = '*'
        )
      )
      AND NOT EXISTS (
        SELECT 1 FROM cron.job_run_details r
        WHERE r.jobid = j.jobid AND r.status = 'succeeded'
          AND r.start_time > now() - interval '90 minutes'
      )
  )
  SELECT 'cron'::text, 'subhourly_jobs_silent_90min'::text,
         CASE WHEN n = 0 THEN 'ok' WHEN n <= 3 THEN 'warn' ELSE 'fail' END,
         n::numeric, msg FROM stuck;

  RETURN QUERY
  WITH bad AS (
    SELECT count(*)::int AS n, string_agg(p.proname, ', ') AS msg
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.prokind = 'f'
      AND pg_get_functiondef(p.oid) ~* '\m(hmac|digest|gen_random_bytes|encrypt|decrypt)\s*\('
      AND NOT EXISTS (
        SELECT 1 FROM unnest(coalesce(p.proconfig, ARRAY[]::text[])) cfg
        WHERE cfg ILIKE 'search_path=%extensions%'
      )
  )
  SELECT 'functions'::text, 'pgcrypto_missing_extensions_searchpath'::text,
         CASE WHEN n = 0 THEN 'ok' ELSE 'fail' END,
         n::numeric, msg FROM bad;

  RETURN QUERY
  WITH bad AS (
    SELECT count(*)::int AS n, string_agg(c.relname, ', ' ORDER BY c.relname) AS msg
    FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public' AND c.relkind = 'v'
      -- FIX: recognize all PG boolean-true spellings, not just the literal 'true'.
      -- security_invoker may be stored as on/true/1/yes depending on how it was set.
      AND NOT EXISTS (
        SELECT 1 FROM unnest(coalesce(c.reloptions, ARRAY[]::text[])) opt
        WHERE split_part(opt, '=', 1) = 'security_invoker'
          AND lower(split_part(opt, '=', 2)) IN ('true','on','1','yes')
      )
      AND c.relname NOT LIKE 'pg_%'
      -- WHITELIST: deliberate anon public-read projections. SECDEF by necessity —
      -- the base exos_* tables RLS-deny anon, so these CANNOT be security_invoker
      -- without breaking the D4 Bridge public storefront (anon-key reads).
      AND c.relname NOT LIKE 'exos_public_%'
  )
  SELECT 'views'::text, 'security_definer_views'::text,
         CASE WHEN n = 0 THEN 'ok' WHEN n <= 3 THEN 'warn' ELSE 'fail' END,
         n::numeric, msg FROM bad;

  RETURN QUERY
  WITH nv AS (
    SELECT count(*)::int AS n, string_agg(conname, ', ' ORDER BY conname) AS msg
    FROM pg_constraint WHERE contype = 'f' AND NOT convalidated
  )
  SELECT 'fks'::text, 'not_valid_fks'::text,
         CASE WHEN n = 0 THEN 'ok' WHEN n <= 60 THEN 'warn' ELSE 'fail' END,
         n::numeric, msg FROM nv;

  RETURN QUERY
  SELECT x.check_class, x.check_name,
    CASE
      WHEN x.metric IS NULL          THEN 'warn'
      WHEN x.metric <  60            THEN 'ok'
      WHEN x.metric <  240           THEN 'warn'
      ELSE                                'fail'
    END,
    x.metric,
    CASE
      WHEN x.metric IS NULL THEN 'no rows yet'
      WHEN x.metric < 60    THEN 'fresh'
      WHEN x.metric < 240   THEN round(x.metric)::text || ' min stale'
      ELSE                       round(x.metric)::text || ' min stale - investigate'
    END
  FROM (VALUES
    ('data_freshness'::text, 'evo_orders_age_min'::text,
      (SELECT EXTRACT(epoch FROM (now() - max(pulled_at)))/60 FROM public.evo_orders)::numeric),
    ('data_freshness',       'listings_snapshots_age_min',
      (SELECT EXTRACT(epoch FROM (now() - max(captured_at)))/60 FROM public.listings_snapshots)),
    ('data_freshness',       'espn_event_snapshots_age_min',
      (SELECT EXTRACT(epoch FROM (now() - max(captured_at)))/60 FROM public.espn_event_snapshots)),
    ('data_freshness',       'vivid_orders_age_min',
      (SELECT EXTRACT(epoch FROM (now() - max(pulled_at)))/60 FROM public.vivid_orders))
  ) AS x(check_class, check_name, metric);

  RETURN QUERY
  WITH q AS (
    SELECT
      (SELECT count(*) FROM public.vivid_orders_pending     WHERE resolved_at IS NULL) AS vivid_pending,
      (SELECT count(*) FROM public.tickpick_orders_pending  WHERE resolved_at IS NULL) AS tickpick_pending
  )
  SELECT 'queues'::text, 'unresolved_pending_total'::text,
         CASE WHEN vivid_pending + tickpick_pending = 0 THEN 'ok'
              WHEN vivid_pending + tickpick_pending < 20 THEN 'warn' ELSE 'fail' END,
         (vivid_pending + tickpick_pending)::numeric,
         format('vivid=%s, tickpick=%s', vivid_pending, tickpick_pending)
  FROM q;

  RETURN;
END $function$;

-- ── PART 2: flip the 4 service_role-only genuine-definer views (safe — no
--    anon/authenticated consumer; service_role bypasses RLS).
ALTER VIEW public.listings_snapshots_recent          SET (security_invoker = true);
ALTER VIEW public.seatgeek_listings_snapshots_recent SET (security_invoker = true);
ALTER VIEW public.v_bot_chat_unresolved              SET (security_invoker = true);
ALTER VIEW public.v_event_listing_trends             SET (security_invoker = true);

-- ── PART 3: ops-internal views wrongly exposed to anon — revoke the unnecessary
--    grant (no app/FE consumer; verified via repo grep), then flip. Hardening.
REVOKE ALL ON public.v_sg_token_budget                FROM anon, authenticated;
REVOKE ALL ON public.v_ticketsdata_credit_usage_daily FROM anon, authenticated;
ALTER VIEW public.v_sg_token_budget                SET (security_invoker = true);
ALTER VIEW public.v_ticketsdata_credit_usage_daily SET (security_invoker = true);

-- ── VERIFICATION (run after apply) ──────────────────────────────────────────
--   SELECT status, metric, detail FROM public.release_health_check()
--    WHERE check_name = 'security_definer_views';
--   -- expect: status='warn', metric=2, detail='unified_listings, v_event_full_sports'
--
-- ── FOLLOW-UP (separate decision, A1/C1) ────────────────────────────────────
--   Decide unified_listings + v_event_full_sports: whitelist (confirmed anon
--   boundary) or REVOKE anon (unintended exposure). Resolving both → check = ok.
-- ============================================================================
