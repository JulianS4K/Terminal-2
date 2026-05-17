-- Migration 20260517010000 · lane:D0 (author) → A1 (apply) · writes:get_broker_event_page_v3 RPC · reads:performer_metadata,entity_performer_map,v_event_velocity_windows,v_sg_broker_sales_by_event,event_competitors_snapshot,seatgeek_event_metrics,section_metrics,tickpick_orders,vivid_orders,listings_snapshots,espn_event_date_lookup · pre:20260516050000 · auth:operator-approved 2026-05-17 ("good add all of them")
--
-- D0 Phase 2a enrichment batch — 9 new payload keys on top of v2.
-- Operator request 2026-05-17 after Knicks-G2 audit (event 3346001):
-- "what data are you seeing here on an event level and what information
-- that's mapped isn't included" — 10 enrichment opportunities surfaced;
-- 9 had existing tables/views (this PR); 1 (v_event_context_* holiday/
-- rivalry/mlb_series views) MISSING — deferred separately.
--
-- Design: v3 calls v2 to get base payload then merges 9 new keys via `||`.
-- v2 stays untouched (rollback-safe).
--
-- 9 NEW PAYLOAD KEYS:
--   performer            — logo + brand color + ESPN league/team_id
--   velocity             — TEvo + SG tix/getin Δ1h Δ24h Δ24h%
--   sg_broker_sales      — aggregate from v_sg_broker_sales_by_event
--   sg_listings_summary  — latest seatgeek_event_metrics row (cost_*)
--   competing_events     — expanded from event_competitors_snapshot.competitors jsonb
--   cross_source_orders  — TickPick + Vivid orders for this event
--   recent_listings      — last 10 TEvo listings_snapshots (firehose snippet)
--   zone_deltas          — per-zone price/qty Δ24h from section_metrics
--   performer_espn_context — performer's next 5 ESPN games (for events with no ESPN xref)
--
-- All 9 hide gracefully when no data: keys present in payload but value is
-- `{"hidden":true,"reason":"..."}` or `[]` — never null at top level so the
-- FE can dispatch deterministically.
--
-- Verified-correct table/view shapes per schema probe 2026-05-17 00:30 UTC.
--
-- Performance: each enrichment is one indexed lookup; total RPC budget
-- estimated ~250ms typical (v2 was 185ms; 9 quick queries add ~65ms).
--
-- ## Pending operator apply via apply_migration

CREATE OR REPLACE FUNCTION public.get_broker_event_page_v3(
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
  -- 1. Email gate (same as v2)
  v_email := coalesce(auth.jwt()->>'email', '');
  IF v_email NOT LIKE '%@s4kent.com' THEN
    RAISE EXCEPTION 'forbidden: % is not an @s4kent.com email', v_email USING ERRCODE = '42501';
  END IF;

  -- 2. Base payload from v2 (includes bridge_ids, overview, chart_data,
  --    zones, orders, cadences, sales_tape, weather, espn, event_alerts,
  --    sg_side_by_side, splits, freshness)
  v_base := public.get_broker_event_page_v2(p_event_id, p_chart_hours);

  -- 3. Pull bridge IDs from base for our enrichment lookups
  v_sg_event_id    := nullif(v_base->'bridge_ids'->>'sg_event_id', '')::bigint;
  v_espn_event_id  := nullif(v_base->'bridge_ids'->>'espn_event_id', '');
  v_espn_league    := nullif(v_base->'bridge_ids'->>'espn_league', '');

  -- 4. Resolve performer id from events table for performer enrichment
  SELECT primary_performer_id INTO v_tevo_performer_id
  FROM public.events WHERE id = p_event_id LIMIT 1;

  -- ============================================================
  -- 5. performer — logo + brand + ESPN league badge
  -- ============================================================
  IF v_tevo_performer_id IS NOT NULL THEN
    SELECT to_jsonb(p) INTO v_performer
    FROM (
      SELECT
        pm.performer_id        AS tevo_performer_id,
        pm.name,
        pm.logo_default_url,
        pm.logo_dark_url,
        pm.logo_4k_primary_url,
        pm.color_primary,
        pm.color_alternate,
        pm.espn_league,
        pm.espn_team_id,
        pm.what_event_type,
        pm.popularity_score,
        em.genre,
        em.top_category_name
      FROM public.performer_metadata pm
      LEFT JOIN public.entity_performer_map em
        ON em.tevo_performer_id = pm.performer_id
      WHERE pm.performer_id = v_tevo_performer_id
      LIMIT 1
    ) p;
    IF v_performer IS NOT NULL THEN
      v_espn_team_id := v_performer->>'espn_team_id';
      IF v_espn_league IS NULL THEN
        v_espn_league := v_performer->>'espn_league';
      END IF;
    END IF;
  END IF;
  IF v_performer IS NULL THEN
    v_performer := jsonb_build_object('hidden', true, 'reason', 'no_performer_id');
  END IF;

  -- ============================================================
  -- 6. velocity — TEvo + SG tix/getin Δ
  -- ============================================================
  SELECT to_jsonb(v) INTO v_velocity
  FROM (
    SELECT
      tevo_event_id, tevo_now_at,
      tevo_tix_now, tevo_tix_d1h, tevo_tix_d24h,
      tevo_getin_now, tevo_getin_d1h, tevo_getin_d6h, tevo_getin_d24h,
      tevo_getin_d1h_pct, tevo_getin_d24h_pct,
      tevo_median_now,
      sg_now_at, sg_tix_now, sg_getin_now, sg_median_now,
      sg_getin_d1h, sg_getin_d24h
    FROM public.v_event_velocity_windows
    WHERE tevo_event_id = p_event_id
    LIMIT 1
  ) v;
  IF v_velocity IS NULL THEN
    v_velocity := jsonb_build_object('hidden', true, 'reason', 'no_velocity_row');
  END IF;

  -- ============================================================
  -- 7. sg_broker_sales — aggregate from new view (A1 shipped 2026-05-16)
  -- ============================================================
  IF v_sg_event_id IS NOT NULL THEN
    SELECT to_jsonb(s) INTO v_sg_broker_sales
    FROM (
      SELECT
        sg_event_id, sg_event_name, sg_event_date,
        sales_count, tickets_sold, gross_estimate,
        min_sale_price, median_sale_price, max_sale_price,
        distinct_sections, latest_sale_at
      FROM public.v_sg_broker_sales_by_event
      WHERE tevo_event_id = p_event_id OR sg_event_id = v_sg_event_id
      LIMIT 1
    ) s;
  END IF;
  IF v_sg_broker_sales IS NULL THEN
    v_sg_broker_sales := jsonb_build_object('hidden', true, 'reason',
      CASE WHEN v_sg_event_id IS NULL THEN 'no_sg_bridge' ELSE 'no_broker_sales_row' END);
  END IF;

  -- ============================================================
  -- 8. sg_listings_summary — latest seatgeek_event_metrics row (richer than sg_side_by_side)
  -- ============================================================
  IF v_sg_event_id IS NOT NULL THEN
    SELECT to_jsonb(m) INTO v_sg_listings_summary
    FROM (
      SELECT captured_at, listings_count, tickets_count,
             cost_min, cost_p25, cost_median, cost_p75, cost_p90, cost_max,
             cost_mean, fill_rate, unique_sections, unique_rows,
             edelivery_share, instant_share
      FROM public.seatgeek_event_metrics
      WHERE sg_event_id = v_sg_event_id
      ORDER BY captured_at DESC LIMIT 1
    ) m;
  END IF;
  IF v_sg_listings_summary IS NULL THEN
    v_sg_listings_summary := jsonb_build_object('hidden', true, 'reason',
      CASE WHEN v_sg_event_id IS NULL THEN 'no_sg_bridge' ELSE 'no_sg_metrics_row' END);
  END IF;

  -- ============================================================
  -- 9. competing_events — expand event_competitors_snapshot.competitors jsonb
  -- ============================================================
  SELECT
    jsonb_build_object(
      'count', competitors_count,
      'refreshed_at', refreshed_at,
      'events', coalesce(competitors, '[]'::jsonb)
    )
  INTO v_competing_events
  FROM public.event_competitors_snapshot
  WHERE tevo_event_id = p_event_id
  LIMIT 1;
  IF v_competing_events IS NULL THEN
    v_competing_events := jsonb_build_object('count', 0, 'events', '[]'::jsonb);
  END IF;

  -- ============================================================
  -- 10. cross_source_orders — TickPick + Vivid for this event
  -- ============================================================
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

  -- ============================================================
  -- 11. recent_listings — last 10 TEvo listings_snapshots (situational awareness)
  -- ============================================================
  SELECT coalesce(jsonb_agg(to_jsonb(l) ORDER BY l.captured_at DESC), '[]'::jsonb)
  INTO v_recent_listings
  FROM (
    SELECT DISTINCT ON (tevo_ticket_group_id)
      tevo_ticket_group_id, captured_at, section, row, quantity,
      retail_price, format, is_owned, brokerage_name
    FROM public.listings_snapshots
    WHERE event_id = p_event_id
      AND captured_at > now() - interval '24 hours'
    ORDER BY tevo_ticket_group_id, captured_at DESC
    LIMIT 10
  ) l;

  -- ============================================================
  -- 12. zone_deltas — per-zone price/qty Δ24h from section_metrics
  -- ============================================================
  -- Two snapshots per zone (latest + 24h-ago), compute deltas
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
    'zone', l.zone,
    'cur_median', l.retail_median,
    'cur_tix', l.tickets_count,
    'cur_owned_tix', l.owned_tickets_count,
    'prior_median', p.prior_median,
    'prior_tix', p.prior_tix,
    'delta_median_pct',
      CASE WHEN p.prior_median IS NULL OR p.prior_median = 0 THEN NULL
           ELSE round(((l.retail_median - p.prior_median) / p.prior_median * 100)::numeric, 2) END,
    'delta_tix_abs',
      CASE WHEN p.prior_tix IS NULL THEN NULL
           ELSE l.tickets_count - p.prior_tix END,
    'latest_at', l.captured_at,
    'prior_at', p.prior_at
  ) ORDER BY l.tickets_count DESC NULLS LAST), '[]'::jsonb)
  INTO v_zone_deltas
  FROM latest l LEFT JOIN prior p ON p.zone = l.zone;

  -- ============================================================
  -- 13. performer_espn_context — next 5 ESPN games for this performer
  --     (useful when THIS event has no ESPN xref but performer does)
  -- ============================================================
  IF v_espn_team_id IS NOT NULL AND v_espn_league IS NOT NULL THEN
    SELECT coalesce(jsonb_agg(jsonb_build_object(
      'espn_event_id', espn_event_id,
      'game_at_utc', game_at_utc,
      'home_team_id', home_team_id,
      'away_team_id', away_team_id,
      'status_short', status_short,
      'is_home', home_team_id = v_espn_team_id
    ) ORDER BY game_at_utc), '[]'::jsonb)
    INTO v_performer_espn
    FROM (
      SELECT * FROM public.espn_event_date_lookup
      WHERE espn_league = v_espn_league
        AND (home_team_id = v_espn_team_id OR away_team_id = v_espn_team_id)
        AND game_at_utc > now() - interval '1 day'
      ORDER BY game_at_utc
      LIMIT 5
    ) g;
  END IF;
  IF v_performer_espn IS NULL THEN
    v_performer_espn := jsonb_build_object('hidden', true, 'reason',
      CASE WHEN v_espn_team_id IS NULL THEN 'no_performer_espn_xref'
           ELSE 'no_upcoming_games' END);
  END IF;

  -- ============================================================
  -- 14. Merge new keys onto v2 base
  -- ============================================================
  RETURN v_base || jsonb_build_object(
    'v', 'v3',
    'performer',             v_performer,
    'velocity',              v_velocity,
    'sg_broker_sales',       v_sg_broker_sales,
    'sg_listings_summary',   v_sg_listings_summary,
    'competing_events',      v_competing_events,
    'cross_source_orders',   v_cross_source_orders,
    'recent_listings',       v_recent_listings,
    'zone_deltas',           v_zone_deltas,
    'performer_espn_context', v_performer_espn
  );
END $func$;

REVOKE ALL ON FUNCTION public.get_broker_event_page_v3(integer, integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_broker_event_page_v3(integer, integer) TO anon, authenticated;

COMMENT ON FUNCTION public.get_broker_event_page_v3(integer, integer) IS
  'D0 Phase 2a v3 — extends v2 with 9 enrichment keys: performer, velocity, sg_broker_sales, sg_listings_summary, competing_events, cross_source_orders, recent_listings, zone_deltas, performer_espn_context. Email-gated to @s4kent.com. v_event_context_* views (holiday/rivalry/mlb_series) deferred — sources missing.';
