-- Lane: B1 (git/code security) · cross-lane: A1 functions, operator-directed fix (Julian, 2026-11-04)
-- Touches: W pg_proc ACLs of public.aq_reschedule_sync_from_tevo(), public.td_gt_tm_enroll_from_match()
-- Already applied to prod · via MCP 2026-11-04 (verified: authenticated/anon EXECUTE false, service_role/postgres true)
--          R none
-- Pre-reqs: 20260705171533_aq_reschedule_sync_event_date_from_tevo, 20260709221500_a1_td_enroll_tm_non_sg_events
--
-- Both are SECURITY DEFINER and were EXECUTE-able by `authenticated`. Their guard
-- `current_user NOT IN ('service_role','postgres','supabase_admin')` is a no-op inside a
-- SECURITY DEFINER body (current_user is the owner, postgres), so any signed-in user could
-- run them. Their only callers are cron jobs (run as postgres), so revoking the client
-- grants changes nothing for the crons.
REVOKE EXECUTE ON FUNCTION public.aq_reschedule_sync_from_tevo() FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.td_gt_tm_enroll_from_match()  FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.aq_reschedule_sync_from_tevo() TO service_role;
GRANT  EXECUTE ON FUNCTION public.td_gt_tm_enroll_from_match()  TO service_role;
