-- Migration 20260608140000 · level:2 · lane:D0
-- writes: get_event_section_map(bigint) [fn]
-- reads:  events, venue_section_map
--
-- Purpose (Step 5 — terminal UI data API): config-aware seat-map crosswalk for one
--   event. Resolves events.configuration_id to the matching venue_section_map bucket,
--   falling back to the union bucket (configuration_id = 0) when the event has no
--   config or no rows for it. Email-gated @s4kent.com like the other terminal RPCs.
--   Consumed by the terminal event page's seat-map panel (loadEventSectionMap).
--
-- ## Already applied to prod  Applied via MCP 2026-06-08 (operator-authorized).
--   Tested: event 3091415 (Yankee, config 53) -> 447 sections, 380 mapped.

CREATE OR REPLACE FUNCTION public.get_event_section_map(p_event_id bigint)
RETURNS TABLE(platform text, section_raw text, seatmap_key text, match_method text, confidence numeric, seen_listings integer, configuration_id integer)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public','pg_temp'
AS $function$
DECLARE v_email text; v_venue bigint; v_cfg integer; v_use integer;
BEGIN
  v_email := coalesce(auth.jwt()->>'email','');
  IF v_email NOT LIKE '%@s4kent.com' THEN
    RAISE EXCEPTION 'forbidden: % is not @s4kent.com', v_email USING ERRCODE='42501';
  END IF;
  SELECT e.venue_id, e.configuration_id INTO v_venue, v_cfg FROM public.events e WHERE e.id = p_event_id;
  IF v_venue IS NULL THEN RETURN; END IF;
  v_use := v_cfg;
  IF v_use IS NULL OR NOT EXISTS (SELECT 1 FROM public.venue_section_map m WHERE m.tevo_venue_id=v_venue AND m.configuration_id=v_use) THEN
    v_use := 0;
  END IF;
  RETURN QUERY
    SELECT m.platform, m.section_raw, m.seatmap_key, m.match_method, m.confidence, m.seen_listings, m.configuration_id
    FROM public.venue_section_map m
    WHERE m.tevo_venue_id = v_venue AND m.configuration_id = v_use
    ORDER BY m.platform, m.section_raw;
END $function$;
COMMENT ON FUNCTION public.get_event_section_map(bigint) IS
  'Terminal seat-map panel API: config-aware section->seatmap_key crosswalk for an event (resolves events.configuration_id, falls back to union bucket 0). Email-gated @s4kent.com.';
REVOKE EXECUTE ON FUNCTION public.get_event_section_map(bigint) FROM anon, public;
GRANT EXECUTE ON FUNCTION public.get_event_section_map(bigint) TO authenticated;
