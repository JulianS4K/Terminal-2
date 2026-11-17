-- Migration 20260927023400 · level:secondary-sales · lane:D7 · writes:n2s_timer_open · reads:none · pre:20260927020000
--
-- Already applied to prod · via MCP 2026-09-27 02:34 UTC under operator direction
-- ("Gate timer at 10 mins, since we need to do additional things within the 15
-- mins like accept order and buy tickets"), after a rolled-back dry run of six
-- cases (9 min open / 11 min closed / no-alert ±5 min / CRM-expired / no data).
--
-- ============================================================================
-- Work an order for the first 10 minutes after its alert (else until 5 min
-- before timer_expires_at). The CRM gives 15; the last 5 are kept for
-- accepting the order and buying the tickets.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.n2s_timer_open(
  p_expires_at timestamptz, p_expired boolean, p_alert_at timestamptz)
 RETURNS boolean
 LANGUAGE sql
 STABLE
 SET search_path TO 'pg_catalog'
AS $f$
  SELECT NOT COALESCE(p_expired, false)
     AND COALESCE(p_alert_at + interval '10 minutes',
                  p_expires_at - interval '5 minutes',
                  'infinity'::timestamptz) > now();
$f$;
COMMENT ON FUNCTION public.n2s_timer_open(timestamptz, boolean, timestamptz) IS
  'True for the first 10 minutes after an N2S alert (else until 5 min before timer_expires_at): the CRM gives 15, and the last 5 are kept for accepting the order and buying the tickets. Gates polling, cover search, the panel view and the external feed.';

-- rollback: the 15-minute body from 20260927020000.
