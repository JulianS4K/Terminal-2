-- A1 PR-4a (part 4 of 5) — v2 RPC sg_side_by_side cost_* → listings_all_* + listings_owned_*
-- Per zany-skipping-fox plan: payload key names renamed (cost_median → listings_all_median).
-- D0 already familiar with the naming via PR #204.

CREATE OR REPLACE FUNCTION public.get_broker_event_page_v2(p_event_id integer, p_chart_hours integer DEFAULT 720)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
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

  SELECT v.sg_event_id, v.aq_short_event_id, v.espn_event_id, v.espn_league,
         v.venue_tevo_id, v.is_indoor, v.event_at_utc
  INTO v_sg_event_id, v_aq_id, v_espn_event_id, v_espn_league,
       v_venue_tevo_id, v_is_indoor, v_event_at
  FROM public._v_d0_event_index v
  WHERE v.tevo_event_id = p_event_id LIMIT 1;

  IF v_event_at IS NULL THEN
    SELECT CASE WHEN e.occurs_at_local ~ '^\d{4}-\d{2}-\d{2}'
                THEN e.occurs_at_local::timestamptz ELSE NULL END,
           e.venue_id, va.is_indoor
    INTO v_event_at, v_venue_tevo_id, v_is_indoor
    FROM public.events e
    LEFT JOIN public.venue_assets va ON va.tevo_venue_id = e.venue_id
    WHERE e.id = p_event_id LIMIT 1;
  END IF;

  IF v_espn_event_id IS NULL THEN
    SELECT ex.espn_event_id, ex.espn_league INTO v_espn_event_id, v_espn_league
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

  -- sales_tape (unchanged)
  IF v_sg_event_id IS NOT NULL THEN
    WITH latest_per_sale AS (
      SELECT DISTINCT ON (sg_sale_id) sg_sale_id, sale_at_utc, section, row, quantity, broadcast_price, stock_type
      FROM public.seatgeek_sales_snapshots
      WHERE sg_event_id = v_sg_event_id AND sale_at_utc > now() - interval '30 days'
      ORDER BY sg_sale_id, pulled_at DESC
    )
    SELECT coalesce(jsonb_agg(to_jsonb(lp) ORDER BY lp.sale_at_utc DESC), '[]'::jsonb)
    INTO v_sales_tape
    FROM (SELECT * FROM latest_per_sale ORDER BY sale_at_utc DESC LIMIT 20) lp;
  ELSE
    v_sales_tape := '[]'::jsonb;
  END IF;

  -- weather (unchanged)
  IF v_is_indoor IS FALSE AND v_venue_tevo_id IS NOT NULL AND v_event_at IS NOT NULL THEN
    WITH forecast AS (
      SELECT is_forecast, observed_at, temp_f, precip_pct, precip_in, wind_mph, gust_mph, humidity_pct, weather_summary
      FROM public.weather_observations
      WHERE tevo_venue_id = v_venue_tevo_id AND is_forecast = true
        AND observed_at BETWEEN now() AND now() + interval '7 days'
      ORDER BY abs(EXTRACT(epoch FROM (observed_at - v_event_at))) LIMIT 6
    ),
    recent_obs AS (
      SELECT is_forecast, observed_at, temp_f, precip_pct, precip_in, wind_mph, gust_mph, humidity_pct, weather_summary
      FROM public.weather_observations
      WHERE tevo_venue_id = v_venue_tevo_id AND is_forecast = false
        AND observed_at > now() - interval '24 hours'
      ORDER BY observed_at DESC LIMIT 3
    ),
    active_alerts AS (
      SELECT id, event, severity, urgency, headline, expires_at, area_desc
      FROM public.nws_alerts WHERE expires_at > now() ORDER BY expires_at LIMIT 5
    )
    SELECT jsonb_build_object(
      'venue_tevo_id', v_venue_tevo_id, 'event_at', v_event_at,
      'forecast', coalesce((SELECT jsonb_agg(to_jsonb(f) ORDER BY f.observed_at) FROM forecast f), '[]'::jsonb),
      'recent_obs', coalesce((SELECT jsonb_agg(to_jsonb(r) ORDER BY r.observed_at DESC) FROM recent_obs r), '[]'::jsonb),
      'nws_alerts', coalesce((SELECT jsonb_agg(to_jsonb(a)) FROM active_alerts a), '[]'::jsonb)
    ) INTO v_weather;
  ELSE
    v_weather := jsonb_build_object('hidden', true, 'reason',
      CASE WHEN v_is_indoor IS TRUE THEN 'indoor_venue'
           WHEN v_venue_tevo_id IS NULL THEN 'no_venue_xref'
           WHEN v_event_at IS NULL THEN 'no_event_time'
           ELSE 'unknown' END);
  END IF;

  -- ESPN (unchanged)
  IF v_espn_event_id IS NOT NULL THEN
    SELECT home_team_id, away_team_id INTO v_home_team_id, v_away_team_id
    FROM public.espn_event_snapshots
    WHERE espn_event_id = v_espn_event_id ORDER BY captured_at DESC LIMIT 1;
    IF v_home_team_id IS NULL THEN
      SELECT home_team_id, away_team_id INTO v_home_team_id, v_away_team_id
      FROM public.espn_event_date_lookup WHERE espn_event_id = v_espn_event_id LIMIT 1;
    END IF;
    WITH team_snaps AS (
      SELECT DISTINCT ON (espn_team_id) espn_team_id, captured_at, wins, losses, ties, win_pct,
             record_summary, standing_summary, streak, playoff_seed
      FROM public.espn_team_snapshots
      WHERE espn_league = v_espn_league AND espn_team_id = ANY(ARRAY[v_home_team_id, v_away_team_id])
      ORDER BY espn_team_id, captured_at DESC
    ),
    injuries AS (
      SELECT DISTINCT ON (athlete_id, espn_team_id) espn_team_id, athlete_name, position, status, injury_type, short_comment, return_date, last_seen_at
      FROM public.espn_injuries_snapshots
      WHERE espn_league = v_espn_league AND espn_team_id = ANY(ARRAY[v_home_team_id, v_away_team_id])
        AND last_seen_at > now() - interval '7 days'
      ORDER BY athlete_id, espn_team_id, last_seen_at DESC
    ),
    recent_results AS (
      SELECT DISTINCT ON (espn_event_id) espn_event_id, captured_at, state, status_short, home_team_id, away_team_id, home_score, away_score
      FROM public.espn_event_snapshots
      WHERE espn_league = v_espn_league AND state = 'post'
        AND (home_team_id = ANY(ARRAY[v_home_team_id, v_away_team_id]) OR away_team_id = ANY(ARRAY[v_home_team_id, v_away_team_id]))
        AND captured_at > now() - interval '60 days'
      ORDER BY espn_event_id, captured_at DESC
    )
    SELECT jsonb_build_object(
      'espn_event_id', v_espn_event_id, 'espn_league', v_espn_league,
      'home_team_id', v_home_team_id, 'away_team_id', v_away_team_id,
      'team_standings', coalesce((SELECT jsonb_agg(to_jsonb(t)) FROM team_snaps t), '[]'::jsonb),
      'injuries', coalesce((SELECT jsonb_agg(to_jsonb(i) ORDER BY i.last_seen_at DESC) FROM injuries i), '[]'::jsonb),
      'recent_results', coalesce((SELECT jsonb_agg(to_jsonb(r) ORDER BY r.captured_at DESC) FROM recent_results r LIMIT 10), '[]'::jsonb)
    ) INTO v_espn;
  ELSE
    v_espn := jsonb_build_object('hidden', true, 'reason', 'no_espn_xref');
  END IF;

  -- event_alerts (unchanged)
  SELECT coalesce(jsonb_agg(to_jsonb(a) ORDER BY a.fired_at DESC), '[]'::jsonb) INTO v_event_alerts
  FROM (
    SELECT id, rule_key, fired_at, severity, message, payload, acknowledged_at
    FROM public.event_alerts
    WHERE tevo_event_id = p_event_id AND fired_at > now() - make_interval(hours => greatest(1, least(coalesce(p_chart_hours, 720), 4320)))
    ORDER BY fired_at DESC LIMIT 50
  ) a;

  -- sg_side_by_side — A1 2026-05-18 PR-4a: cost_* swap → listings_all_* + listings_owned_*
  IF v_sg_event_id IS NOT NULL THEN
    WITH em_latest AS (
      SELECT row_number() OVER (ORDER BY captured_at DESC) AS rn,
             captured_at,
             listings_all_count, listings_all_tickets,
             listings_all_min, listings_all_p25, listings_all_median, listings_all_mean,
             listings_all_p75, listings_all_p90, listings_all_max,
             listings_owned_count, listings_owned_tickets,
             listings_owned_min, listings_owned_p25, listings_owned_median, listings_owned_mean,
             listings_owned_p75, listings_owned_p90, listings_owned_max,
             sold_quantity, sold_gross, sold_price_min, sold_price_median, sold_price_max,
             unique_sections, unique_rows
      FROM public.seatgeek_event_metrics WHERE sg_event_id = v_sg_event_id
      ORDER BY captured_at DESC LIMIT 25
    )
    SELECT jsonb_build_object(
      'sg_event_id', v_sg_event_id,
      'current',  (SELECT to_jsonb(e) FROM em_latest e WHERE rn = 1),
      'd24h_ago', (SELECT to_jsonb(e) FROM em_latest e WHERE e.captured_at <= now() - interval '24 hours' ORDER BY e.captured_at DESC LIMIT 1)
    ) INTO v_sg_sxs;
  ELSE
    v_sg_sxs := jsonb_build_object('hidden', true, 'reason', 'no_sg_bridge');
  END IF;

  -- splits (unchanged)
  WITH latest_per_tg AS (
    SELECT DISTINCT ON (tevo_ticket_group_id) quantity, is_owned, retail_price, brokerage_id
    FROM public.listings_snapshots
    WHERE event_id = p_event_id AND captured_at > now() - interval '24 hours'
    ORDER BY tevo_ticket_group_id, captured_at DESC
  ),
  bucketed AS (
    SELECT CASE WHEN is_owned AND brokerage_id = 1768 THEN 'owned' ELSE 'market' END AS src,
      CASE WHEN quantity = 1 THEN 'singles' WHEN quantity = 2 THEN 'pairs' WHEN quantity = 3 THEN 'triples' WHEN quantity = 4 THEN 'quads' ELSE 'five_plus' END AS bucket,
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

  -- Freshness (unchanged)
  SELECT max(captured_at) INTO v_max_tevo FROM public.listings_snapshots WHERE event_id = p_event_id;
  IF v_sg_event_id IS NOT NULL THEN
    SELECT max(captured_at) INTO v_max_sg_lst FROM public.seatgeek_listings_snapshots WHERE sg_event_id = v_sg_event_id;
    SELECT max(sale_at_utc) INTO v_max_sg_sales FROM public.seatgeek_sales_snapshots WHERE sg_event_id = v_sg_event_id;
  END IF;
  IF v_venue_tevo_id IS NOT NULL THEN
    SELECT max(observed_at) INTO v_max_weather FROM public.weather_observations WHERE tevo_venue_id = v_venue_tevo_id AND is_forecast = false;
    IF v_max_weather IS NULL THEN
      SELECT max(observed_at) INTO v_max_weather FROM public.weather_observations WHERE tevo_venue_id = v_venue_tevo_id AND is_forecast = true;
    END IF;
  END IF;
  IF v_espn_event_id IS NOT NULL THEN
    SELECT max(captured_at) INTO v_max_espn_team FROM public.espn_team_snapshots WHERE espn_league = v_espn_league AND espn_team_id = ANY(ARRAY[v_home_team_id, v_away_team_id]);
    SELECT max(last_seen_at) INTO v_max_espn_inj FROM public.espn_injuries_snapshots WHERE espn_league = v_espn_league AND espn_team_id = ANY(ARRAY[v_home_team_id, v_away_team_id]);
  END IF;
  SELECT max(sale_timestamp) INTO v_max_sd_sales FROM public.sd_sales_normalized WHERE tevo_event_id = p_event_id;

  v_freshness := jsonb_build_object(
    'tevo_listings_latest', v_max_tevo, 'sg_listings_latest', v_max_sg_lst,
    'sg_sales_latest', v_max_sg_sales, 'weather_latest', v_max_weather,
    'espn_team_latest', v_max_espn_team, 'espn_inj_latest', v_max_espn_inj,
    'sd_sales_latest', v_max_sd_sales, 'computed_at', v_now
  );

  RETURN v_base || jsonb_build_object(
    'v', 'v2',
    'bridge_ids', jsonb_build_object(
      'tevo_event_id', p_event_id, 'sg_event_id', v_sg_event_id, 'aq_short_event_id', v_aq_id,
      'espn_event_id', v_espn_event_id, 'espn_league', v_espn_league, 'venue_tevo_id', v_venue_tevo_id
    ),
    'sales_tape', v_sales_tape, 'weather', v_weather, 'espn', v_espn, 'event_alerts', v_event_alerts,
    'sg_side_by_side', v_sg_sxs, 'splits', v_splits, 'freshness', v_freshness
  );
END $function$;
