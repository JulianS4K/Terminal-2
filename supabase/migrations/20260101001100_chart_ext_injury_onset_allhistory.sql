-- Migration 20260629220000 · level:data-collection · lane:a1 · writes:get_event_chart_extended · reads:espn_injuries_snapshots,espn_event_snapshots,seatgeek_*,seatdata_sales_snapshots,evo_order_items,evo_orders,tickpick_orders,vivid_orders,event_xref,seatgeek_event_xref,espn_event_date_lookup · pre:20260608170000
--
-- ESPN injuries → event price chart: surface genuine injury ONSETS, not nothing.
--
-- SYMPTOM (terminal demo prep, 2026-06-29)
--   The event-page price chart's ESPN injury markers (pink "+") never appeared
--   for team-sport events (verified on the Yankees @ Rays demo event 3099851:
--   Aaron Judge → 10-Day-IL, Max Fried → 15-Day-IL, Stanton, McMahon, Wells all
--   present in espn_injuries_snapshots, zero markers drawn).
--
-- ROOT CAUSE (two layers)
--   1. FE (static/terminal/event.js) skipped EVERY prev_status==null row to avoid
--      a left-edge baseline pile-up — but because espn-collect re-baselines on a
--      content-hash basis, a fresh onset almost always arrives with prev_status
--      null, so the skip hid essentially all injuries. (Fixed in the same branch:
--      FE now renders transitions + in-window onsets.)
--   2. RPC computed LAG(status) over the IN-WINDOW rows only. A pre-existing
--      injury re-captured inside the window had its first in-window row tagged
--      prev_status=null (its real prior status sat just before window_start),
--      so it masqueraded as an onset AND piled at the left edge; meanwhile the
--      adaptive bucket noise made "transitions only" emit a flood or nothing.
--
-- FIX (this migration, RPC-side; injury CTE only — all other CTEs byte-identical
--      to mig 20260608170000)
--   Compute LAG over ALL HISTORY per stable athlete identity, THEN filter to the
--   in-window rows. Now:
--     • a pre-existing injury re-seen unchanged in-window has prev_status =
--       its real prior status = current status ⇒ filtered out (no left-edge cluster);
--     • a true status change in-window (DTD→Out→IL) keeps a non-null prev_status
--       ⇒ one marker per real transition;
--     • a brand-new injury whose first-ever capture is in-window keeps
--       prev_status=null ⇒ a genuine onset marker (the FE renders these).
--   Partition restored to the stable identity (espn_league, espn_team_id,
--   lower(btrim(coalesce(athlete_name, athlete_id)))) per the Arias fix
--   (mig 20260520220000) — defends against ESPN provisional negative athlete_ids.
--
-- INVARIANTS PRESERVED
--   - Signature, SECDEF, STABLE, search_path, @s4kent.com email gate unchanged.
--   - REVOKE/GRANT matrix unchanged (idempotent re-grant included).
--   - SG listings/sales series, SeatData sales, our-orders count, and game-state
--     transition CTEs are byte-identical to mig 20260608170000.
--
-- ⏳ NOT YET APPLIED — pending operator apply_migration (A1).
-- Post-apply smoke:
--   SELECT jsonb_array_length(
--     public.get_event_chart_extended(3099851, 720) -> 'annotations' -> 'injuries'
--   );  -- expect a handful of real injury events across both rosters, not 0 / not 200+

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
  v_sd_sales       jsonb := '[]'::jsonb;
  v_sd_sales_ct    jsonb := '[]'::jsonb;
  v_orders_ct      jsonb := '[]'::jsonb;
  v_injuries       jsonb := '[]'::jsonb;
  v_game_state     jsonb := '[]'::jsonb;
  v_sg_hidden      boolean := false;
  v_sg_reason      text;
BEGIN
  v_email := coalesce(auth.jwt()->>'email', '');
  IF v_email NOT LIKE '%@s4kent.com' THEN
    RAISE EXCEPTION 'forbidden: % is not an @s4kent.com email', v_email USING ERRCODE = '42501';
  END IF;

  v_window_start := v_now - make_interval(hours => v_hours);

  v_bucket_secs := CASE
    WHEN v_hours <=  24 THEN  900
    WHEN v_hours <=  72 THEN 3600
    WHEN v_hours <= 168 THEN 7200
    WHEN v_hours <= 720 THEN 21600
    ELSE 86400
  END;

  SELECT sg_event_id INTO v_sg_event_id
  FROM public.seatgeek_event_xref WHERE tevo_event_id = p_event_id LIMIT 1;

  IF v_sg_event_id IS NULL THEN
    v_sg_hidden := true;
    v_sg_reason := 'no_sg_bridge';
  END IF;

  SELECT ex.espn_event_id, ex.espn_league
  INTO v_espn_event_id, v_espn_league
  FROM public.event_xref ex
  WHERE ex.tevo_event_id = p_event_id LIMIT 1;

  IF (v_home_team IS NULL OR v_away_team IS NULL) AND v_espn_event_id IS NOT NULL THEN
    SELECT home_team_id, away_team_id
    INTO v_home_team, v_away_team
    FROM public.espn_event_date_lookup
    WHERE espn_event_id = v_espn_event_id LIMIT 1;

    IF v_home_team IS NULL OR v_away_team IS NULL THEN
      SELECT home_team_id, away_team_id
      INTO v_home_team, v_away_team
      FROM public.espn_event_snapshots
      WHERE espn_event_id = v_espn_event_id
      ORDER BY captured_at DESC LIMIT 1;
    END IF;
  END IF;

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

  -- SeatData sales (DISTINCT ON content_hash, bucket on sale_timestamp) — keyed on tevo_event_id
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

  -- OUR orders: EVO + TickPick + Vivid (sold-status filtered) — no DISTINCT ON (upsert-by-PK)
  WITH norm AS (
    SELECT o.evo_created_at AS ts, coalesce(oi.quantity, 1) AS qty
    FROM public.evo_order_items oi
    JOIN public.evo_orders o ON o.evo_order_id = oi.evo_order_id
    WHERE oi.event_id = p_event_id
      AND coalesce(o.state, '') NOT IN ('rejected', 'canceled', 'cancelled', 'canceled_post_acceptance')
    UNION ALL
    SELECT ordered_at AS ts, coalesce(quantity, 1) AS qty
    FROM public.tickpick_orders
    WHERE tevo_event_id = p_event_id
      AND (order_status IS NULL OR upper(order_status) NOT IN ('REJECTED', 'CANCELLED', 'CANCELED', 'REFUNDED', 'VOID'))
    UNION ALL
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

  -- ---------- ESPN injury onsets/transitions (LAG over ALL HISTORY, then window-filter) ----------
  -- Compute prev_status across the athlete's FULL history (not just in-window) so
  -- a pre-existing injury re-seen unchanged inside the window is filtered out
  -- (prev = current), eliminating the left-edge baseline cluster, while genuine
  -- in-window transitions (non-null prev) and brand-new onsets (null prev whose
  -- first-ever capture is in-window) both survive. Partition on stable identity
  -- (Arias provisional-id fix, mig 20260520220000).
  IF (v_home_team IS NOT NULL OR v_away_team IS NOT NULL) AND v_espn_league IS NOT NULL THEN
    WITH hist AS (
      SELECT
        captured_at, espn_team_id, athlete_id, athlete_name, position, status,
        LAG(status) OVER (
          PARTITION BY espn_league, espn_team_id,
                       lower(btrim(coalesce(athlete_name, athlete_id, '')))
          ORDER BY captured_at
        ) AS prev_status
      FROM public.espn_injuries_snapshots
      WHERE espn_league = v_espn_league
        AND espn_team_id IN (v_home_team, v_away_team)
        AND espn_team_id IS NOT NULL
        AND captured_at <= v_now
    ),
    ordered AS (
      SELECT *
      FROM hist
      WHERE captured_at > v_window_start
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
    WHERE status IS DISTINCT FROM prev_status;
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
  'D0 event chart extension — SG listings/sales series + SeatData sales + our-orders count over adaptive buckets + 2 ESPN annotation arrays. Injuries: LAG(status) over ALL athlete history (stable identity partition), filtered to in-window status changes/onsets so pre-existing unchanged injuries drop out (no left-edge cluster) and real onsets/transitions surface (mig 20260629220000). Game-state: LAG(status_short) per espn_event_id. Bridge via seatgeek_event_xref; ESPN via event_xref. Email-gated.';
