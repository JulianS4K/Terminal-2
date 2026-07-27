-- Migration 20260603180000 · lane:D0 (author) → A1 (apply) · writes:get_event_source_links · reads:aq_event_map,sg_events_canonical,ticketsdata_event_xref · pre:20260603120000 · auth:operator-requested 2026-06-03
--
-- D0 — per-source marketplace event URLs for the event page's data tabs, so the
-- operator can click straight through to each source and spot-check our captured
-- data against the live book. Resolves EVERYTHING off the canonical aq_event_map
-- hub (the "map via aq" rule, PROJECT_BIBLE §5) keyed by the tevo event id:
--   aq_event_map → sg/sh/vivid/tm event ids + aq_short_event_id
--   SG url  → sg_events_canonical.sg_url   (fallback: constructed /e/events/<id>)
--   TD urls → ticketsdata_event_xref.event_url per platform (SH/GT/VD/TP/TM)
--
-- ticketsdata_event_xref has NO authenticated GRANT (RLS-opaque to Path C), so
-- this SECDEF wrapper is the only way the email-gated terminal can surface those
-- real per-platform URLs. TEvo has no consumer URL → not returned (FE omits it).
--
-- Return shape:
--   { tevo_event_id, sg_event_id, sh_event_id, vivid_event_id, tm_event_id,
--     aq_short_event_id, event_name, sg_url, td:{ SH,GT,VD,TP,TM → url } }

CREATE OR REPLACE FUNCTION public.get_event_source_links(p_event_id bigint)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $func$
DECLARE
  v_email   text;
  v_sg_id   bigint;
  v_sh_id   bigint;
  v_vivid   bigint;
  v_tm_id   bigint;
  v_aq      text;
  v_name    text;
  v_sg_url  text;
  v_td      jsonb;
BEGIN
  v_email := coalesce(auth.jwt()->>'email', '');
  IF v_email NOT LIKE '%@s4kent.com' THEN
    RAISE EXCEPTION 'forbidden: % is not an @s4kent.com email', v_email USING ERRCODE = '42501';
  END IF;

  -- Canonical hub: a tevo event can have >1 aq_event_map row (per aq_source);
  -- pick the freshest non-null id for each source so partial rows still resolve.
  SELECT max(sg_event_id), max(sh_event_id), max(vivid_event_id), max(tm_event_id),
         max(aq_short_event_id), max(event_name)
    INTO v_sg_id, v_sh_id, v_vivid, v_tm_id, v_aq, v_name
  FROM public.aq_event_map
  WHERE tevo_event_id = p_event_id;

  -- SeatGeek canonical URL; fall back to a constructed event link when missing.
  IF v_sg_id IS NOT NULL THEN
    SELECT sg_url INTO v_sg_url
    FROM public.sg_events_canonical
    WHERE sg_event_id = v_sg_id AND sg_url IS NOT NULL AND sg_url <> ''
    ORDER BY updated_at DESC NULLS LAST
    LIMIT 1;
    IF v_sg_url IS NULL OR v_sg_url = '' THEN
      v_sg_url := 'https://seatgeek.com/e/events/' || v_sg_id;
    END IF;
  END IF;

  -- TicketsData per-platform real event URLs. Bridge via the canonical aq hub:
  -- aq_event_map(tevo) → aq_short_event_id → ticketsdata_event_xref (the 100%
  -- join key — NOT xref.event_id, which is the TD-internal id; see sibling RPC
  -- get_event_all_source_listing_metrics + PROJECT_BIBLE §5). Active + freshest
  -- first per platform.
  SELECT jsonb_object_agg(platform, event_url) INTO v_td
  FROM (
    SELECT DISTINCT ON (x.platform) x.platform, x.event_url
    FROM public.aq_event_map a
    JOIN public.ticketsdata_event_xref x ON x.aq_short_event_id = a.aq_short_event_id
    WHERE a.tevo_event_id = p_event_id
      AND x.event_url IS NOT NULL AND x.event_url <> ''
    ORDER BY x.platform, x.active DESC NULLS LAST, x.updated_at DESC NULLS LAST
  ) q;

  RETURN jsonb_build_object(
    'tevo_event_id',     p_event_id,
    'sg_event_id',       v_sg_id,
    'sh_event_id',       v_sh_id,
    'vivid_event_id',    v_vivid,
    'tm_event_id',       v_tm_id,
    'aq_short_event_id', v_aq,
    'event_name',        v_name,
    'sg_url',            v_sg_url,
    'td',                coalesce(v_td, '{}'::jsonb)
  );
END
$func$;

REVOKE ALL ON FUNCTION public.get_event_source_links(bigint) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_event_source_links(bigint) TO anon, authenticated;
