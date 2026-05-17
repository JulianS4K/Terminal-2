-- Close B1 #275 (SEC-MED defense-in-depth) — security_invoker on D2's 2 views.
--
-- PR #166 (D2-authored, A1-applied today) shipped v_sg_broker_sales_by_event
-- + v_sg_broker_sales_by_section without security_invoker=true. Default view
-- semantics on Postgres run as the view CREATOR (SECDEF), bypassing RLS on
-- underlying tables.
--
-- Not currently exploitable: both views REVOKE from PUBLIC/anon/authenticated
-- and only GRANT SELECT to service_role. But:
--   - PROJECT_BIBLE.md §3 lists security_invoker=true as the canonical pattern
--   - release_health_check.views.security_definer_views WARN=2 flagged the drift
--   - If a future PR widens grants, the SECDEF semantics would bypass
--     seatgeek_sales_snapshots RLS (table has 1 policy)
--
-- 2-line fix per B1's recommended patch.
-- Post-apply verified: both reloptions = {security_invoker=true}.

ALTER VIEW public.v_sg_broker_sales_by_event SET (security_invoker = true);
ALTER VIEW public.v_sg_broker_sales_by_section SET (security_invoker = true);
