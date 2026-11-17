-- Migration 20261028223000 · level:secondary-sales · lane:D7 · writes:grants · reads:none · pre:20261028220000
--
-- Lock the auto-buy dry-run capture functions to service_role.
--
-- They are SECURITY DEFINER and take the caps and gates as parameters, and
-- Supabase's default privileges had granted EXECUTE to `authenticated`. Any
-- signed-in user could therefore call them over PostgREST with their own caps
-- or gates ('{1,2,3,4,5,6}') and write would_buy rows into the dry-run log —
-- the log a live buyer would one day act on. Flagged by the commit security
-- review on 20261028220000.
--
-- Nothing calls them over the API (grep: no callers outside SQL); they run
-- from the statement trigger on n2s_cover_queue, which cron writes as the
-- table owner, so revoking client roles does not affect the dry run.
--
-- rollback: GRANT EXECUTE ON FUNCTION … TO authenticated (not recommended).

REVOKE EXECUTE ON FUNCTION public.n2s_gt_order_dryrun_capture(numeric, numeric, integer[]) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.n2s_evo_order_dryrun_capture(numeric, numeric, integer[]) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.n2s_gt_order_dryrun_trg() FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.n2s_gt_order_dryrun_capture(numeric, numeric, integer[]) TO service_role;
GRANT EXECUTE ON FUNCTION public.n2s_evo_order_dryrun_capture(numeric, numeric, integer[]) TO service_role;
GRANT EXECUTE ON FUNCTION public.n2s_gt_order_dryrun_trg() TO service_role;
