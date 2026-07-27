-- ============================================================
-- SECURITY P2b — pin mutable search_path on aq_name_consistent (2026-06-01).
-- Surfaced by the post-fix advisor re-run (lint 0011_function_search_path_mutable),
-- same class as compute_event_breakdowns in sec_p2. Non-SECDEF helper; hardening only.
-- ============================================================
ALTER FUNCTION public.aq_name_consistent(p_tevo text, p_aq text) SET search_path = public, pg_temp;
