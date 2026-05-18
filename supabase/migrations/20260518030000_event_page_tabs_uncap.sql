-- Migration 20260518030000 · lane:D0 (author) → A1 (apply) · writes:get_event_sg_listings_full + get_event_evo_listings_full + get_event_sg_sales_full · reads:seatgeek_listings_snapshots,listings_snapshots,seatgeek_sales_snapshots,seatgeek_event_xref,sg_events_canonical · pre:20260517180000 · auth:operator-approved 2026-05-17
--
-- D0 — drop the 500-row ceiling on the 3 event-page full-list tab RPCs
-- shipped in PR #196 (mig 20260517180000) + the days_to_event_at_sale
-- inline-compute hotfix from PR #197 (mig 20260517210000).
--
-- Operator ask: SG Listings / EVO Listings / SG Sales tabs should show
-- ALL available data, not max 500.
--
-- Approach: CREATE OR REPLACE each function preserving signature, email
-- gate, SECDEF, REVOKE/GRANT, DISTINCT ON dedup. Two changes only:
--   1. Default p_limit bumped 250 → 100000 (practical "all rows" — SG
--      firehose 24h-deduped per event maxes ~10k for hot events; 10× headroom).
--   2. Inner LIMIT changed from `greatest(1, least(p_limit, 500))` to
--      just `greatest(1, p_limit)` — keep floor (no zero/negative), drop ceiling.
--
-- Everything else unchanged (DISTINCT ON keys, ORDER BY, window filters,
-- sg_event_id bridge, days_to_event_at_sale inline compute from A1's PR #197).
--
-- ## Pending operator apply via apply_migration

-- ============================================================
-- 1. SG Listings tab — uncapped
-- ============================================================
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
  FROM (SELECT * FROM latest ORDER BY captured_at DESC LIMIT greatest(1, p_limit)) l;

  RETURN v_rows;
END $func$;

REVOKE ALL ON FUNCTION public.get_event_sg_listings_full(integer, integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_event_sg_listings_full(integer, integer) TO anon, authenticated;

-- ============================================================
-- 2. EVO Listings tab — uncapped
-- ============================================================
CREATE OR REPLACE FUNCTION public.get_event_evo_listings_full(
  p_event_id integer,
  p_limit    integer DEFAULT 100000
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
  FROM (SELECT * FROM latest ORDER BY is_owned DESC, captured_at DESC LIMIT greatest(1, p_limit)) l;

  RETURN v_rows;
END $func$;

REVOKE ALL ON FUNCTION public.get_event_evo_listings_full(integer, integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_event_evo_listings_full(integer, integer) TO anon, authenticated;

-- ============================================================
-- 3. SG Sales tab — uncapped (preserves A1's PR #197 days_to_event_at_sale inline compute)
-- ============================================================
CREATE OR REPLACE FUNCTION public.get_event_sg_sales_full(
  p_event_id integer,
  p_limit    integer DEFAULT 100000,
  p_window_days integer DEFAULT 30
)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, extensions, pg_temp
AS $func$
DECLARE
  v_email       text;
  v_sg_event_id bigint;
  v_event_date  date;
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

  -- A1 PR #197 hotfix preserved: days_to_event_at_sale isn't a column on
  -- seatgeek_sales_snapshots — compute inline via sg_events_canonical lookup.
  SELECT sg_event_date INTO v_event_date
  FROM public.sg_events_canonical WHERE sg_event_id = v_sg_event_id LIMIT 1;

  -- DISTINCT ON sg_sale_id mandatory per PROJECT_BIBLE §3 (11x dedup factor).
  -- Scope to sg_event_id uses idx_sg_sales_sg_event_id_time.
  WITH latest AS (
    SELECT DISTINCT ON (sg_sale_id)
      sg_sale_id, sale_at_utc, pulled_at,
      section, row, quantity, broadcast_price, stock_type,
      CASE
        WHEN v_event_date IS NULL OR sale_at_utc IS NULL THEN NULL
        ELSE (v_event_date - sale_at_utc::date)::int
      END AS days_to_event_at_sale
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
  FROM (SELECT * FROM latest ORDER BY sale_at_utc DESC LIMIT greatest(1, p_limit)) l;

  RETURN v_rows;
END $func$;

REVOKE ALL ON FUNCTION public.get_event_sg_sales_full(integer, integer, integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_event_sg_sales_full(integer, integer, integer) TO anon, authenticated;

COMMENT ON FUNCTION public.get_event_sg_listings_full(integer, integer) IS
  'D0 event-page tabs — full SG listings for an event (deduped on sglid, last 7d, UNCAPPED default 100000). Email-gated.';

COMMENT ON FUNCTION public.get_event_evo_listings_full(integer, integer) IS
  'D0 event-page tabs — full TEvo listings for an event (deduped on tevo_ticket_group_id, last 7d, UNCAPPED default 100000, owned-first sort). Email-gated.';

COMMENT ON FUNCTION public.get_event_sg_sales_full(integer, integer, integer) IS
  'D0 event-page tabs — full SG sales for an event (DISTINCT ON sg_sale_id, window 1-90d, UNCAPPED default 100000). Inline days_to_event_at_sale (PR #197). Uses idx_sg_sales_sg_event_id_time. Email-gated.';
