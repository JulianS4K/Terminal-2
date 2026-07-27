-- ============================================================================
-- Migration 20260520230000 · level:security · lane:Security
-- writes: EXECUTE grants on 16 SECDEF fns + table grant/RLS on
--         tevo_blindspot_discovery_attempts
-- reads:  pg_proc, pg_class (audit only)
-- pre:    none (idempotent REVOKE/GRANT/ENABLE RLS)
--
-- B1 audit 2026-05-20 (operator "audit and fix", triggered by the Exos RLS
-- review which surfaced the Supabase default-grant gotcha). Swept the whole
-- public schema for the same class: Supabase auto-GRANTs every new public
-- table to anon+authenticated and every new function EXECUTE to PUBLIC. Any
-- object that never explicitly REVOKEd inherits an internet-facing surface.
--
-- FINDINGS CLOSED HERE
-- -------------------------------------------------------------------------
-- SEC-HIGH (2) — anon-EXECUTE SECDEF fns that drive PAID external work on
--   demand (anon + public anon key -> /rest/v1/rpc/... -> cost amplification):
--     * tevo_blindspot_discovery_enqueue()      -> tevo-blindspot-discovery edge fn (TEvo /v9/events)
--     * collect_listings_featured_refresh(int)   -> collect-listings edge fn
-- SEC-MED (14) — anon-EXECUTE SECDEF write fns (matchers/backfills/ingest/
--   cron gate); all cron/service_role-driven, no legit anon caller. Closes
--   the anon-drivable-write surface (overlaps the B1-NEXT-29/30/31 §6 backlog,
--   but REVOKE is the load-bearing fix; the body-guard retrofit remains a
--   separate defense-in-depth follow-up).
-- SEC-MED (1 table) — tevo_blindspot_discovery_attempts: RLS was never enabled
--   and anon held SELECT/INSERT/UPDATE/DELETE/TRUNCATE. Internal cron telemetry
--   (no PII), but anon could wipe/poison it over PostgREST.
--
-- SAFE: every fn is invoked by crons / edge fns running as service_role (which
-- retains EXECUTE), and intra-DB callers run as their own SECDEF owner; no
-- anon/authenticated app path calls any of these. The table's writer
-- (tevo_blindspot_discovery_enqueue, SECDEF) runs as owner and bypasses RLS;
-- the edge-fn writeback uses the service-role key and bypasses RLS.
--
-- ## Regression risk
-- cron.failed_jobs_90min — none expected (service_role retains EXECUTE; cron
--   DO-blocks unchanged). functions still resolve by oid.
-- PostgREST anon/authenticated callers — intentionally lose access to these
--   16 RPCs + the table. Re-probe after apply: anon EXECUTE = denied.
--
-- ## Already applied to prod
-- NOT YET. Operator authorizes prod apply (2026-05-13 lockdown). A1-lane fns
-- ride along (REVOKE is identical + safe) — A1 has apply-time veto.
-- ============================================================================

-- --- SEC-HIGH: anon-executable SECDEF fns that drive paid external work ------
REVOKE EXECUTE ON FUNCTION public.tevo_blindspot_discovery_enqueue()              FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.tevo_blindspot_discovery_enqueue()              TO service_role;
REVOKE EXECUTE ON FUNCTION public.collect_listings_featured_refresh(integer)      FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.collect_listings_featured_refresh(integer)      TO service_role;

-- --- SEC-MED: anon-executable SECDEF write fns (cron/service_role driven) -----
REVOKE EXECUTE ON FUNCTION public.aq_event_map_ingest(jsonb)                                                          FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.aq_event_map_ingest(jsonb)                                                          TO service_role;
REVOKE EXECUTE ON FUNCTION public.auto_match_sg_canonical_v3()                                                        FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.auto_match_sg_canonical_v3()                                                        TO service_role;
REVOKE EXECUTE ON FUNCTION public.backfill_seatgeek_sales_tevo_event_id(integer)                                      FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.backfill_seatgeek_sales_tevo_event_id(integer)                                      TO service_role;
REVOKE EXECUTE ON FUNCTION public.create_system_aq_event(text, text, text, timestamp with time zone, bigint)          FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.create_system_aq_event(text, text, text, timestamp with time zone, bigint)          TO service_role;
REVOKE EXECUTE ON FUNCTION public.cron_should_fire(text)                                                              FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.cron_should_fire(text)                                                              TO service_role;
REVOKE EXECUTE ON FUNCTION public.listings_deltas_backfill_chunked(integer)                                          FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.listings_deltas_backfill_chunked(integer)                                          TO service_role;
REVOKE EXECUTE ON FUNCTION public.match_unmatched_listings_chunked(integer, boolean)                                  FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.match_unmatched_listings_chunked(integer, boolean)                                  TO service_role;
REVOKE EXECUTE ON FUNCTION public.match_unmatched_orders_sweep(integer, boolean)                                      FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.match_unmatched_orders_sweep(integer, boolean)                                      TO service_role;
REVOKE EXECUTE ON FUNCTION public.refresh_cross_source_venue_map()                                                    FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.refresh_cross_source_venue_map()                                                    TO service_role;
REVOKE EXECUTE ON FUNCTION public.refresh_sg_broker_listings_event_metrics(integer)                                   FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.refresh_sg_broker_listings_event_metrics(integer)                                   TO service_role;
REVOKE EXECUTE ON FUNCTION public.sg_attempt_event_xref_v3(bigint, text, date, timestamp with time zone, text, text, text, text) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.sg_attempt_event_xref_v3(bigint, text, date, timestamp with time zone, text, text, text, text) TO service_role;
REVOKE EXECUTE ON FUNCTION public.sg_canonical_link_from_tevo_chunked(integer)                                        FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.sg_canonical_link_from_tevo_chunked(integer)                                        TO service_role;
REVOKE EXECUTE ON FUNCTION public.sg_canonical_refresh_v2_pull(integer)                                               FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.sg_canonical_refresh_v2_pull(integer)                                               TO service_role;
REVOKE EXECUTE ON FUNCTION public.sg_classify_events()                                                                FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.sg_classify_events()                                                                TO service_role;

-- --- SEC-MED: table grant leak + RLS on tevo_blindspot_discovery_attempts -----
REVOKE ALL ON public.tevo_blindspot_discovery_attempts FROM anon, authenticated;
ALTER TABLE public.tevo_blindspot_discovery_attempts ENABLE ROW LEVEL SECURITY;
-- service_role + the SECDEF writer (owner) bypass RLS. Preserve ops read for the
-- read-only human role; no anon/authenticated policy = deny-by-default for them.
DROP POLICY IF EXISTS tevo_blindspot_attempts_ro ON public.tevo_blindspot_discovery_attempts;
CREATE POLICY tevo_blindspot_attempts_ro ON public.tevo_blindspot_discovery_attempts
  FOR SELECT TO coworker_readonly USING (true);
