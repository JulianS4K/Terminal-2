-- 20260620010000_get_discovery_gaps.sql
--
-- New read RPC: get_discovery_gaps(p_gap_type, p_limit) — powers the terminal
-- Discovery page "DISCOVERY GAPS — CROSS-PLATFORM ALERTS" panel.
--
-- WHY: discovery.js read discovery_gap_alerts DIRECTLY via the Supabase client
-- (.from('discovery_gap_alerts')). But that table has RLS enabled with ZERO
-- policies and no SELECT grant to `authenticated`, so the terminal client's read
-- fails with "permission denied for table discovery_gap_alerts" — the panel has
-- been showing an error/empty even though the feed is healthy (verified prod
-- 2026-06-20: 2,808 active gaps, last detected 2026-06-19 09:00 UTC). The same
-- ungranted direct read also silently kills the gap-chip enrichment on the Home
-- movers table (home.js loadGapMap, which swallows the error).
--
-- A SECURITY DEFINER RPC is the correct read path — it matches the other three
-- Discovery panels (get_blind_spots_tevo_selling / get_sg_blindspot_evo_tracking
-- / get_returning_entities, all granted to authenticated) and keeps the read
-- curated rather than opening direct table access on an A1-owned table.
--
-- The RPC also enriches each gap with the event name + date server-side (SG
-- canonical first, TEvo events fallback for evo_no_sg gaps that have no SG row),
-- collapsing the FE's prior 3 round-trips (gaps + sg_events_canonical + events)
-- into one. LATERAL LIMIT 1 on the SG join guards against AQ-map duplicate
-- tevo_event_id fan-out (PROJECT_BIBLE §0).
--
-- Lane: authored by D0 (terminal FE owner of the consuming panel); prod apply is
-- operator-gated and lands via A1 (CLAUDE.md §1 / PROJECT_BIBLE §2.3).

CREATE OR REPLACE FUNCTION public.get_discovery_gaps(
  p_gap_type text DEFAULT NULL,   -- NULL = all active gap types
  p_limit    int  DEFAULT 200
) RETURNS TABLE (
  id           bigint,
  event_id     bigint,
  gap_type     text,
  detail       text,
  signal_score numeric,
  detected_at  timestamptz,
  event_name   text,
  occurs_at    text               -- ISO local string (SG canonical UTC, else events.occurs_at_local)
)
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
DECLARE v_email text;
BEGIN
  -- Same operator gate as the sibling Discovery RPCs (get_blind_spots_tevo_selling,
  -- get_sg_blindspot_evo_tracking, get_returning_entities): broker-internal data,
  -- @s4kent.com only — never exposed to a non-S4K authenticated session.
  v_email := coalesce(auth.jwt()->>'email', '');
  IF v_email NOT LIKE '%@s4kent.com' THEN
    RAISE EXCEPTION 'forbidden: % is not an @s4kent.com email', v_email USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
  SELECT
    g.id,
    g.event_id,
    g.gap_type,
    g.detail,
    g.signal_score,
    g.detected_at,
    COALESCE(sgc.sg_event_name, e.name)                                          AS event_name,
    COALESCE(to_char(sgc.sg_datetime_utc, 'YYYY-MM-DD"T"HH24:MI:SS'), e.occurs_at_local) AS occurs_at
  FROM public.discovery_gap_alerts g
  LEFT JOIN LATERAL (
    SELECT s.sg_event_name, s.sg_datetime_utc
    FROM   public.sg_events_canonical s
    WHERE  s.tevo_event_id = g.event_id
    ORDER BY s.sg_datetime_utc DESC NULLS LAST
    LIMIT 1
  ) sgc ON true
  LEFT JOIN public.events e
    ON e.id = g.event_id
  WHERE g.resolved_at IS NULL
    AND (p_gap_type IS NULL OR g.gap_type = p_gap_type)
  ORDER BY g.signal_score DESC NULLS LAST
  LIMIT GREATEST(p_limit, 1);
END;
$function$;

-- Same exposure as the sibling Discovery RPCs: terminal (authenticated) +
-- service_role may read; anon/public may not.
REVOKE ALL ON FUNCTION public.get_discovery_gaps(text,int) FROM anon, public;

COMMENT ON FUNCTION public.get_discovery_gaps IS
  'Terminal Discovery gaps panel: active discovery_gap_alerts (resolved_at IS NULL), '
  'enriched with event name/date (SG canonical, TEvo events fallback), ordered by '
  'signal_score. Curated read path — discovery_gap_alerts is not client-grant-readable.';
