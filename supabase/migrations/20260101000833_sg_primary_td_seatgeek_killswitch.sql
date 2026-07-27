-- ============================================================================
-- MIG 20260606120000 — Hard-wire SeatGeek to its PRIMARY API; kill TD-seatgeek
--
-- Operator directive (2026-06-06): "turn off SG via the TicketsData platform,
-- use SeatGeek's primary [API], hard-wire the TD turn-off unless emergency."
--
-- Findings that motivated this (read-only audit, 2026-06-06):
--   • The entire live SG pipeline ALREADY runs on SeatGeek primary:
--       - sg_listings_poll_tick  → https://brokerdata.seatgeek.com/listings
--       - sg_sales_poll_tick     → https://brokerdata.seatgeek.com/sales
--       - auto_match_sg_canonical_v3 / sg_seller_process → no TicketsData use
--   • TicketsData was NEVER the live SG listings source. The only TD-seatgeek
--     calls that ever existed were ad-hoc /events *searches* (a one-off event
--     match on 2026-05-29, source tag 'td_seatgeek_search', and a manual probe).
--   • td_api_platform() currently returns 'sg' for SG via the ELSE LOWER()
--     fallback — i.e. nothing stops a future caller from building a
--     ticketsdata.com?platform=seatgeek URL.
--
-- This migration makes the policy enforceable rather than implicit:
--   1. integration_policy flag table + a single 'td_seatgeek_emergency_override'
--      row, default DISABLED.
--   2. td_seatgeek_allowed() — the guard; false unless the override is flipped.
--   3. td_api_platform() — hard-blocks SG/seatgeek (RAISE) unless the override
--      is on, so the central TD URL-builder can never emit a seatgeek platform
--      string by accident. SH/VD/GT/TM/TP mappings unchanged.
--
-- Emergency re-enable (and REVERT after):
--   UPDATE public.integration_policy
--     SET enabled = true, reason = '<incident ref>', updated_by = '<bot/op>',
--         updated_at = now()
--   WHERE key = 'td_seatgeek_emergency_override';
--
-- NOTE: this guards the TD URL-builder path. A raw net.http_get to
-- ticketsdata.com with platform=seatgeek still bypasses SQL (no DB-level
-- intercept exists for arbitrary pg_net calls) — that path is covered by the
-- written policy: any TD-seatgeek call MUST check td_seatgeek_allowed() first.
-- ============================================================================

BEGIN;

-- 1) Policy flag table (generic; first use is the TD-seatgeek kill switch).
CREATE TABLE IF NOT EXISTS public.integration_policy (
  key        text PRIMARY KEY,
  enabled    boolean     NOT NULL DEFAULT false,
  reason     text,
  updated_by text,
  updated_at timestamptz NOT NULL DEFAULT now()
);
REVOKE ALL ON public.integration_policy FROM anon, authenticated;
ALTER TABLE public.integration_policy ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS integration_policy_service_only ON public.integration_policy;
CREATE POLICY integration_policy_service_only ON public.integration_policy
  FOR ALL TO service_role USING (true) WITH CHECK (true);

INSERT INTO public.integration_policy (key, enabled, reason, updated_by)
VALUES (
  'td_seatgeek_emergency_override',
  false,
  'SeatGeek is sourced from its PRIMARY API (brokerdata.seatgeek.com). Routing '
  'SeatGeek through TicketsData is hard-disabled. Set enabled=true ONLY for an '
  'emergency, record an incident ref in this column, then revert to false.',
  'A1 mig 20260606120000'
)
ON CONFLICT (key) DO NOTHING;

-- 2) The guard. false unless the override is explicitly on.
CREATE OR REPLACE FUNCTION public.td_seatgeek_allowed()
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
  SELECT COALESCE(
    (SELECT enabled FROM public.integration_policy
      WHERE key = 'td_seatgeek_emergency_override'),
    false);
$$;
REVOKE ALL ON FUNCTION public.td_seatgeek_allowed() FROM anon, PUBLIC;
COMMENT ON FUNCTION public.td_seatgeek_allowed() IS
  'Guard for the hard-disabled TicketsData-seatgeek path. Returns false unless '
  'integration_policy.td_seatgeek_emergency_override is flipped on for an '
  'emergency. SeatGeek must otherwise be sourced from brokerdata.seatgeek.com.';

-- 3) Hard-block SG/seatgeek in the central TD platform-string mapper.
--    (Was LANGUAGE sql IMMUTABLE — now plpgsql STABLE because it reads the
--     guard. td_api_platform is only used inside function bodies to build URLs,
--     never in an index/generated column, so the volatility change is safe.)
CREATE OR REPLACE FUNCTION public.td_api_platform(p_code text)
RETURNS text
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
  IF lower(p_code) IN ('sg', 'seatgeek') AND NOT public.td_seatgeek_allowed() THEN
    RAISE EXCEPTION 'TD-seatgeek is hard-disabled: source SeatGeek from its primary API (brokerdata.seatgeek.com). To override for an emergency, set integration_policy.td_seatgeek_emergency_override = true.';
  END IF;
  RETURN CASE p_code
    WHEN 'SH' THEN 'stubhub'
    WHEN 'VD' THEN 'vividseats'
    WHEN 'GT' THEN 'gametime'
    WHEN 'TM' THEN 'ticketmaster'
    WHEN 'TP' THEN 'tickpick'
    WHEN 'SG' THEN 'seatgeek'   -- only reachable when the emergency override is on
    ELSE LOWER(p_code)
  END;
END;
$function$;
REVOKE ALL ON FUNCTION public.td_api_platform(text) FROM anon, PUBLIC;
COMMENT ON FUNCTION public.td_api_platform(text) IS
  'Maps internal platform code → TicketsData API platform string. SG/seatgeek '
  'is hard-blocked (RAISE) unless td_seatgeek_allowed() — SeatGeek is sourced '
  'from its primary API, not TicketsData. See mig 20260606120000.';

COMMIT;
