-- A1 PR-4a (part 5 of 5) — v3 RPC sg_listings_summary cost_* → listings_all_* + listings_owned_*

CREATE OR REPLACE FUNCTION public.get_broker_event_page_v3(p_event_id integer, p_chart_hours integer DEFAULT 720)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
DECLARE
  v_email                text;
  v_base                 jsonb;
  v_now                  timestamptz := now();
  v_sg_event_id          bigint;
  v_espn_event_id        text;
  v_espn_team_id         text;
  v_espn_league          text;
  v_tevo_performer_id    bigint;
  v_performer            jsonb;
  v_velocity             jsonb;
  v_sg_broker_sales      jsonb;
  v_sg_listings_summary  jsonb;
  v_competing_events     jsonb;
  v_cross_source_orders  jsonb;
  v_recent_listings      jsonb;
  v_zone_deltas          jsonb;
  v_performer_espn       jsonb;
BEGIN
  v_email := coalesce(auth.jwt()->>'email', '');
  IF v_email NOT LIKE '%@s4kent.com' THEN
    RAISE EXCEPTION 'forbidden: % is not an @s4kent.com email', v_email USING ERRCODE = '42501';
  END IF;

  v_base := public.get_broker_event_page_v2(p_event_id, p_chart_hours);
  v_sg_event_id    := nullif(v_base->'bridge_ids'->>'sg_event_id', '')::bigint;
  v_espn_event_id  := nullif(v_base->'bridge_ids'->>'espn_event_id', '');
  v_espn_league    := nullif(v_base->'bridge_ids'->>'espn_league', '');

  SELECT primary_performer_id INTO v_tevo_performer_id
  FROM public.events WHERE id = p_event_id LIMIT 1;

  IF v_tevo_performer_id IS NOT NULL THEN
    SELECT to_jsonb(p) INTO v_performer FROM (
      SELECT pm.performer_id AS tevo_performer_id, pm.name,
        pm.logo_default_url, pm.logo_dark_url, pm.logo_4k_primary_url,
        pm.color_primary, pm.color_alternate, pm.espn_league, pm.espn_team_id,
        pm.what_event_type, pm.popularity_score, em.genre, em.top_category_name
      FROM public.performer_metadata pm
      LEFT JOIN public.entity_performer_map em ON em.tevo_performer_id = pm.performer_id
      WHERE pm.performer_id = v_tevo_performer_id LIMIT 1
    ) p;
    IF v_performer IS NOT NULL THEN
      v_espn_team_id := v_performer->>'espn_team_id';
      IF v_espn_league IS NULL THEN v_espn_league := v_performer->>'espn_league'; END IF;
    END IF;
  END IF;
  IF v_performer IS NULL THEN v_performer := jsonb_build_object('hidden', true, 'reason', 'no_performer_id'); END IF;

  SELECT to_jsonb(v) INTO v_velocity FROM (
    SELECT tevo_event_id, tevo_now_at, tevo_tix_now, tevo_tix_d1h, tevo_tix_d24h,
      tevo_getin_now, tevo_getin_d1h, tevo_getin_d6h, tevo_getin_d24h,
      tevo_getin_d1h_pct, tevo_getin_d24h_pct, tevo_median_now,
      sg_now_at, sg_tix_now, sg_getin_now, sg_median_now, sg_getin_d1h, sg_getin_d24h
    FROM public.v_event_velocity_windows WHERE tevo_event_id = p_event_id LIMIT 1
  ) v;
  IF v_velocity IS NULL THEN v_velocity := jsonb_build_object('hidden', true, 'reason', 'no_velocity_row'); END IF;

  IF v_sg_event_id IS NOT NULL THEN
    WITH dedup AS (
      SELECT DISTINCT ON (sg_sale_id)
        sg_sale_id, quantity, broadcast_price, section, sale_at_utc
      FROM public.seatgeek_sales_snapshots
      WHERE sg_event_id = v_sg_event_id AND section IS NOT NULL
      ORDER BY sg_sale_id, pulled_at DESC
    ),
    agg AS (
      SELECT count(*) AS sales_count,
             sum(quantity)::bigint AS tickets_sold,
             sum(broadcast_price * COALESCE(quantity, 1)::numeric) AS gross_estimate,
             min(broadcast_price) AS min_sale_price,
             round(percentile_cont(0.5) WITHIN GROUP (ORDER BY broadcast_price::double precision)::numeric, 2) AS median_sale_price,
             max(broadcast_price) AS max_sale_price,
             count(DISTINCT section) AS distinct_sections,
             max(sale_at_utc) AS latest_sale_at
      FROM dedup
    )
    SELECT to_jsonb(s) INTO v_sg_broker_sales FROM (
      SELECT v_sg_event_id AS sg_event_id, sgc.sg_event_name, sgc.sg_event_date,
        a.sales_count, a.tickets_sold, a.gross_estimate, a.min_sale_price,
        a.median_sale_price, a.max_sale_price, a.distinct_sections, a.latest_sale_at
      FROM agg a LEFT JOIN public.sg_events_canonical sgc ON sgc.sg_event_id = v_sg_event_id
      WHERE a.sales_count > 0 LIMIT 1
    ) s;
  END IF;
  IF v_sg_broker_sales IS NULL THEN
    v_sg_broker_sales := jsonb_build_object('hidden', true, 'reason',
      CASE WHEN v_sg_event_id IS NULL THEN 'no_sg_bridge' ELSE 'no_broker_sales_row' END);
  END IF;

  -- sg_listings_summary — A1 2026-05-18 PR-4a: cost_* swap → listings_all_* + listings_owned_*
  IF v_sg_event_id IS NOT NULL THEN
    SELECT to_jsonb(m) INTO v_sg_listings_summary FROM (
      SELECT captured_at,
        listings_all_count, listings_all_tickets,
        listings_all_min, listings_all_p25, listings_all_median, listings_all_mean,
        listings_all_p75, listings_all_p90, listings_all_max,
        listings_owned_count, listings_owned_tickets,
        listings_owned_min, listings_owned_p25, listings_owned_median, listings_owned_mean,
        listings_owned_p75, listings_owned_p90, listings_owned_max,
        fill_rate, unique_sections, unique_rows, edelivery_share, instant_share
      FROM public.seatgeek_event_metrics
      WHERE sg_event_id = v_sg_event_id
      ORDER BY captured_at DESC LIMIT 1
    ) m;
  END IF;
  IF v_sg_listings_summary IS NULL THEN
    v_sg_listings_summary := jsonb_build_object('hidden', true, 'reason',
      CASE WHEN v_sg_event_id IS NULL THEN 'no_sg_bridge' ELSE 'no_sg_metrics_row' END);
  END IF;

  SELECT jsonb_build_object(
    'count', competitors_count, 'refreshed_at', refreshed_at,
    'events', coalesce(competitors, '[]'::jsonb)
  ) INTO v_competing_events
  FROM public.event_competitors_snapshot WHERE tevo_event_id = p_event_id LIMIT 1;
  IF v_competing_events IS NULL THEN v_competing_events := jsonb_build_object('count', 0, 'events', '[]'::jsonb); END IF;

  SELECT jsonb_build_object(
    'tickpick', coalesce((
      SELECT jsonb_agg(jsonb_build_object(
        'tp_order_id', tp_order_id, 'status', status, 'quantity', quantity,
        'total', total, 'section', section, 'row', row, 'ordered_at', ordered_at
      ) ORDER BY ordered_at DESC NULLS LAST)
      FROM public.tickpick_orders WHERE tevo_event_id = p_event_id LIMIT 50
    ), '[]'::jsonb),
    'vivid', coalesce((
      SELECT jsonb_agg(jsonb_build_object(
        'vivid_order_id', vivid_order_id, 'status', status, 'quantity', quantity,
        'total', total, 'section', section, 'row', row, 'ordered_at', ordered_at
      ) ORDER BY ordered_at DESC NULLS LAST)
      FROM public.vivid_orders WHERE tevo_event_id = p_event_id LIMIT 50
    ), '[]'::jsonb)
  ) INTO v_cross_source_orders;

  SELECT coalesce(jsonb_agg(to_jsonb(l) ORDER BY l.captured_at DESC), '[]'::jsonb)
  INTO v_recent_listings FROM (
    SELECT DISTINCT ON (tevo_ticket_group_id)
      tevo_ticket_group_id, captured_at, section, row, quantity,
      retail_price, format, is_owned, brokerage_name
    FROM public.listings_snapshots
    WHERE event_id = p_event_id AND captured_at > now() - interval '24 hours'
    ORDER BY tevo_ticket_group_id, captured_at DESC LIMIT 10
  ) l;

  WITH latest AS (
    SELECT DISTINCT ON (zone) zone, retail_median, tickets_count, owned_tickets_count, captured_at
    FROM public.section_metrics
    WHERE event_id = p_event_id AND zone IS NOT NULL
    ORDER BY zone, captured_at DESC
  ),
  prior AS (
    SELECT DISTINCT ON (zone) zone, retail_median AS prior_median, tickets_count AS prior_tix, captured_at AS prior_at
    FROM public.section_metrics
    WHERE event_id = p_event_id AND zone IS NOT NULL
      AND captured_at <= now() - interval '24 hours'
    ORDER BY zone, captured_at DESC
  )
  SELECT coalesce(jsonb_agg(jsonb_build_object(
    'zone', l.zone, 'cur_median', l.retail_median, 'cur_tix', l.tickets_count,
    'cur_owned_tix', l.owned_tickets_count,
    'prior_median', p.prior_median, 'prior_tix', p.prior_tix,
    'delta_median_pct',
      CASE WHEN p.prior_median IS NULL OR p.prior_median = 0 THEN NULL
           ELSE round(((l.retail_median - p.prior_median) / p.prior_median * 100)::numeric, 2) END,
    'delta_tix_abs',
      CASE WHEN p.prior_tix IS NULL THEN NULL ELSE l.tickets_count - p.prior_tix END,
    'latest_at', l.captured_at, 'prior_at', p.prior_at
  ) ORDER BY l.tickets_count DESC NULLS LAST), '[]'::jsonb)
  INTO v_zone_deltas
  FROM latest l LEFT JOIN prior p ON p.zone = l.zone;

  IF v_espn_team_id IS NOT NULL AND v_espn_league IS NOT NULL THEN
    SELECT coalesce(jsonb_agg(jsonb_build_object(
      'espn_event_id', espn_event_id, 'game_at_utc', game_at_utc,
      'home_team_id', home_team_id, 'away_team_id', away_team_id,
      'status_short', status_short,
      'is_home', home_team_id = v_espn_team_id
    ) ORDER BY game_at_utc), '[]'::jsonb)
    INTO v_performer_espn FROM (
      SELECT * FROM public.espn_event_date_lookup
      WHERE espn_league = v_espn_league
        AND (home_team_id = v_espn_team_id OR away_team_id = v_espn_team_id)
        AND game_at_utc > now() - interval '1 day'
      ORDER BY game_at_utc LIMIT 5
    ) g;
  END IF;
  IF v_performer_espn IS NULL THEN
    v_performer_espn := jsonb_build_object('hidden', true, 'reason',
      CASE WHEN v_espn_team_id IS NULL THEN 'no_performer_espn_xref' ELSE 'no_upcoming_games' END);
  END IF;

  RETURN v_base || jsonb_build_object(
    'v', 'v3',
    'performer', v_performer,
    'velocity', v_velocity,
    'sg_broker_sales', v_sg_broker_sales,
    'sg_listings_summary', v_sg_listings_summary,
    'competing_events', v_competing_events,
    'cross_source_orders', v_cross_source_orders,
    'recent_listings', v_recent_listings,
    'zone_deltas', v_zone_deltas,
    'performer_espn_context', v_performer_espn
  );
END $function$;
