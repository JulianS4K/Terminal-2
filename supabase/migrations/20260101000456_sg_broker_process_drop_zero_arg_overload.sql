-- ============================================================================
-- Hotfix for mig 20260517160000 (sg_broker_process_bounded_drain).
--
-- Symptom: after applying the bounded-drain migration, both
-- sg_priority_listings_process_1min and sg_priority_sales_process_1min
-- started failing every 1-min fire with:
--
--   ERROR: function public.sg_broker_sales_process() is not unique
--   HINT: Could not choose a best candidate function.
--
-- Cause: CREATE OR REPLACE FUNCTION only replaces a function whose signature
-- matches the existing one. Mig 20260517160000 added a `p_limit int DEFAULT 50`
-- parameter, which Postgres treats as a NEW overload (signature differs).
-- The cron command `SELECT public.sg_broker_{listings,sales}_process()` then
-- resolved ambiguously — could match the old 0-arg variant OR the new
-- 1-arg-with-default variant.
--
-- Fix: drop the legacy 0-arg overloads so the cron's no-arg call
-- unambiguously resolves to the new function via the DEFAULT.
--
-- Same class of bug A1 saw in bot_chat 258 / migration 20260516260000
-- (match_to_aq_event_id 7-arg drop). When changing function signatures with
-- defaults, always DROP the old variant explicitly.
-- ============================================================================

DROP FUNCTION IF EXISTS public.sg_broker_listings_process();
DROP FUNCTION IF EXISTS public.sg_broker_sales_process();
