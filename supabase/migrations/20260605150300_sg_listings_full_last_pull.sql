-- Migration 20260601120000 · lane:D0 (author) → A1 (apply) · writes:get_event_sg_listings_full · reads:seatgeek_listings_snapshots,seatgeek_event_xref · pre:20260518030000 · auth:pending operator approval
-- ============================================================================
-- Migration 20260601120000 — SG Listings tab RPC: trim to the LAST PULL
--
-- Lane:     D0 (author) → A1 (apply)
-- Touches:  get_event_sg_listings_full (W, CREATE OR REPLACE),
--           seatgeek_listings_snapshots (R), seatgeek_event_xref (R)
-- Pre-reqs: 20260518030000 (prior uncapped definition of this fn)
--
-- Problem: the prior body dedups DISTINCT ON (sglid) across a 7-DAY window,
-- so every listing keeps its LAST-SEEN captured_at. Listings that left the
-- board days ago still return, stamped with stale pull times — the tab shows
-- one event's listings spread across many "Captured" timestamps (e.g. Guardians
-- @ Yankees sg 17691547: 4353 rows over 20 pulls vs 563 in the latest pull).
--
-- Fix: scope to the most recent pull only. Each poll writes one uniform
-- captured_at, so the current board = rows whose captured_at = max(captured_at)
-- within the 7-day window. DISTINCT ON (sglid) retained as a cheap guard against
-- a duplicate sglid inside a single pull. Output now also returns last_pull so
-- the FE can label freshness without scanning rows. Mirrors the client-side
-- guard shipped in PR #394 (static/terminal/event.js renderSgListingsFull) —
-- once applied, the FE filter is a no-op (all rows already share captured_at).
--
-- Everything else unchanged: signature, email gate, SECDEF, REVOKE/GRANT,
-- sg_event_id bridge, no_sg_bridge hidden-state, p_limit floor.
-- ============================================================================
--
-- ## Pending operator apply via apply_migration

CREATE OR REPLACE FUNCTION public.get_event_sg_listings_full(
  p_event_id integer,
  p_limit    integer DEFAULT 100000
)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, extensions, pg_temp
AS $func$
DECLARE
  v_email       text;
  v_sg_event_id bigint;
  v_last_pull   timestamptz;
  v_rows        jsonb;
BEGIN
  v_email := coalesce(auth.jwt()->>'email', '');
  IF v_email NOT LIKE '%@s4kent.com' THEN
    RAISE EXCEPTION 'forbidden: % is not an @s4kent.com email', v_email USING ERRCODE = '42501';
  END IF;

  SELECT sg_event_id INTO v_sg_event_id
  FROM public.seatgeek_event_xref WHERE tevo_event_id = p_event_id LIMIT 1;

  IF v_sg_event_id IS NULL THEN
    RETURN jsonb_build_object('hidden', true, 'reason', 'no_sg_bridge', 'count', 0, 'rows', '[]'::jsonb);
  END IF;

  -- Resolve the latest pull timestamp within the 7-day window (indexed scan
  -- on sg_event_id + captured_at). NULL when no listings captured for the event.
  SELECT max(captured_at) INTO v_last_pull
  FROM public.seatgeek_listings_snapshots
  WHERE sg_event_id = v_sg_event_id
    AND captured_at > now() - interval '7 days';

  IF v_last_pull IS NULL THEN
    RETURN jsonb_build_object('count', 0, 'sg_event_id', v_sg_event_id, 'last_pull', NULL, 'rows', '[]'::jsonb);
  END IF;

  WITH latest AS (
    SELECT DISTINCT ON (sglid)
      sglid, captured_at, section, row, quantity,
      retail_price_all_in, broadcast_price,
      delivery_method, stock_type, is_broker_owned, is_instant_download,
      market_source, splits, in_hand_date
    FROM public.seatgeek_listings_snapshots
    WHERE sg_event_id = v_sg_event_id
      AND captured_at = v_last_pull
    ORDER BY sglid, captured_at DESC
  )
  SELECT jsonb_build_object(
    'count', count(*),
    'sg_event_id', v_sg_event_id,
    'last_pull', v_last_pull,
    'rows', coalesce(jsonb_agg(to_jsonb(l) ORDER BY l.broadcast_price ASC NULLS LAST, l.section, l.row), '[]'::jsonb)
  ) INTO v_rows
  FROM (SELECT * FROM latest ORDER BY broadcast_price ASC NULLS LAST, section, row LIMIT greatest(1, p_limit)) l;

  RETURN v_rows;
END $func$;

REVOKE ALL ON FUNCTION public.get_event_sg_listings_full(integer, integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_event_sg_listings_full(integer, integer) TO anon, authenticated;

COMMENT ON FUNCTION public.get_event_sg_listings_full(integer, integer) IS
  'D0 event-page tabs — SG listings for an event, scoped to the LAST PULL only (captured_at = max within 7d), deduped on sglid, price-ascending. Returns last_pull for FE freshness. Email-gated. Supersedes the 7-day last-seen window (mig 20260601120000).';
