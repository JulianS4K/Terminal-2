-- 20260520410000_compute_event_breakdowns_non_fatal.sql
--
-- Make compute_event_breakdowns non-fatal so a slow event no longer 502s
-- the collect-listings edge function.
--
-- ## Bug
--
-- The deployed collect-listings edge fn (v10) calls compute_event_breakdowns
-- AFTER it has already written listings_snapshots + event_metrics. On a
-- high-inventory event (e.g. Yankees home games — thousands of seats), the
-- breakdowns RPC exceeds the 8s statement_timeout that applies to the
-- `authenticator` role PostgREST connects as (service_role has no cap, but
-- ALTER ROLE timeouts are applied at login as authenticator, and SET ROLE
-- does not lift them). PostgREST cancels the statement → the edge fn's
-- `db.rpc(...)` returns an error → `writeBreakdowns` throws → the whole pull
-- returns HTTP 502 with `{event_id, error, log}`.
--
-- Because pricing (event_metrics) is committed by the edge fn BEFORE this
-- RPC, the 502 is a false failure: the storefront's pricing data is fine.
-- But it pollutes `runs.stats_errors`, pg_net response health, and the
-- Featured-pricing cron's monitoring (observed 2026-05-19 ~20:53 UTC: 42
-- such 502s vs 10 success in a 3-min window).
--
-- Diagnosis confirmed the slow path is compute_event_section_metrics: it
-- calls match_performer_zone() per row via LATERAL, then expands every
-- listing by generate_series(1, quantity) to compute quantity-weighted
-- percentiles. For a section with thousands of seats that intermediate
-- result is large. (zone_metrics + section_metrics are fresh for MOST
-- events — only heavy ones, under contention, blow the 8s budget.)
-- The base index idx_listings_event_time(event_id, captured_at DESC)
-- already exists, so this is NOT a missing-index problem.
--
-- ## Fix
--
-- Wrap the zone + section computations in sub-transactions with a self-imposed
-- statement_timeout BELOW the 8s authenticator ceiling. A slow event is then
-- caught HERE (graceful) instead of being killed by PostgREST. The function
-- returns a status jsonb the edge fn already treats as success (it only
-- throws on `error`, which we no longer produce). Validated 2026-05-19 that
-- catching a statement_timeout cancellation in a sub-block + resetting the
-- budget + continuing works on this Postgres.
--
-- Zone + section live in separate sub-blocks so a section timeout still keeps
-- any zone rows already written. The 7s total budget leaves ~1s under the 8s
-- ceiling for the EXCEPTION handling + RETURN serialization.
--
-- ## What this does NOT change
--
-- - The underlying compute_event_zone_metrics / compute_event_section_metrics
--   are untouched, so the isolated backfill cron (backfill_stale_zone_metrics,
--   currently disabled) can still call them DIRECTLY under its own 90s budget
--   to recompute breakdowns for heavy events out-of-band. Re-enabling +
--   extending that cron to also cover sections is a recommended follow-up
--   (separate, since cron schedule changes are operator-gated).
-- - Pricing freshness is unaffected — event_metrics is written by the edge fn
--   before this RPC is ever called.

CREATE OR REPLACE FUNCTION public.compute_event_breakdowns(p_event_id bigint, p_captured_at timestamptz)
RETURNS jsonb
LANGUAGE plpgsql
AS $fn$
DECLARE
  v_zones      integer := 0;
  v_sections   integer := 0;
  v_zone_ok    boolean := true;
  v_section_ok boolean := true;
BEGIN
  -- Zone step. Self-capped under the 8s authenticator ceiling so a slow
  -- event is caught here, not killed by PostgREST.
  BEGIN
    SET LOCAL statement_timeout = '7000ms';
    v_zones := public.compute_event_zone_metrics(p_event_id, p_captured_at);
  EXCEPTION WHEN OTHERS THEN
    v_zone_ok := false;
    RAISE NOTICE 'compute_event_breakdowns: zone soft-fail event %: %', p_event_id, SQLERRM;
  END;

  -- Section step (the heavy one). Shares the 7s total budget measured from
  -- RPC start; a timeout here keeps whatever zone rows already landed.
  BEGIN
    SET LOCAL statement_timeout = '7000ms';
    v_sections := public.compute_event_section_metrics(p_event_id, p_captured_at);
  EXCEPTION WHEN OTHERS THEN
    v_section_ok := false;
    RAISE NOTICE 'compute_event_breakdowns: section soft-fail event %: %', p_event_id, SQLERRM;
  END;

  -- Restore a normal budget so the trailing RETURN isn't re-cancelled.
  SET LOCAL statement_timeout = '8s';

  RETURN jsonb_build_object(
    'zones_written',    v_zones,
    'sections_written', v_sections,
    'zone_ok',          v_zone_ok,
    'section_ok',       v_section_ok
  );
END
$fn$;

COMMENT ON FUNCTION public.compute_event_breakdowns(bigint, timestamptz) IS
  'Computes zone + section metrics for one event snapshot. Non-fatal: '
  'self-caps at 7s (under the 8s authenticator/PostgREST ceiling) and soft-'
  'fails a slow step rather than erroring, so collect-listings no longer '
  '502s on heavy events after pricing has already persisted. Returns '
  'zones_written/sections_written + zone_ok/section_ok status flags. '
  'For out-of-band recompute of heavy events, call compute_event_zone_metrics '
  '/ compute_event_section_metrics directly (e.g. backfill_stale_zone_metrics) '
  'where a longer budget is available.';

-- ============================================================
-- Post-apply verification
-- ============================================================
-- 1. Definition updated:
--    SELECT pg_get_functiondef('public.compute_event_breakdowns'::regproc);
--
-- 2. Heavy event no longer errors — call directly under an 8s cap and
--    confirm it RETURNS a jsonb status (zone_ok/section_ok may be false)
--    instead of raising:
--      SET statement_timeout = '8s';
--      SELECT public.compute_event_breakdowns(
--        3091452, (SELECT max(captured_at) FROM listings_snapshots WHERE event_id = 3091452));
--    -- expect a jsonb row, NOT "canceling statement due to statement timeout"
--
-- 3. After next Featured-pricing cron firing, confirm the 502 rate drops:
--      SELECT status_code, count(*) FROM net._http_response
--      WHERE created > now() - interval '15 minutes'
--      GROUP BY 1 ORDER BY 1;
--    -- expect far fewer 502s; the prior compute_event_breakdowns 502s gone.
