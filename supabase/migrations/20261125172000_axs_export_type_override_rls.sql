-- Migration 20261125172000 · level:security · lane:A1 (DB security) · writes:axs_export_type_override(RLS,grants,CHECK) · reads:none · pre:20261125170500
--
-- axs_export_type_override IS LOCKED DOWN LIKE ITS SIBLINGS.
-- Found by the automated security review on mig 20261125170500 and confirmed against prod: every other AXS
-- table (axs_export_event, axs_export_sync, axs_watch_config, axs_watch_venue, axs_watch_poll,
-- axs_watch_audit) has relrowsecurity = true with 0 policies and service_role as the only grantee. The new
-- override table was created without ENABLE ROW LEVEL SECURITY, making it the one outlier.
--
-- Exposure was limited rather than open: the table already had only service_role granted (no anon, no
-- authenticated, no PUBLIC), so PostgREST never exposed it. RLS-off with no policies is still the missing half
-- of the house pattern, and a later default-privilege change or an accidental GRANT would have had nothing
-- behind it. This closes that.
--
-- Also constrains forced_type. The table exists to relabel a venue's AXS-sold events as axs_primary; without a
-- CHECK it could relabel them as anything, and two objects filter on that value as inclusion
-- (v_axs_event_map, axs_market_fallback_match). Widening the set later is a deliberate ALTER, not a typo.
--
-- The BEFORE trigger function axs_export_type_force() is SECURITY DEFINER and owned by the table owner, which
-- is not subject to RLS, so enabling it does not affect the forcing path. Verified after apply.
--
-- rollback: ALTER TABLE public.axs_export_type_override DISABLE ROW LEVEL SECURITY;
--           ALTER TABLE public.axs_export_type_override DROP CONSTRAINT axs_export_type_override_forced_type_ck;

BEGIN;

ALTER TABLE public.axs_export_type_override ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public.axs_export_type_override FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.axs_export_type_override TO service_role;

ALTER TABLE public.axs_export_type_override
  DROP CONSTRAINT IF EXISTS axs_export_type_override_forced_type_ck;
ALTER TABLE public.axs_export_type_override
  ADD CONSTRAINT axs_export_type_override_forced_type_ck CHECK (forced_type IN ('axs_primary'));

COMMIT;
