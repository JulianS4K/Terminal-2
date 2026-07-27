-- Migration 20260515130000 · level:admin · lane:Audit/Push · writes:ALTER FUNCTION search_path on 3 functions · reads:- · pre:20260514181000
-- Fix PR #95 search_path sweep regression.
--
-- The function_search_path_mutable advisor sweep (PR #95,
-- 20260514181000_fn_search_path_sweep) added `SET search_path = public,
-- pg_temp` to 215 functions. That set is correct for the security-lint
-- objective (no mutable search_path → no privilege escalation via
-- unqualified call resolution), but it inadvertently removed access to
-- the `extensions` schema where pgcrypto's `hmac()`, `digest()`, etc.
-- live in default Supabase setup.
--
-- Three functions depend on pgcrypto and broke silently when PR #95
-- applied (~17:30 UTC 2026-05-14):
--   • public.tevo_sign_get(p_path, p_query, p_secret) — calls hmac() for
--     TEvo HMAC-SHA256 signing. evo_orders_queue_30min (jobid 61) has
--     been failing every 30 min since.
--   • public.sg_seller_process() — calls digest() for content-hash
--     dedup. sg_seller_process_30min (jobid 65) failing similarly.
--   • public.sg_listings_process() — same digest() use; on a less
--     visible cadence but equally broken.
--
-- Fix: extend each function's search_path to include `extensions`. This
-- preserves PR #95's privilege-escalation hardening (caller can't inject
-- a malicious search-path object) while restoring access to pgcrypto.
-- Pattern matches `seatdata_integration` and other migrations that
-- already do `SET search_path = public, extensions, pg_temp` explicitly.
--
-- ## Already applied to prod
-- Applied via MCP at 2026-05-14 (this session). Idempotent.

ALTER FUNCTION public.tevo_sign_get(p_path text, p_query text, p_secret text)
  SET search_path = public, extensions, pg_temp;

ALTER FUNCTION public.sg_listings_process()
  SET search_path = public, extensions, pg_temp;

ALTER FUNCTION public.sg_seller_process()
  SET search_path = public, extensions, pg_temp;
