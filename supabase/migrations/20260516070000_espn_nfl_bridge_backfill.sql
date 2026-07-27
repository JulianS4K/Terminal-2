-- Migration 20260516070000 · admin · ESPN→TEvo→AQ→SG NFL bridge backfill · pre:20260516060000
--
-- Operator directive 2026-05-16: "NFL schedule just got released ... use ESPN game
-- data to search for event in TEvo and then map that event to aq event and use aq
-- number to map to sg."
--
-- 100-event sync census earlier this session surfaced: 0% of sampled NFL events had
-- cross-source bridges (SG / ESPN / AQ). Root cause: NFL schedule was JUST released;
-- AQ + ESPN ingests hadn't yet picked up the regular season.
--
-- This migration:
-- 1. Triggers ESPN scoreboard ingest with 270-day lookahead (cron default is 90d —
--    enough for preseason but misses regular season Oct-Jan). 322 NFL games landed
--    in espn_event_date_lookup spanning 2026-08-07 to 2027-01-31.
-- 2. Bridges ESPN→TEvo via entity_performer_map (32 NFL teams, all mapped). Matches
--    on home_team_id + ±6h date window. Result: 292/322 (91%) ESPN games matched
--    to live TEvo events.
-- 3. Populates event_xref (the table backing entity_event_map view's ESPN side) for
--    the 292 matched events. match_method='a1_espn_nfl_perfid_date_2026_05_16'.
-- 4. Creates AQ rows for the 292 events via existing create_system_aq_event fn
--    (SYS-{md5(name|venue|date)[:10]} convention). category='espn_nfl_derived'.
-- 5. Attempts AQ→SG match via venue+date probe of sg_events_canonical. Found 3
--    SG NFL games (Lions@Bills TNF 9/17, Cowboys@Giants SNF 9/13, Bears@Lions 11/26
--    Thanksgiving — all primetime). Updates aq_event_map.sg_event_id + inserts
--    seatgeek_event_xref rows for those 3.
--
-- Idempotent: re-runs are no-ops via ON CONFLICT clauses.
--
-- ## Already applied to prod  Applied via MCP 2026-05-16.

-- ============================================================
-- Step 1: Trigger ESPN scoreboard ingest with full-season lookahead
-- ============================================================
SELECT public.espn_scoreboard_queue(270);

-- Step 2: Wait for pg_net to fetch (typical ~10-15s for 7 scoreboard requests)
SELECT pg_sleep(15);

-- Step 3: Process the responses into espn_event_date_lookup
SELECT public.espn_scoreboard_process();

-- ============================================================
-- Step 4: Populate event_xref with ESPN→TEvo NFL bridges
-- ============================================================
WITH matched AS (
  SELECT DISTINCT ON (e.id)
    e.id AS tevo_event_id,
    eg.espn_event_id,
    'NFL'::text AS espn_league,
    abs(EXTRACT(epoch FROM (e.occurs_at_local::timestamptz - eg.game_at_utc))) AS time_delta
  FROM public.espn_event_date_lookup eg
  JOIN public.entity_performer_map pm_home
    ON pm_home.espn_team_id = eg.home_team_id AND pm_home.espn_league = 'NFL'
  JOIN public.events e
    ON e.primary_performer_id = pm_home.tevo_performer_id
    AND e.occurs_at_local ~ '^\d{4}-\d{2}-\d{2}'
    AND abs(EXTRACT(epoch FROM (e.occurs_at_local::timestamptz - eg.game_at_utc))) < 21600
  WHERE eg.espn_league = 'NFL' AND eg.game_at_utc > now()
  ORDER BY e.id, abs(EXTRACT(epoch FROM (e.occurs_at_local::timestamptz - eg.game_at_utc)))
)
INSERT INTO public.event_xref AS m
  (tevo_event_id, espn_event_id, espn_league, espn_slug, matched_at, match_method, meta)
SELECT
  tevo_event_id, espn_event_id, espn_league,
  'nfl-' || espn_event_id,
  now(),
  'a1_espn_nfl_perfid_date_2026_05_16',
  jsonb_build_object('time_delta_sec', time_delta)
FROM matched
ON CONFLICT (tevo_event_id) DO UPDATE SET
  espn_event_id = EXCLUDED.espn_event_id,
  espn_league   = EXCLUDED.espn_league,
  espn_slug     = EXCLUDED.espn_slug,
  matched_at    = now(),
  match_method  = EXCLUDED.match_method;

-- ============================================================
-- Step 5: Create AQ rows for matched events (via existing helper)
-- ============================================================
DO $$
DECLARE
  r RECORD;
  v_count int := 0;
BEGIN
  FOR r IN
    SELECT e.name, e.venue_name, e.occurs_at_local
    FROM public.event_xref ex
    JOIN public.events e ON e.id = ex.tevo_event_id
    WHERE ex.espn_league = 'NFL'
      AND ex.match_method = 'a1_espn_nfl_perfid_date_2026_05_16'
      AND e.occurs_at_local ~ '^\d{4}-\d{2}-\d{2}'
  LOOP
    PERFORM public.create_system_aq_event(
      'espn_nfl_derived', r.name, r.venue_name, r.occurs_at_local::timestamptz);
    v_count := v_count + 1;
  END LOOP;
  RAISE NOTICE 'NFL AQ rows created/upserted: %', v_count;
END $$;

-- ============================================================
-- Step 6: AQ→SG match via venue+date (matcher tier 2 equivalent)
-- ============================================================
WITH our_nfl AS (
  SELECT
    e.id AS tevo_event_id, e.name AS tevo_name, e.venue_name AS tevo_venue,
    e.occurs_at_local::timestamptz AS event_at,
    aem.aq_short_event_id
  FROM public.event_xref ex
  JOIN public.events e ON e.id = ex.tevo_event_id
  JOIN public.aq_event_map aem
    ON aem.aq_short_event_id = 'SYS-' || substring(
       md5(coalesce(e.name,'') || '|' || coalesce(e.venue_name,'') || '|' ||
           coalesce(to_char(e.occurs_at_local::timestamptz, 'YYYY-MM-DD"T"HH24:MI'),''))
       from 1 for 10)
  WHERE ex.espn_league = 'NFL'
    AND ex.match_method = 'a1_espn_nfl_perfid_date_2026_05_16'
    AND e.occurs_at_local ~ '^\d{4}-\d{2}-\d{2}'
),
sg_matched AS (
  SELECT DISTINCT ON (n.tevo_event_id)
    n.tevo_event_id, n.aq_short_event_id, c.sg_event_id, c.sg_event_name,
    c.sg_venue_name, c.sg_datetime_utc
  FROM our_nfl n
  JOIN public.sg_events_canonical c
    ON lower(trim(c.sg_venue_name)) = lower(trim(n.tevo_venue))
    AND abs(EXTRACT(epoch FROM (c.sg_datetime_utc - n.event_at))) < 21600
  ORDER BY n.tevo_event_id, abs(EXTRACT(epoch FROM (c.sg_datetime_utc - n.event_at)))
),
upd_aq AS (
  UPDATE public.aq_event_map aem
  SET sg_event_id = sm.sg_event_id
  FROM sg_matched sm
  WHERE aem.aq_short_event_id = sm.aq_short_event_id
    AND aem.sg_event_id IS NULL
  RETURNING aem.aq_short_event_id
)
INSERT INTO public.seatgeek_event_xref AS x
  (tevo_event_id, sg_event_id, sg_event_name, sg_event_location, sg_start_data,
   matched_at, match_method, match_confidence)
SELECT
  tevo_event_id, sg_event_id, sg_event_name, sg_venue_name, sg_datetime_utc,
  now(), 'a1_espn_nfl_perfid_bridge_2026_05_16', 0.95
FROM sg_matched
ON CONFLICT (tevo_event_id) DO UPDATE SET
  sg_event_id   = EXCLUDED.sg_event_id,
  sg_event_name = EXCLUDED.sg_event_name,
  matched_at    = now(),
  match_method  = EXCLUDED.match_method;

-- ============================================================
-- Step 7: v2 RPC fallback bridge fix
-- ============================================================
-- Earlier v2 RPC anchored bridge lookups on _v_d0_event_index which only contains
-- SG-tracked events (anchored on sg_event_priority_state). NFL events lacking SG
-- presence fell through silently with all bridge_ids = NULL.
--
-- Fix: when view returns no row, fall back to base tables (events + venue_assets +
-- event_xref + seatgeek_event_xref + aq_event_map). For aq_short_event_id lookup,
-- also try the SYS-{md5(name|venue|date)[:10]} convention used by create_system_aq_event.

CREATE OR REPLACE FUNCTION public.get_broker_event_page_v2(
  p_event_id    integer,
  p_chart_hours integer DEFAULT 720
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, extensions, pg_temp
AS $func$
DECLARE
  v_email           text;
  v_base            jsonb;
  v_now             timestamptz := now();
  v_sg_event_id     bigint;
  v_aq_id           text;
  v_espn_event_id   text;
  v_espn_league     text;
  v_venue_tevo_id   bigint;
  v_is_indoor       boolean;
  v_event_at        timestamptz;
  v_sales_tape      jsonb;
  v_weather         jsonb;
  v_espn            jsonb;
  v_event_alerts    jsonb;
  v_sg_sxs          jsonb;
  v_splits          jsonb;
  v_freshness       jsonb;
  v_max_tevo        timestamptz;
  v_max_sg_lst      timestamptz;
  v_max_sg_sales    timestamptz;
  v_max_weather     timestamptz;
  v_max_espn_team   timestamptz;
  v_max_espn_inj    timestamptz;
  v_max_sd_sales    timestamptz;
  v_home_team_id    text;
  v_away_team_id    text;
BEGIN
  v_email := coalesce(auth.jwt()->>'email', '');
  IF v_email NOT LIKE '%@s4kent.com' THEN
    RAISE EXCEPTION 'forbidden: % is not an @s4kent.com email', v_email USING ERRCODE = '42501';
  END IF;

  v_base := public.get_broker_event_page(p_event_id, p_chart_hours);

  -- Primary: bridge IDs from _v_d0_event_index (anchored on sg_event_priority_state)
  SELECT v.sg_event_id, v.aq_short_event_id, v.espn_event_id, v.espn_league,
         v.venue_tevo_id, v.is_indoor, v.event_at_utc
  INTO v_sg_event_id, v_aq_id, v_espn_event_id, v_espn_league,
       v_venue_tevo_id, v_is_indoor, v_event_at
  FROM public._v_d0_event_index v
  WHERE v.tevo_event_id = p_event_id LIMIT 1;

  -- Fallback for non-SG events (NFL, NWSL, niche): read from base tables
  IF v_event_at IS NULL THEN
    SELECT
      CASE WHEN e.occurs_at_local ~ '^\d{4}-\d{2}-\d{2}'
           THEN e.occurs_at_local::timestamptz ELSE NULL END,
      e.venue_id, va.is_indoor
    INTO v_event_at, v_venue_tevo_id, v_is_indoor
    FROM public.events e
    LEFT JOIN public.venue_assets va ON va.tevo_venue_id = e.venue_id
    WHERE e.id = p_event_id LIMIT 1;
  END IF;

  IF v_espn_event_id IS NULL THEN
    SELECT ex.espn_event_id, ex.espn_league
    INTO v_espn_event_id, v_espn_league
    FROM public.event_xref ex WHERE ex.tevo_event_id = p_event_id LIMIT 1;
  END IF;

  IF v_sg_event_id IS NULL THEN
    SELECT sgx.sg_event_id INTO v_sg_event_id
    FROM public.seatgeek_event_xref sgx WHERE sgx.tevo_event_id = p_event_id LIMIT 1;
  END IF;

  IF v_aq_id IS NULL THEN
    IF v_sg_event_id IS NOT NULL THEN
      SELECT aem.aq_short_event_id INTO v_aq_id
      FROM public.aq_event_map aem WHERE aem.sg_event_id = v_sg_event_id LIMIT 1;
    END IF;
    IF v_aq_id IS NULL THEN
      -- SYS-{md5} convention (created via create_system_aq_event)
      SELECT aem.aq_short_event_id INTO v_aq_id
      FROM public.events e
      JOIN public.aq_event_map aem
        ON aem.aq_short_event_id = 'SYS-' || substring(
             md5(coalesce(e.name,'') || '|' || coalesce(e.venue_name,'') || '|' ||
                 coalesce(to_char(e.occurs_at_local::timestamptz, 'YYYY-MM-DD"T"HH24:MI'),''))
             from 1 for 10)
      WHERE e.id = p_event_id
        AND e.occurs_at_local ~ '^\d{4}-\d{2}-\d{2}'
      LIMIT 1;
    END IF;
  END IF;

  -- sales_tape
  IF v_sg_event_id IS NOT NULL THEN
    WITH latest_per_sale AS (
      SELECT DISTINCT ON (sg_sale_id)
        sg_sale_id, sale_at_utc, section, row, quantity, broadcast_price, stock_type
      FROM public.seatgeek_sales_snapshots
      WHERE sg_event_id = v_sg_event_id
        AND sale_at_utc > now() - interval '30 days'
      ORDER BY sg_sale_id, pulled_at DESC
    )
    SELECT coalesce(jsonb_agg(to_jsonb(lp) ORDER BY lp.sale_at_utc DESC), '[]'::jsonb)
    INTO v_sales_tape
    FROM (SELECT * FROM latest_per_sale ORDER BY sale_at_utc DESC LIMIT 20) lp;
  ELSE
    v_sales_tape := '[]'::jsonb;
  END IF;

  -- weather
  IF v_is_indoor IS FALSE AND v_venue_tevo_id IS NOT NULL AND v_event_at IS NOT NULL THEN
    WITH forecast AS (
      SELECT is_forecast, observed_at, temp_f, precip_pct, precip_in, wind_mph,
             gust_mph, humidity_pct, weather_summary
      FROM public.weather_observations
      WHERE tevo_venue_id = v_venue_tevo_id
        AND is_forecast = true
        AND observed_at BETWEEN now() AND now() + interval '7 days'
      ORDER BY abs(EXTRACT(epoch FROM (observed_at - v_event_at)))
      LIMIT 6
    ),
    recent_obs AS (
      SELECT is_forecast, observed_at, temp_f, precip_pct, precip_in, wind_mph,
             gust_mph, humidity_pct, weather_summary
      FROM public.weather_observations
      WHERE tevo_venue_id = v_venue_tevo_id
        AND is_forecast = false
        AND observed_at > now() - interval '24 hours'
      ORDER BY observed_at DESC LIMIT 3
    ),
    active_alerts AS (
      SELECT id, event, severity, urgency, headline, expires_at, area_desc
      FROM public.nws_alerts WHERE expires_at > now() ORDER BY expires_at LIMIT 5
    )
    SELECT jsonb_build_object(
      'venue_tevo_id', v_venue_tevo_id,
      'event_at',      v_event_at,
      'forecast',      coalesce((SELECT jsonb_agg(to_jsonb(f) ORDER BY f.observed_at) FROM forecast f), '[]'::jsonb),
      'recent_obs',    coalesce((SELECT jsonb_agg(to_jsonb(r) ORDER BY r.observed_at DESC) FROM recent_obs r), '[]'::jsonb),
      'nws_alerts',    coalesce((SELECT jsonb_agg(to_jsonb(a)) FROM active_alerts a), '[]'::jsonb)
    ) INTO v_weather;
  ELSE
    v_weather := jsonb_build_object('hidden', true, 'reason',
      CASE WHEN v_is_indoor IS TRUE THEN 'indoor_venue'
           WHEN v_venue_tevo_id IS NULL THEN 'no_venue_xref'
           WHEN v_event_at IS NULL THEN 'no_event_time'
           ELSE 'unknown' END);
  END IF;

  -- ESPN (gated on espn xref; falls back to date_lookup for events without snapshots yet)
  IF v_espn_event_id IS NOT NULL THEN
    SELECT home_team_id, away_team_id INTO v_home_team_id, v_away_team_id
    FROM public.espn_event_snapshots
    WHERE espn_event_id = v_espn_event_id
    ORDER BY captured_at DESC LIMIT 1;

    IF v_home_team_id IS NULL THEN
      SELECT home_team_id, away_team_id INTO v_home_team_id, v_away_team_id
      FROM public.espn_event_date_lookup
      WHERE espn_event_id = v_espn_event_id LIMIT 1;
    END IF;

    WITH team_snaps AS (
      SELECT DISTINCT ON (espn_team_id)
        espn_team_id, captured_at, wins, losses, ties, win_pct,
        record_summary, standing_summary, streak, playoff_seed
      FROM public.espn_team_snapshots
      WHERE espn_league = v_espn_league
        AND espn_team_id = ANY(ARRAY[v_home_team_id, v_away_team_id])
      ORDER BY espn_team_id, captured_at DESC
    ),
    injuries AS (
      SELECT DISTINCT ON (athlete_id, espn_team_id)
        espn_team_id, athlete_name, position, status, injury_type,
        short_comment, return_date, last_seen_at
      FROM public.espn_injuries_snapshots
      WHERE espn_league = v_espn_league
        AND espn_team_id = ANY(ARRAY[v_home_team_id, v_away_team_id])
        AND last_seen_at > now() - interval '7 days'
      ORDER BY athlete_id, espn_team_id, last_seen_at DESC
    ),
    recent_results AS (
      SELECT DISTINCT ON (espn_event_id)
        espn_event_id, captured_at, state, status_short,
        home_team_id, away_team_id, home_score, away_score
      FROM public.espn_event_snapshots
      WHERE espn_league = v_espn_league
        AND state = 'post'
        AND (home_team_id = ANY(ARRAY[v_home_team_id, v_away_team_id])
             OR away_team_id = ANY(ARRAY[v_home_team_id, v_away_team_id]))
        AND captured_at > now() - interval '60 days'
      ORDER BY espn_event_id, captured_at DESC
    )
    SELECT jsonb_build_object(
      'espn_event_id',   v_espn_event_id,
      'espn_league',     v_espn_league,
      'home_team_id',    v_home_team_id,
      'away_team_id',    v_away_team_id,
      'team_standings',  coalesce((SELECT jsonb_agg(to_jsonb(t)) FROM team_snaps t), '[]'::jsonb),
      'injuries',        coalesce((SELECT jsonb_agg(to_jsonb(i) ORDER BY i.last_seen_at DESC) FROM injuries i), '[]'::jsonb),
      'recent_results',  coalesce((SELECT jsonb_agg(to_jsonb(r) ORDER BY r.captured_at DESC) FROM recent_results r LIMIT 10), '[]'::jsonb)
    ) INTO v_espn;
  ELSE
    v_espn := jsonb_build_object('hidden', true, 'reason', 'no_espn_xref');
  END IF;

  SELECT coalesce(jsonb_agg(to_jsonb(a) ORDER BY a.fired_at DESC), '[]'::jsonb)
  INTO v_event_alerts
  FROM (
    SELECT id, rule_key, fired_at, severity, message, payload, acknowledged_at
    FROM public.event_alerts
    WHERE tevo_event_id = p_event_id
      AND fired_at > now() - make_interval(hours => greatest(1, least(coalesce(p_chart_hours, 720), 4320)))
    ORDER BY fired_at DESC LIMIT 50
  ) a;

  IF v_sg_event_id IS NOT NULL THEN
    WITH em_latest AS (
      SELECT row_number() OVER (ORDER BY captured_at DESC) AS rn,
             captured_at, listings_count, tickets_count,
             cost_min, cost_p25, cost_median, cost_mean, cost_p75, cost_p90, cost_max, cost_sum,
             sold_quantity, sold_gross, sold_price_min, sold_price_median, sold_price_max,
             unique_sections, unique_rows
      FROM public.seatgeek_event_metrics
      WHERE sg_event_id = v_sg_event_id
      ORDER BY captured_at DESC LIMIT 25
    )
    SELECT jsonb_build_object(
      'sg_event_id', v_sg_event_id,
      'current',  (SELECT to_jsonb(e) FROM em_latest e WHERE rn = 1),
      'd24h_ago', (SELECT to_jsonb(e) FROM em_latest e
                   WHERE e.captured_at <= now() - interval '24 hours'
                   ORDER BY e.captured_at DESC LIMIT 1)
    ) INTO v_sg_sxs;
  ELSE
    v_sg_sxs := jsonb_build_object('hidden', true, 'reason', 'no_sg_bridge');
  END IF;

  WITH latest_per_tg AS (
    SELECT DISTINCT ON (tevo_ticket_group_id)
      quantity, is_owned, retail_price, brokerage_id
    FROM public.listings_snapshots
    WHERE event_id = p_event_id AND captured_at > now() - interval '24 hours'
    ORDER BY tevo_ticket_group_id, captured_at DESC
  ),
  bucketed AS (
    SELECT
      CASE WHEN is_owned AND brokerage_id = 1768 THEN 'owned' ELSE 'market' END AS src,
      CASE WHEN quantity = 1 THEN 'singles' WHEN quantity = 2 THEN 'pairs'
           WHEN quantity = 3 THEN 'triples' WHEN quantity = 4 THEN 'quads'
           ELSE 'five_plus' END AS bucket,
      quantity, retail_price
    FROM latest_per_tg
  )
  SELECT coalesce(jsonb_object_agg(src, bucket_data), jsonb_build_object('owned','{}'::jsonb, 'market','{}'::jsonb))
  INTO v_splits
  FROM (
    SELECT src, jsonb_object_agg(bucket, jsonb_build_object(
      'tg_count', tg_count, 'tix_count', tix_count,
      'min_px', round(min_px::numeric, 2), 'avg_px', round(avg_px::numeric, 2), 'max_px', round(max_px::numeric, 2)
    )) AS bucket_data
    FROM (
      SELECT src, bucket, count(*) AS tg_count, sum(quantity) AS tix_count,
             min(retail_price) AS min_px, avg(retail_price) AS avg_px, max(retail_price) AS max_px
      FROM bucketed GROUP BY src, bucket
    ) ia GROUP BY src
  ) oa;

  IF v_splits IS NULL THEN v_splits := jsonb_build_object('owned','{}'::jsonb, 'market','{}'::jsonb); END IF;

  SELECT max(captured_at) INTO v_max_tevo
  FROM public.listings_snapshots WHERE event_id = p_event_id;

  IF v_sg_event_id IS NOT NULL THEN
    SELECT max(captured_at) INTO v_max_sg_lst
    FROM public.seatgeek_listings_snapshots WHERE sg_event_id = v_sg_event_id;
    SELECT max(sale_at_utc) INTO v_max_sg_sales
    FROM public.seatgeek_sales_snapshots WHERE sg_event_id = v_sg_event_id;
  END IF;

  IF v_venue_tevo_id IS NOT NULL THEN
    SELECT max(observed_at) INTO v_max_weather
    FROM public.weather_observations
    WHERE tevo_venue_id = v_venue_tevo_id AND is_forecast = false;
  END IF;

  IF v_espn_event_id IS NOT NULL THEN
    SELECT max(captured_at) INTO v_max_espn_team
    FROM public.espn_team_snapshots
    WHERE espn_league = v_espn_league
      AND espn_team_id = ANY(ARRAY[v_home_team_id, v_away_team_id]);
    SELECT max(last_seen_at) INTO v_max_espn_inj
    FROM public.espn_injuries_snapshots
    WHERE espn_league = v_espn_league
      AND espn_team_id = ANY(ARRAY[v_home_team_id, v_away_team_id]);
  END IF;

  SELECT max(sale_timestamp) INTO v_max_sd_sales
  FROM public.sd_sales_normalized WHERE tevo_event_id = p_event_id;

  v_freshness := jsonb_build_object(
    'tevo_listings_latest', v_max_tevo,
    'sg_listings_latest',   v_max_sg_lst,
    'sg_sales_latest',      v_max_sg_sales,
    'weather_latest',       v_max_weather,
    'espn_team_latest',     v_max_espn_team,
    'espn_inj_latest',      v_max_espn_inj,
    'sd_sales_latest',      v_max_sd_sales,
    'computed_at',          v_now
  );

  RETURN v_base || jsonb_build_object(
    'v', 'v2',
    'bridge_ids', jsonb_build_object(
      'tevo_event_id', p_event_id,
      'sg_event_id', v_sg_event_id,
      'aq_short_event_id', v_aq_id,
      'espn_event_id', v_espn_event_id,
      'espn_league', v_espn_league,
      'venue_tevo_id', v_venue_tevo_id
    ),
    'sales_tape',      v_sales_tape,
    'weather',         v_weather,
    'espn',            v_espn,
    'event_alerts',    v_event_alerts,
    'sg_side_by_side', v_sg_sxs,
    'splits',          v_splits,
    'freshness',       v_freshness
  );
END $func$;

COMMENT ON FUNCTION public.get_broker_event_page_v2(integer, integer) IS
  'D0 Phase 2a Event Detail RPC. Reads bridge IDs from _v_d0_event_index first; falls back to event_xref + seatgeek_event_xref + aq_event_map (SYS-md5 convention) for events not in sg_event_priority_state. 7 new payload keys beyond v1: sales_tape, weather, espn, event_alerts, sg_side_by_side, splits, freshness. Email-gated to @s4kent.com.';
