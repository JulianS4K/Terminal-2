-- Migration 20260628000000 · level:admin · lane:D0 · writes: · reads:zone_rules · pre:20260507000000_capture_derive_zone_fallback
--
-- derive_zone_fallback_batch() — resolve the system zone fallback for many
-- (section, row) pairs in ONE round-trip.
--
-- WHY: GET /api/broker/event/{id}/section-zones called the scalar
-- derive_zone_fallback() once per distinct (section, row) pair over PostgREST
-- — an N+1 of HTTP round-trips for the non-curated sections of an event
-- (heavy events have hundreds of distinct sections). This wrapper folds those
-- N calls into a single RPC; the per-pair logic is unchanged (it delegates to
-- the existing scalar function, so curated/keyword/digit-tier behaviour is
-- byte-identical).
--
-- SHAPE: input is a jsonb array of {"section": text, "row": text} objects;
-- output is one row per input element: (section, row, zone) where zone is the
-- scalar fallback (NULL when unmapped). Callers key the result by (section,
-- row) and treat a missing/NULL zone as "unmapped" — exactly as the scalar
-- loop did.
--
-- SAFE TO SHIP BEFORE APPLY: the application code (routers/broker.py) tries
-- this RPC and transparently degrades to the legacy per-pair scalar loop if it
-- is absent or errors, so behaviour is identical whether or not this migration
-- has been applied to prod.
--
-- SECURITY: SECURITY INVOKER (default), STABLE — same posture as the scalar
-- derive_zone_fallback() it wraps; reads only zone_rules. No REVOKE/GRANT
-- needed (not SECURITY DEFINER).
--
-- ROLLBACK: DROP FUNCTION derive_zone_fallback_batch(jsonb);

create or replace function derive_zone_fallback_batch(p_pairs jsonb)
returns table(section text, "row" text, zone text)
language sql
stable
as $func$
  select
    (e->>'section')                                            as section,
    (e->>'row')                                                as "row",
    derive_zone_fallback((e->>'section'), (e->>'row'))         as zone
  from jsonb_array_elements(coalesce(p_pairs, '[]'::jsonb)) as e
$func$;
