-- Migration 20260516050000 · admin · Phase 2a — get_broker_event_page_v2 RPC · pre:20260516040000
--
-- D0's Phase 2a Event Detail expansion per docs/event-view-wireframe-v4.md §3-§6
-- and D0's plan addendum 5 Section E.9 Step 1. Extends v1 (20260515310000) with
-- 7 new payload keys + bridge_ids summary:
--
--   sales_tape         — last 20 SG sales (DISTINCT ON sg_sale_id; 11× dedup factor)
--   weather            — forecast nearest event_at + recent obs + active NWS alerts
--   espn               — home/away team standings + injuries + recent results (gated)
--   event_alerts       — chart markers (ORDER BY fired_at DESC)
--   sg_side_by_side    — SG aggregates parallel to TEvo KPI (NULL = TEvo-only state)
--   splits             — singles/pairs/3+/4+/5+ density (owned vs market)
--   freshness          — per-source MAX captured_at (never from dead xref columns)
--
-- Design: v2 calls v1 to get base payload then merges 7 new keys via `||`.
-- v1 stays untouched (rollback-safe).
--
-- Schema deltas caught during drafting (3 corrections beyond plan E.14):
--   event_alerts.tevo_event_id     (NOT event_id)
--   nws_alerts.expires_at          (NOT expires)
--   seatgeek_event_metrics.cost_*  (NOT retail_*)
--   sd_sales_normalized.sale_timestamp + tevo_event_id  (NOT observed_at + aq_short_event_id)
--
-- Performance: 185ms execution measured on Bruno Mars (richest payload). 7.5× faster
-- than the v1 Python orchestration which averaged ~1.4s. Requires the SG sg_event_id
-- indexes shipped in 20260516060000 (otherwise SG branches seq-scan 1-10M rows).
--
-- Verified 2026-05-16 on 5 spot-check events:
--   MLB Yankees-Jays 5/18: 20 sales · 6 forecast points · ESPN linked w/ 44 injuries
--   NBA Lakers G6 CANCELLED: 20 sales · weather hidden (indoor) · ESPN linked w/ 6 injuries
--   Bruno Mars Soldier Field: 20 sales · 6 forecast points · no ESPN · 154 market pairs / 1 owned
--   MMA Intuit Dome: 20 sales · weather hidden (indoor) · no ESPN · 36 market pairs
--   MLS Charlotte FC: 20 sales · 6 forecast points · ESPN linked · 63 market / 25 owned pairs
--
-- Graceful degradation observed: events with stale TEvo data (Yankees+Lakers — last
-- capture 5/12-5/14 due to broken collect-listings-1-7d cron, separate B1 task) show
-- splits=null because 24h window has no rows. Expected; D0 renders "no recent TEvo data".
--
-- ## Already applied to prod  Applied via MCP 2026-05-16.

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
  -- 1. Email gate
  v_email := coalesce(auth.jwt()->>'email', '');
  IF v_email NOT LIKE '%@s4kent.com' THEN
    RAISE EXCEPTION 'forbidden: % is not an @s4kent.com email', v_email USING ERRCODE = '42501';
  END IF;

  -- 2. Base payload from v1
  v_base := public.get_broker_event_page(p_event_id, p_chart_hours);

  -- 3. Bridge IDs from _v_d0_event_index
  SELECT v.sg_event_id, v.aq_short_event_id, v.espn_event_id, v.espn_league,
         v.venue_tevo_id, v.is_indoor, v.event_at_utc
  INTO v_sg_event_id, v_aq_id, v_espn_event_id, v_espn_league,
       v_venue_tevo_id, v_is_indoor, v_event_at
  FROM public._v_d0_event_index v
  WHERE v.tevo_event_id = p_event_id LIMIT 1;

  -- Fall back to events table when no _v_d0 row (event >6h past or not in priority_state)
  IF v_event_at IS NULL THEN
    SELECT CASE WHEN e.occurs_at_local ~ '^\d{4}-\d{2}-\d{2}'
                THEN e.occurs_at_local::timestamptz ELSE NULL END,
           e.venue_id
    INTO v_event_at, v_venue_tevo_id
    FROM public.events e WHERE e.id = p_event_id LIMIT 1;
  END IF;

  -- 4. sales_tape (deduped on sg_sale_id)
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

  -- 5. weather (hide when indoor / no geo / no event time)
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
      FROM public.nws_alerts
      WHERE expires_at > now()
      ORDER BY expires_at LIMIT 5
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

  -- 6. ESPN (gated on espn_event_id present)
  IF v_espn_event_id IS NOT NULL THEN
    SELECT home_team_id, away_team_id INTO v_home_team_id, v_away_team_id
    FROM public.espn_event_snapshots
    WHERE espn_event_id = v_espn_event_id
    ORDER BY captured_at DESC LIMIT 1;

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

  -- 7. event_alerts
  SELECT coalesce(jsonb_agg(to_jsonb(a) ORDER BY a.fired_at DESC), '[]'::jsonb)
  INTO v_event_alerts
  FROM (
    SELECT id, rule_key, fired_at, severity, message, payload, acknowledged_at
    FROM public.event_alerts
    WHERE tevo_event_id = p_event_id
      AND fired_at > now() - make_interval(hours => greatest(1, least(coalesce(p_chart_hours, 720), 4320)))
    ORDER BY fired_at DESC LIMIT 50
  ) a;

  -- 8. sg_side_by_side
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

  -- 9. splits
  WITH latest_per_tg AS (
    SELECT DISTINCT ON (tevo_ticket_group_id)
      quantity, is_owned, retail_price, brokerage_id
    FROM public.listings_snapshots
    WHERE event_id = p_event_id
      AND captured_at > now() - interval '24 hours'
    ORDER BY tevo_ticket_group_id, captured_at DESC
  ),
  bucketed AS (
    SELECT
      CASE WHEN is_owned AND brokerage_id = 1768 THEN 'owned' ELSE 'market' END AS src,
      CASE WHEN quantity = 1 THEN 'singles'
           WHEN quantity = 2 THEN 'pairs'
           WHEN quantity = 3 THEN 'triples'
           WHEN quantity = 4 THEN 'quads'
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

  -- 10. Freshness
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

  -- 11. Merge new keys onto v1 base
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

REVOKE ALL ON FUNCTION public.get_broker_event_page_v2(integer, integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_broker_event_page_v2(integer, integer) TO anon, authenticated;

COMMENT ON FUNCTION public.get_broker_event_page_v2(integer, integer) IS
  'D0 Phase 2a Event Detail RPC. Extends v1 with sales_tape (SG, deduped on sg_sale_id), weather (forecast+obs+NWS, hidden when indoor), espn (standings+injuries+recent_results, gated on espn xref), event_alerts (chart markers), sg_side_by_side (NULL when no SG bridge), splits (owned vs market density), freshness (per-source MAX captured_at). Email-gated to @s4kent.com. 185ms typical execution.';
