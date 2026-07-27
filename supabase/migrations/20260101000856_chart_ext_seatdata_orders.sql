-- Migration 20260608170000 · lane:A1 · writes:get_event_chart_extended,get_event_seatdata_sales_full · reads:seatgeek_listings_snapshots,seatgeek_sales_snapshots,seatgeek_event_xref,seatdata_sales_snapshots,seatdata_event_xref,evo_order_items,evo_orders,tickpick_orders,vivid_orders,espn_injuries_snapshots,espn_event_snapshots,event_xref · pre:20260608032000 · auth:operator-approved 2026-06-08
--
-- D0 — wire SeatData sales + our orders (EVO+TickPick+Vivid) into the
-- Inventory & sales chart, and add a SeatData Sales top tab.
--
-- Two functions in this migration:
--
-- 1. CREATE OR REPLACE get_event_chart_extended (IDENTICAL 4-arg signature) —
--    additive: three new bucketed series appended to the `series` object,
--    every existing key untouched so the FE call is unchanged:
--      series.sd_sales_count   SeatData sales count per bucket (DISTINCT ON content_hash)
--      series.sd_sales_median  SeatData sales price median per bucket (price chart)
--      series.orders_count     OUR sell-through (EVO+TP+Vivid) tickets-sold per bucket
--    SeatData + orders are keyed by tevo_event_id directly (NOT the SG bridge),
--    so they render even when SG is hidden (v_sg_hidden).
--
-- 2. NEW get_event_seatdata_sales_full — clone of get_event_sg_sales_full
--    (mig 20260518030000) for the SeatData Sales tab. DISTINCT ON content_hash.
--
-- Sold-status filter (verified against live data 2026-06-08) — keep live, drop dead:
--   EVO    evo_orders.state       keep accepted/completed; drop rejected/canceled/canceled_post_acceptance
--   TICKPICK  ⚠ liveness is order_status (CONFIRMED/REJECTED), NOT status
--             (status is delivery state Scheduled/Rescheduled). Filtering on
--             `status` would silently keep cancelled orders — DO NOT "fix" this
--             back to status.
--   VIVID  vivid_orders.status    keep PENDING_SHIPMENT + shipped/completed; drop ignored_tbd_postponed/CANCELLED/CANCELED
--
-- Dedup: ONLY SeatData needs DISTINCT ON (append snapshot table, content-hashed).
-- Order tables are upsert-by-PK (not firehose snapshots) — no DISTINCT ON. SG
-- sales already dedup by sg_sale_id (unchanged).
--
-- Per A1 SECDEF pattern: SECDEF + @s4kent.com gate + REVOKE PUBLIC + GRANT
-- anon/authenticated. STABLE.

CREATE OR REPLACE FUNCTION public.get_event_chart_extended(
  p_event_id        integer,
  p_chart_hours     integer DEFAULT 168,
  p_espn_home_team  text    DEFAULT NULL,
  p_espn_away_team  text    DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, extensions, pg_temp
AS $func$
DECLARE
  v_email          text;
  v_sg_event_id    bigint;
  v_espn_event_id  text;
  v_espn_league    text;
  v_home_team      text := p_espn_home_team;
  v_away_team      text := p_espn_away_team;
  v_hours          int  := greatest(1, least(coalesce(p_chart_hours, 168), 4320));
  v_bucket_secs    int;
  v_window_start   timestamptz;
  v_now            timestamptz := now();
  v_sg_listings    jsonb := '[]'::jsonb;
  v_sg_listings_own jsonb := '[]'::jsonb;
  v_sg_listings_ct jsonb := '[]'::jsonb;
  v_sg_sales       jsonb := '[]'::jsonb;
  v_sg_sales_ct    jsonb := '[]'::jsonb;
  v_sd_sales       jsonb := '[]'::jsonb;   -- SeatData median price / bucket
  v_sd_sales_ct    jsonb := '[]'::jsonb;   -- SeatData sale count / bucket
  v_orders_ct      jsonb := '[]'::jsonb;   -- combined our-orders qty / bucket
  v_injuries       jsonb := '[]'::jsonb;
  v_game_state     jsonb := '[]'::jsonb;
  v_sg_hidden      boolean := false;
  v_sg_reason      text;
BEGIN
  -- ---------- auth gate (mirrors v3 / sibling RPCs) ----------
  v_email := coalesce(auth.jwt()->>'email', '');
  IF v_email NOT LIKE '%@s4kent.com' THEN
    RAISE EXCEPTION 'forbidden: % is not an @s4kent.com email', v_email USING ERRCODE = '42501';
  END IF;

  v_window_start := v_now - make_interval(hours => v_hours);

  -- ---------- bucket size (adapts to window length) ----------
  v_bucket_secs := CASE
    WHEN v_hours <=  24 THEN  900   -- 15 min
    WHEN v_hours <=  72 THEN 3600   --  1 hr
    WHEN v_hours <= 168 THEN 7200   --  2 hr
    WHEN v_hours <= 720 THEN 21600  --  6 hr
    ELSE 86400                      --  1 day
  END;

  -- ---------- bridge resolution ----------
  SELECT sg_event_id INTO v_sg_event_id
  FROM public.seatgeek_event_xref WHERE tevo_event_id = p_event_id LIMIT 1;

  IF v_sg_event_id IS NULL THEN
    v_sg_hidden := true;
    v_sg_reason := 'no_sg_bridge';
  END IF;

  -- ESPN linkage (always attempt — annotations may render even when SG is hidden)
  SELECT ex.espn_event_id, ex.espn_league
  INTO v_espn_event_id, v_espn_league
  FROM public.event_xref ex
  WHERE ex.tevo_event_id = p_event_id LIMIT 1;

  -- Auto-resolve home/away team IDs if not supplied by FE.
  -- Prefer espn_event_date_lookup (populated for forward-look events) over
  -- espn_event_snapshots (gameday-scope only per §10 drift watchlist).
  IF (v_home_team IS NULL OR v_away_team IS NULL) AND v_espn_event_id IS NOT NULL THEN
    SELECT home_team_id, away_team_id
    INTO v_home_team, v_away_team
    FROM public.espn_event_date_lookup
    WHERE espn_event_id = v_espn_event_id LIMIT 1;

    -- Snapshot fallback for past games where date_lookup is sparse
    IF v_home_team IS NULL OR v_away_team IS NULL THEN
      SELECT home_team_id, away_team_id
      INTO v_home_team, v_away_team
      FROM public.espn_event_snapshots
      WHERE espn_event_id = v_espn_event_id
      ORDER BY captured_at DESC LIMIT 1;
    END IF;
  END IF;

  -- ---------- SG listings series (DISTINCT ON sglid, then bucket) ----------
  IF NOT v_sg_hidden THEN
    WITH deduped AS (
      SELECT DISTINCT ON (sglid)
        sglid, captured_at, broadcast_price, quantity, is_broker_owned
      FROM public.seatgeek_listings_snapshots
      WHERE sg_event_id = v_sg_event_id
        AND captured_at > v_window_start
        AND captured_at <= v_now
      ORDER BY sglid, captured_at DESC
    ),
    bucketed AS (
      SELECT
        date_bin(make_interval(secs => v_bucket_secs), captured_at, '2000-01-01'::timestamptz) AS bucket,
        broadcast_price, quantity, is_broker_owned
      FROM deduped
      WHERE broadcast_price IS NOT NULL
    )
    SELECT
      coalesce(jsonb_agg(jsonb_build_object('t', to_char(bucket AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'), 'v', median_p) ORDER BY bucket), '[]'::jsonb),
      coalesce(jsonb_agg(jsonb_build_object('t', to_char(bucket AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'), 'v', median_p_owned) ORDER BY bucket) FILTER (WHERE median_p_owned IS NOT NULL), '[]'::jsonb),
      coalesce(jsonb_agg(jsonb_build_object('t', to_char(bucket AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'), 'v', total_qty) ORDER BY bucket), '[]'::jsonb)
    INTO v_sg_listings, v_sg_listings_own, v_sg_listings_ct
    FROM (
      SELECT
        bucket,
        percentile_cont(0.5) WITHIN GROUP (ORDER BY broadcast_price) AS median_p,
        percentile_cont(0.5) WITHIN GROUP (ORDER BY broadcast_price) FILTER (WHERE is_broker_owned) AS median_p_owned,
        SUM(quantity)::int AS total_qty
      FROM bucketed GROUP BY bucket
    ) b;
  END IF;

  -- ---------- SG sales series (DISTINCT ON sg_sale_id, then bucket on sale_at_utc) ----------
  IF NOT v_sg_hidden THEN
    WITH deduped AS (
      SELECT DISTINCT ON (sg_sale_id)
        sg_sale_id, sale_at_utc, pulled_at, broadcast_price, quantity
      FROM public.seatgeek_sales_snapshots
      WHERE sg_event_id = v_sg_event_id
        AND coalesce(sale_at_utc, pulled_at) > v_window_start
        AND coalesce(sale_at_utc, pulled_at) <= v_now
      ORDER BY sg_sale_id, pulled_at DESC
    ),
    bucketed AS (
      SELECT
        date_bin(make_interval(secs => v_bucket_secs), coalesce(sale_at_utc, pulled_at), '2000-01-01'::timestamptz) AS bucket,
        broadcast_price
      FROM deduped
      WHERE broadcast_price IS NOT NULL
    )
    SELECT
      coalesce(jsonb_agg(jsonb_build_object('t', to_char(bucket AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'), 'v', median_p) ORDER BY bucket), '[]'::jsonb),
      coalesce(jsonb_agg(jsonb_build_object('t', to_char(bucket AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'), 'v', sale_ct) ORDER BY bucket), '[]'::jsonb)
    INTO v_sg_sales, v_sg_sales_ct
    FROM (
      SELECT
        bucket,
        percentile_cont(0.5) WITHIN GROUP (ORDER BY broadcast_price) AS median_p,
        count(*)::int AS sale_ct
      FROM bucketed GROUP BY bucket
    ) b;
  END IF;

  -- ---------- SeatData sales series (DISTINCT ON content_hash, bucket on sale_timestamp) ----------
  -- Keyed by tevo_event_id directly (independent of the SG bridge), so it
  -- renders even when SG is hidden. count(*) (sale rows) parallels SG sale ct.
  WITH deduped AS (
    SELECT DISTINCT ON (content_hash)
      content_hash, sale_timestamp, price, quantity
    FROM public.seatdata_sales_snapshots
    WHERE tevo_event_id = p_event_id
      AND sale_timestamp > v_window_start
      AND sale_timestamp <= v_now
    ORDER BY content_hash, pulled_at DESC
  ),
  bucketed AS (
    SELECT
      date_bin(make_interval(secs => v_bucket_secs), sale_timestamp, '2000-01-01'::timestamptz) AS bucket,
      price
    FROM deduped
  )
  SELECT
    coalesce(jsonb_agg(jsonb_build_object('t', to_char(bucket AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'), 'v', median_p) ORDER BY bucket) FILTER (WHERE median_p IS NOT NULL), '[]'::jsonb),
    coalesce(jsonb_agg(jsonb_build_object('t', to_char(bucket AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'), 'v', sale_ct) ORDER BY bucket), '[]'::jsonb)
  INTO v_sd_sales, v_sd_sales_ct
  FROM (
    SELECT
      bucket,
      percentile_cont(0.5) WITHIN GROUP (ORDER BY price) FILTER (WHERE price IS NOT NULL) AS median_p,
      count(*)::int AS sale_ct
    FROM bucketed GROUP BY bucket
  ) b;

  -- ---------- OUR orders: EVO + TickPick + Vivid (sold-status filtered, then bucket) ----------
  -- No DISTINCT ON — these are upsert-by-PK tables, not firehose snapshots.
  WITH norm AS (
    -- EVO: line-items joined to order header for state + created_at
    SELECT o.evo_created_at AS ts, coalesce(oi.quantity, 1) AS qty
    FROM public.evo_order_items oi
    JOIN public.evo_orders o ON o.evo_order_id = oi.evo_order_id
    WHERE oi.event_id = p_event_id
      AND coalesce(o.state, '') NOT IN ('rejected', 'canceled', 'cancelled', 'canceled_post_acceptance')
    UNION ALL
    -- TickPick: liveness is order_status (NOT status — see header caveat)
    SELECT ordered_at AS ts, coalesce(quantity, 1) AS qty
    FROM public.tickpick_orders
    WHERE tevo_event_id = p_event_id
      AND (order_status IS NULL OR upper(order_status) NOT IN ('REJECTED', 'CANCELLED', 'CANCELED', 'REFUNDED', 'VOID'))
    UNION ALL
    -- Vivid
    SELECT ordered_at AS ts, coalesce(quantity, 1) AS qty
    FROM public.vivid_orders
    WHERE tevo_event_id = p_event_id
      AND coalesce(status, '') NOT IN ('ignored_tbd_postponed', 'CANCELLED', 'CANCELED')
  ),
  bucketed AS (
    SELECT
      date_bin(make_interval(secs => v_bucket_secs), ts, '2000-01-01'::timestamptz) AS bucket,
      qty
    FROM norm
    WHERE ts IS NOT NULL
      AND ts > v_window_start
      AND ts <= v_now
  )
  SELECT
    coalesce(jsonb_agg(jsonb_build_object('t', to_char(bucket AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'), 'v', total_qty) ORDER BY bucket), '[]'::jsonb)
  INTO v_orders_ct
  FROM (
    SELECT bucket, SUM(qty)::int AS total_qty
    FROM bucketed GROUP BY bucket
  ) b;

  -- ---------- ESPN injury transitions (LAG per athlete, both teams) ----------
  -- espn_team_id is NOT globally unique across leagues — e.g. id="28" maps to
  -- MLB Atlanta Braves AND an NHL team. ALWAYS scope by espn_league so cross-
  -- league fan-out doesn't surface unrelated injuries on a sport-specific chart.
  IF (v_home_team IS NOT NULL OR v_away_team IS NOT NULL) AND v_espn_league IS NOT NULL THEN
    WITH ordered AS (
      SELECT
        captured_at, espn_team_id, athlete_id, athlete_name, position, status,
        LAG(status) OVER (PARTITION BY athlete_id ORDER BY captured_at) AS prev_status
      FROM public.espn_injuries_snapshots
      WHERE espn_league = v_espn_league
        AND espn_team_id IN (v_home_team, v_away_team)
        AND espn_team_id IS NOT NULL
        AND captured_at > v_window_start
        AND captured_at <= v_now
    )
    SELECT coalesce(jsonb_agg(jsonb_build_object(
             'at',            to_char(captured_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
             'athlete_id',    athlete_id,
             'athlete_name',  athlete_name,
             'position',      position,
             'espn_team_id',  espn_team_id,
             'prev_status',   prev_status,
             'new_status',    status
           ) ORDER BY captured_at), '[]'::jsonb)
    INTO v_injuries
    FROM ordered
    WHERE status IS DISTINCT FROM prev_status;  -- transitions only (including first-seen NULL→X)
  END IF;

  -- ---------- ESPN game-state transitions (LAG on status_short, this event) ----------
  IF v_espn_event_id IS NOT NULL THEN
    WITH ordered AS (
      SELECT
        captured_at, espn_event_id, status_short, state,
        LAG(status_short) OVER (PARTITION BY espn_event_id ORDER BY captured_at) AS prev_status
      FROM public.espn_event_snapshots
      WHERE espn_event_id = v_espn_event_id
        AND (v_espn_league IS NULL OR espn_league = v_espn_league)
        AND captured_at > v_window_start
        AND captured_at <= v_now
    )
    SELECT coalesce(jsonb_agg(jsonb_build_object(
             'at',             to_char(captured_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
             'espn_event_id',  espn_event_id,
             'prev_status',    prev_status,
             'new_status',     status_short,
             'state',          state
           ) ORDER BY captured_at), '[]'::jsonb)
    INTO v_game_state
    FROM ordered
    WHERE status_short IS DISTINCT FROM prev_status;
  END IF;

  -- ---------- assemble ----------
  RETURN jsonb_build_object(
    'tevo_event_id',  p_event_id,
    'sg_event_id',    v_sg_event_id,
    'espn_event_id',  v_espn_event_id,
    'espn_league',    v_espn_league,
    'home_team_id',   v_home_team,
    'away_team_id',   v_away_team,
    'range', jsonb_build_object(
      'start',  to_char(v_window_start AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
      'end',    to_char(v_now          AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
      'hours',  v_hours,
      'bucket_seconds', v_bucket_secs
    ),
    'sg_hidden', v_sg_hidden,
    'sg_reason', v_sg_reason,
    'series', jsonb_build_object(
      'sg_listings_median',       v_sg_listings,
      'sg_listings_owned_median', v_sg_listings_own,
      'sg_listings_count',        v_sg_listings_ct,
      'sg_sales_median',          v_sg_sales,
      'sg_sales_count',           v_sg_sales_ct,
      'sd_sales_median',          v_sd_sales,
      'sd_sales_count',           v_sd_sales_ct,
      'orders_count',             v_orders_ct
    ),
    'annotations', jsonb_build_object(
      'injuries',   v_injuries,
      'game_state', v_game_state
    )
  );
END $func$;

REVOKE ALL ON FUNCTION public.get_event_chart_extended(integer, integer, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_event_chart_extended(integer, integer, text, text) TO anon, authenticated;

COMMENT ON FUNCTION public.get_event_chart_extended(integer, integer, text, text) IS
  'D0 event chart extension — SG-side series (listings median/owned/count + sales median/count) + SeatData sales (sd_sales_median/sd_sales_count, DISTINCT ON content_hash) + OUR orders sell-through (orders_count = EVO+TickPick+Vivid tickets sold/bucket, sold-status filtered) + 2 ESPN annotation arrays. SeatData/orders keyed by tevo_event_id (render even when SG hidden). DISTINCT ON sg_sale_id|sglid|content_hash mandatory (§3 landmine). ⚠ TickPick liveness uses order_status, NOT status. Email-gated.';

-- ============================================================
-- get_event_seatdata_sales_full — SeatData Sales tab (clone of get_event_sg_sales_full)
-- ============================================================
CREATE OR REPLACE FUNCTION public.get_event_seatdata_sales_full(
  p_event_id    integer,
  p_limit       integer DEFAULT 100000,
  p_window_days integer DEFAULT 30
)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, extensions, pg_temp
AS $func$
DECLARE
  v_email       text;
  v_sd_event_id bigint;
  v_rows        jsonb;
BEGIN
  v_email := coalesce(auth.jwt()->>'email', '');
  IF v_email NOT LIKE '%@s4kent.com' THEN
    RAISE EXCEPTION 'forbidden: % is not an @s4kent.com email', v_email USING ERRCODE = '42501';
  END IF;

  -- Optional bridge lookup for the meta line (SeatData sales are keyed directly
  -- on tevo_event_id, so absence of an xref row does NOT hide the data).
  SELECT sd_event_id INTO v_sd_event_id
  FROM public.seatdata_event_xref WHERE tevo_event_id = p_event_id LIMIT 1;

  -- DISTINCT ON content_hash (SeatData dedup key). Window on sale_timestamp.
  WITH latest AS (
    SELECT DISTINCT ON (content_hash)
      content_hash, sale_timestamp, price, quantity, zone, section, row
    FROM public.seatdata_sales_snapshots
    WHERE tevo_event_id = p_event_id
      AND sale_timestamp > now() - make_interval(days => greatest(1, least(p_window_days, 90)))
    ORDER BY content_hash, pulled_at DESC
  )
  SELECT jsonb_build_object(
    'count', count(*),
    'sd_event_id', v_sd_event_id,
    'window_days', greatest(1, least(p_window_days, 90)),
    'rows', coalesce(jsonb_agg(to_jsonb(l) ORDER BY l.sale_timestamp DESC), '[]'::jsonb)
  ) INTO v_rows
  FROM (SELECT * FROM latest ORDER BY sale_timestamp DESC LIMIT greatest(1, p_limit)) l;

  RETURN v_rows;
END $func$;

REVOKE ALL ON FUNCTION public.get_event_seatdata_sales_full(integer, integer, integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_event_seatdata_sales_full(integer, integer, integer) TO anon, authenticated;

COMMENT ON FUNCTION public.get_event_seatdata_sales_full(integer, integer, integer) IS
  'D0 event-page tabs — full SeatData sales for an event (DISTINCT ON content_hash, window 1-90d, UNCAPPED default 100000). Keyed on tevo_event_id (no SG bridge). Email-gated.';
