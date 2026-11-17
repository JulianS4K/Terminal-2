-- Migration 20261117071000 · level:security · lane:A1 (data plane — DB security) · writes:cron_try_lock() grants · reads:none · pre:20261117070000
--
-- Operator 2026-11-17 ("corn lock"): cron_try_lock(text) — pg_try_advisory_xact_lock on
-- hashtext('cron_job:' || key) — is executable by PUBLIC, anon and authenticated, so anyone with
-- the public API key can call it over PostgREST. Within one request the lock is released at the
-- end of the transaction, so the risk is small, but nothing outside the database should take the
-- cron locks. Its callers on prod (checked 2026-11-17) are 19 pg_cron jobs, which run as postgres,
-- and four SECURITY DEFINER functions owned by postgres (cron_should_fire, n2s_pipeline_tick,
-- sub_finder_refresh, sub_finder_settle_pending), all executable by service_role only. None of
-- them needs anon or authenticated to hold EXECUTE. service_role keeps it.

BEGIN;
SET LOCAL lock_timeout = '10s';

REVOKE ALL ON FUNCTION public.cron_try_lock(text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.cron_try_lock(text) TO service_role;

COMMIT;

-- VERIFY: SELECT proacl FROM pg_proc WHERE oid = 'public.cron_try_lock(text)'::regprocedure;
--   → {postgres=X/postgres,service_role=X/postgres}; the next cron ticks keep succeeding.
-- ROLLBACK: GRANT EXECUTE ON FUNCTION public.cron_try_lock(text) TO PUBLIC;
