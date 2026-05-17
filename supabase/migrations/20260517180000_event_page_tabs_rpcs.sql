-- Migration 20260517180000 · lane:D0 (author) → A1 (apply) · writes:get_event_sg_listings_full + get_event_evo_listings_full + get_event_sg_sales_full · reads:seatgeek_listings_snapshots,listings_snapshots,seatgeek_sales_snapshots,seatgeek_event_xref · pre:20260517030000 · auth:operator-approved 2026-05-17
--
-- D0 Phase 2a tabs — 3 SECDEF RPCs powering the new event-page tabs:
--   Tab "SG Listings"      — full window of SG listings (deduped on sglid)
--   Tab "EVO Listings"     — full window of TEvo listings (deduped on tevo_ticket_group_id)
--   Tab "SG Sales"         — full window of SG sales (deduped on sg_sale_id, 11x dedup factor)
--
-- The existing v3 sales_tape returns 20 deduped rows; this RPC returns up to
-- 500 with optional p_window_hours so the tab can show full broker history.
--
-- All 3 follow the same pattern as v3 RPCs:
--   - SECURITY DEFINER + email gate (@s4kent.com)
--   - REVOKE ALL FROM PUBLIC; GRANT EXECUTE to anon + authenticated
--   - 250-500 row caps to keep payloads sane
--   - DISTINCT ON natural key to handle pull-time dedup (esp. SG sales 11x factor)
--   - ORDER BY captured_at/pulled_at DESC for "newest first"
--
-- ## Pending operator apply via apply_migration

-- ============================================================
-- 1. SG Listings tab — all listings for an event from seatgeek_listings_snapshots
-- ============================================================
CREATE OR REPLACE FUNCTION public.get_event_sg_listings_full(
  p_event_id integer,
  p_limit    integer DEFAULT 250
)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, extensions, pg_temp
AS $func$
DECLARE
  v_email       text;
  v_sg_event_id bigint;
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

  WITH latest AS (
    SELECT DISTINCT ON (sglid)
      sglid, captured_at, section, row, quantity,
      retail_price_all_in, broadcast_price,
      delivery_method, stock_type, is_broker_owned, is_instant_download,
      market_source, splits, in_hand_date
    FROM public.seatgeek_listings_snapshots
    WHERE sg_event_id = v_sg_event_id
      AND captured_at > now() - interval '7 days'
    ORDER BY sglid, captured_at DESC
  )
  SELECT jsonb_build_object(
    'count', count(*),
    'sg_event_id', v_sg_event_id,
    'rows', coalesce(jsonb_agg(to_jsonb(l) ORDER BY l.captured_at DESC), '[]'::jsonb)
  ) INTO v_rows
  FROM (SELECT * FROM latest ORDER BY captured_at DESC LIMIT greatest(1, least(p_limit, 500))) l;

  RETURN v_rows;
END $func$;

REVOKE ALL ON FUNCTION public.get_event_sg_listings_full(integer, integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_event_sg_listings_full(integer, integer) TO anon, authenticated;

-- ============================================================
-- 2. EVO Listings tab — all TEvo listings for an event from listings_snapshots
-- ============================================================
CREATE OR REPLACE FUNCTION public.get_event_evo_listings_full(
  p_event_id integer,
  p_limit    integer DEFAULT 250
)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, extensions, pg_temp
AS $func$
DECLARE
  v_email text;
  v_rows  jsonb;
BEGIN
  v_email := coalesce(auth.jwt()->>'email', '');
  IF v_email NOT LIKE '%@s4kent.com' THEN
    RAISE EXCEPTION 'forbidden: % is not an @s4kent.com email', v_email USING ERRCODE = '42501';
  END IF;

  WITH latest AS (
    SELECT DISTINCT ON (tevo_ticket_group_id)
      tevo_ticket_group_id, captured_at, section, row, quantity,
      retail_price, wholesale_price, format, splits,
      is_owned, is_ancillary, brokerage_id, brokerage_name,
      office_name, instant_delivery, eticket, type,
      prev_retail_price, prev_quantity
    FROM public.listings_snapshots
    WHERE event_id = p_event_id
      AND captured_at > now() - interval '7 days'
    ORDER BY tevo_ticket_group_id, captured_at DESC
  )
  SELECT jsonb_build_object(
    'count', count(*),
    'event_id', p_event_id,
    'rows', coalesce(jsonb_agg(to_jsonb(l) ORDER BY l.is_owned DESC, l.captured_at DESC), '[]'::jsonb)
  ) INTO v_rows
  FROM (SELECT * FROM latest ORDER BY is_owned DESC, captured_at DESC LIMIT greatest(1, least(p_limit, 500))) l;

  RETURN v_rows;
END $func$;

REVOKE ALL ON FUNCTION public.get_event_evo_listings_full(integer, integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_event_evo_listings_full(integer, integer) TO anon, authenticated;

-- ============================================================
-- 3. SG Sales tab — full window of SG broker sales (deduped 11x firehose)
-- ============================================================
CREATE OR REPLACE FUNCTION public.get_event_sg_sales_full(
  p_event_id integer,
  p_limit    integer DEFAULT 250,
  p_window_days integer DEFAULT 30
)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, extensions, pg_temp
AS $func$
DECLARE
  v_email       text;
  v_sg_event_id bigint;
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

  -- DISTINCT ON sg_sale_id mandatory per PROJECT_BIBLE §3 (11x dedup factor).
  -- Scope to sg_event_id uses idx_sg_sales_sg_event_id_time (A1 ship 2026-05-16).
  WITH latest AS (
    SELECT DISTINCT ON (sg_sale_id)
      sg_sale_id, sale_at_utc, pulled_at,
      section, row, quantity, broadcast_price, stock_type,
      days_to_event_at_sale
    FROM public.seatgeek_sales_snapshots
    WHERE sg_event_id = v_sg_event_id
      AND sale_at_utc > now() - make_interval(days => greatest(1, least(p_window_days, 90)))
    ORDER BY sg_sale_id, pulled_at DESC
  )
  SELECT jsonb_build_object(
    'count', count(*),
    'sg_event_id', v_sg_event_id,
    'window_days', greatest(1, least(p_window_days, 90)),
    'rows', coalesce(jsonb_agg(to_jsonb(l) ORDER BY l.sale_at_utc DESC), '[]'::jsonb)
  ) INTO v_rows
  FROM (SELECT * FROM latest ORDER BY sale_at_utc DESC LIMIT greatest(1, least(p_limit, 500))) l;

  RETURN v_rows;
END $func$;

REVOKE ALL ON FUNCTION public.get_event_sg_sales_full(integer, integer, integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_event_sg_sales_full(integer, integer, integer) TO anon, authenticated;

COMMENT ON FUNCTION public.get_event_sg_listings_full(integer, integer) IS
  'D0 event-page tabs — full SG listings for an event (deduped on sglid, last 7d, capped 500). Email-gated.';

COMMENT ON FUNCTION public.get_event_evo_listings_full(integer, integer) IS
  'D0 event-page tabs — full TEvo listings for an event (deduped on tevo_ticket_group_id, last 7d, capped 500, owned-first sort). Email-gated.';

COMMENT ON FUNCTION public.get_event_sg_sales_full(integer, integer, integer) IS
  'D0 event-page tabs — full SG sales for an event (DISTINCT ON sg_sale_id, window 1-90d, capped 500). Uses idx_sg_sales_sg_event_id_time. Email-gated.';
