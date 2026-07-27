-- Migration 20260515310000 · level:admin · lane:Audit/Push · writes:get_broker_event_page() fn · pre:20260515300000
--
-- D0's Path C — Event Detail Page MVP build.
-- D0 forwarded "Event Detail Page — MVP Build Plan" (3 addendums) locking
-- direct Supabase RPC consumption from the static-site terminal frontend
-- (vibepass-terminal-test). Replaces the FastAPI app.py endpoints for this
-- page only; the rest of the broker UI keeps consuming Python.
--
-- Single RPC that flattens 5 broker event-detail endpoints into one JSONB:
--   /api/broker/event/{id}/overview     → overview key
--   /api/broker/event/{id}/chart-data   → chart_data key
--   /api/broker/event/{id}/zones        → zones key
--   /api/broker/event/{id}/orders       → orders key
--   /api/broker/event/{id}/cadences     → cadences key
--
-- AUTH: auth.jwt()->>'email' LIKE '%@s4kent.com'
-- (mirrors the FastAPI require_auth() check in app.py:auth_dependencies)
-- D0's terminal uses Supabase JS client + magic-link, so the JWT email
-- comes through naturally.
--
-- SECURITY DEFINER so the anon role on the static CDN can call this — the
-- function body's own email gate prevents non-S4K JWTs from getting data.
-- search_path locked to public+extensions+pg_temp per §6 SECDEF convention.
--
-- COMPOSES existing SECDEF helpers (no duplication):
--   public.get_broker_event_detail(p_event_id)    -- event header (per-source xref-rich payload)
--   public.get_event_zones_rollup(event,owned)    -- owned + market zone rollups
--   public.derive_event_lifecycle(p_event_id)     -- ghost/postponed/completed classifier
--
-- DESIGN NOTE: Python endpoints in app.py:1700-3260 do significant Python
-- post-processing (delta computation, forward-fill, normalization, weighted
-- composites for team_index). This RPC returns RAW rows + minimal shaping;
-- D0 frontend reproduces the compute in JS. Path of least resistance to
-- MVP; keeps SQL stable as Python evolves.
--
-- DEFERRED for v2 (not on MVP critical path):
--   - ESPN standings time series, injury overlays, roster moves
--   - Last-5 records, news velocity, composite team_index
--   - Per-zone time series (frontend can derive from event_metrics + zone_metrics)
--
-- See app.py:1725-1835 (/overview), 2558-3015 (/chart-data),
-- 1936-2009 (/zones), 3619-3665 (/orders), 3216-3254 (/cadences) for the
-- shapes this mirrors.

CREATE OR REPLACE FUNCTION public.get_broker_event_page(
  p_event_id    integer,
  p_chart_hours integer DEFAULT 720    -- 30 days; capped to [1, 4320] internally
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, extensions, pg_temp
AS $func$
DECLARE
  v_email           text;
  v_since           timestamptz;
  v_now             timestamptz := now();
  v_chart_hours     integer;
  v_event           jsonb;
  v_lifecycle       jsonb;
  v_occurs_at_local timestamptz;
  v_listings_cad    integer;
  v_metrics_curr    jsonb;
  v_metrics_prev    jsonb;
  v_zones_rollup    jsonb;
  v_zones_detail    jsonb;
  v_chart_em        jsonb;
  v_chart_zm        jsonb;
  v_orders_payload  jsonb;
  v_last_em         timestamptz;
  v_last_inj        timestamptz;
  v_last_team_snap  timestamptz;
BEGIN
  ----------------------------------------------------------------------
  -- 1. Email gate (mirrors app.py require_auth)
  ----------------------------------------------------------------------
  v_email := coalesce(auth.jwt()->>'email', '');
  IF v_email NOT LIKE '%@s4kent.com' THEN
    RAISE EXCEPTION 'forbidden: % is not an @s4kent.com email', v_email
      USING ERRCODE = '42501';
  END IF;

  -- Clamp chart window to sane bounds: 1h .. 180d
  v_chart_hours := greatest(1, least(coalesce(p_chart_hours, 720), 4320));
  v_since := v_now - make_interval(hours => v_chart_hours);

  ----------------------------------------------------------------------
  -- 2. Event header — reuse get_broker_event_detail SECDEF helper
  ----------------------------------------------------------------------
  SELECT to_jsonb(d) INTO v_event
  FROM public.get_broker_event_detail(p_event_id) d
  LIMIT 1;

  IF v_event IS NULL THEN
    RAISE EXCEPTION 'event % not found in get_broker_event_detail', p_event_id
      USING ERRCODE = 'P0002';
  END IF;

  v_occurs_at_local := nullif(v_event->>'occurs_at_local','')::timestamptz;

  -- Listings cadence — mirrors _listings_cadence_seconds() in app.py:1693-1706
  -- 6h to event: 60s · 24h: 5min · 7d: 30min · 30d: 4h · 60d: 12h · else: 24h
  v_listings_cad := CASE
    WHEN v_occurs_at_local IS NULL                                THEN 24*3600
    WHEN v_occurs_at_local - v_now <  interval '6 hours'          THEN 60
    WHEN v_occurs_at_local - v_now <  interval '24 hours'         THEN 5*60
    WHEN v_occurs_at_local - v_now <  interval '7 days'           THEN 30*60
    WHEN v_occurs_at_local - v_now <  interval '30 days'          THEN 4*3600
    WHEN v_occurs_at_local - v_now <  interval '60 days'          THEN 12*3600
    ELSE                                                               24*3600
  END;

  ----------------------------------------------------------------------
  -- 3. Lifecycle classification (non-essential — wrapped to keep page rendering even if RPC errors)
  ----------------------------------------------------------------------
  BEGIN
    SELECT to_jsonb(l) INTO v_lifecycle
    FROM public.derive_event_lifecycle(p_event_id) l LIMIT 1;
  EXCEPTION WHEN OTHERS THEN
    v_lifecycle := NULL;
  END;

  ----------------------------------------------------------------------
  -- 4. Latest 2 event_metrics rows — frontend computes deltas
  ----------------------------------------------------------------------
  WITH em_latest AS (
    SELECT row_number() OVER (ORDER BY captured_at DESC) AS rn, em.*
    FROM public.event_metrics em
    WHERE em.event_id = p_event_id
    ORDER BY captured_at DESC
    LIMIT 2
  )
  SELECT
    (SELECT to_jsonb(e) FROM em_latest e WHERE rn = 1),
    (SELECT to_jsonb(e) FROM em_latest e WHERE rn = 2)
  INTO v_metrics_curr, v_metrics_prev;

  v_last_em := nullif(v_metrics_curr->>'captured_at','')::timestamptz;

  ----------------------------------------------------------------------
  -- 5. Zone rollup (owned + market) — for overview pane
  ----------------------------------------------------------------------
  v_zones_rollup := jsonb_build_object(
    'owned',  coalesce(
      (SELECT jsonb_agg(to_jsonb(z))
         FROM public.get_event_zones_rollup(p_event_id, true) z),
      '[]'::jsonb),
    'market', coalesce(
      (SELECT jsonb_agg(to_jsonb(z))
         FROM public.get_event_zones_rollup(p_event_id, false) z),
      '[]'::jsonb)
  );

  ----------------------------------------------------------------------
  -- 6. Zones detail — for /zones endpoint
  -- Picks ONE zone_source per event by priority curated > fallback > unmapped.
  -- Mirrors app.py:1967-1976 priority logic.
  ----------------------------------------------------------------------
  WITH zm AS (
    SELECT
      zone, zone_source, captured_at,
      row_number() OVER (PARTITION BY zone_source, zone ORDER BY captured_at DESC) AS rn,
      tickets_count, groups_count, sections_count,
      retail_min, retail_p25, retail_median, retail_mean, retail_p75, retail_p90, retail_max, retail_sum,
      wholesale_min, wholesale_median, wholesale_mean, wholesale_max,
      getin_price,
      owned_groups_count, owned_tickets_count, owned_share, owned_median_retail
    FROM public.zone_metrics
    WHERE event_id = p_event_id
  ),
  src_pick AS (
    SELECT CASE
      WHEN EXISTS (SELECT 1 FROM zm WHERE zone_source = 'curated')  THEN 'curated'
      WHEN EXISTS (SELECT 1 FROM zm WHERE zone_source = 'fallback') THEN 'fallback'
      WHEN EXISTS (SELECT 1 FROM zm WHERE zone_source = 'unmapped') THEN 'unmapped'
      ELSE NULL
    END AS chosen_source
  )
  SELECT jsonb_build_object(
    'zones', coalesce(
      (SELECT jsonb_agg(to_jsonb(z) ORDER BY z.tickets_count DESC NULLS LAST)
         FROM zm z, src_pick s
        WHERE z.rn = 1 AND s.chosen_source IS NOT NULL AND z.zone_source = s.chosen_source),
      '[]'::jsonb),
    'source', (SELECT chosen_source FROM src_pick),
    'available_sources', coalesce(
      (SELECT array_agg(DISTINCT zone_source ORDER BY zone_source) FROM zm),
      ARRAY[]::text[])
  ) INTO v_zones_detail;

  ----------------------------------------------------------------------
  -- 7. Chart-data: event_metrics time series (frontend slices each column into its own series)
  ----------------------------------------------------------------------
  v_chart_em := coalesce(
    (SELECT jsonb_agg(to_jsonb(em) ORDER BY em.captured_at)
       FROM public.event_metrics em
      WHERE em.event_id = p_event_id
        AND em.captured_at >= v_since),
    '[]'::jsonb
  );

  -- Per-zone time series (one chosen source)
  WITH zm AS (
    SELECT zone, zone_source, captured_at,
           retail_median, tickets_count, owned_median_retail, owned_tickets_count
    FROM public.zone_metrics
    WHERE event_id = p_event_id AND captured_at >= v_since
  ),
  src_pick AS (
    SELECT CASE
      WHEN EXISTS (SELECT 1 FROM zm WHERE zone_source = 'curated')  THEN 'curated'
      WHEN EXISTS (SELECT 1 FROM zm WHERE zone_source = 'fallback') THEN 'fallback'
      WHEN EXISTS (SELECT 1 FROM zm WHERE zone_source = 'unmapped') THEN 'unmapped'
      ELSE NULL
    END AS chosen_source
  )
  SELECT coalesce(
    (SELECT jsonb_agg(to_jsonb(z) ORDER BY z.captured_at)
       FROM zm z, src_pick s
      WHERE s.chosen_source IS NOT NULL AND z.zone_source = s.chosen_source),
    '[]'::jsonb)
  INTO v_chart_zm;

  ----------------------------------------------------------------------
  -- 8. Orders + items
  ----------------------------------------------------------------------
  WITH items AS (
    SELECT
      i.evo_order_id, i.evo_item_id, i.quantity, i.price,
      i.ticket_group_id, i.ticket_group_section, i.ticket_group_row, i.ticket_group_seats,
      i.eticket_available, i.eticket_downloaded_at, i.occurs_at
    FROM public.evo_order_items i
    WHERE i.event_id = p_event_id
  ),
  ord AS (
    SELECT
      o.evo_order_id, o.state, o.type, o.fraud_check_status,
      o.total, o.subtotal, o.refunded, o.balance,
      o.buyer_name, o.seller_name, o.client_name,
      o.evo_created_at, o.evo_updated_at
    FROM public.evo_orders o
    WHERE o.evo_order_id IN (SELECT DISTINCT evo_order_id FROM items WHERE evo_order_id IS NOT NULL)
  )
  SELECT jsonb_build_object(
    'items',  coalesce((SELECT jsonb_agg(to_jsonb(i) ORDER BY i.evo_order_id, i.evo_item_id) FROM items i), '[]'::jsonb),
    'orders', coalesce((SELECT jsonb_agg(to_jsonb(o) ORDER BY o.evo_created_at DESC NULLS LAST) FROM ord o), '[]'::jsonb)
  ) INTO v_orders_payload;

  ----------------------------------------------------------------------
  -- 9. ESPN cadence helpers (table-wide; per-event is over-specific for MVP)
  ----------------------------------------------------------------------
  SELECT max(last_seen_at) INTO v_last_inj       FROM public.espn_injuries_snapshots;
  SELECT max(last_seen_at) INTO v_last_team_snap FROM public.espn_team_snapshots;

  ----------------------------------------------------------------------
  -- 10. Final flattened payload
  ----------------------------------------------------------------------
  RETURN jsonb_build_object(
    'event_id',     p_event_id,
    'generated_at', v_now,
    'overview', jsonb_build_object(
      'event',           v_event,
      'metrics_current', v_metrics_curr,
      'metrics_prev',    v_metrics_prev,
      'zones',           v_zones_rollup,
      'last_pull_at',    v_last_em,
      'cadence_seconds', v_listings_cad,
      'lifecycle',       v_lifecycle
    ),
    'chart_data', jsonb_build_object(
      'event_metrics_series', v_chart_em,
      'zone_metrics_series',  v_chart_zm,
      'range', jsonb_build_object(
        'since', v_since,
        'until', v_now,
        'hours', v_chart_hours
      )
    ),
    'zones',  v_zones_detail,
    'orders', v_orders_payload,
    'cadences', jsonb_build_object(
      'overview',        jsonb_build_object('last_pull_at', v_last_em,        'cadence_seconds', v_listings_cad),
      'section_metrics', jsonb_build_object('last_pull_at', v_last_em,        'cadence_seconds', v_listings_cad),
      'raw_tevo',        jsonb_build_object('last_pull_at', v_last_em,        'cadence_seconds', v_listings_cad),
      'espn_injuries',   jsonb_build_object('last_pull_at', v_last_inj,       'cadence_seconds', 600),
      'espn_team',       jsonb_build_object('last_pull_at', v_last_team_snap, 'cadence_seconds', 86400)
    )
  );
END $func$;

-- Anon role gets EXECUTE so the static-site terminal (signed in via Supabase
-- JS client with @s4kent.com magic-link) can call this. The function body's
-- own JWT email gate is what actually prevents non-S4K JWTs from getting data.
REVOKE ALL ON FUNCTION public.get_broker_event_page(integer, integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_broker_event_page(integer, integer) TO anon, authenticated;

COMMENT ON FUNCTION public.get_broker_event_page(integer, integer) IS
  'D0 broker event detail page RPC. Flattens overview+chart_data+zones+orders+cadences into one JSONB. Email-gated to @s4kent.com via auth.jwt(). Composes get_broker_event_detail + get_event_zones_rollup + derive_event_lifecycle. Returns RAW rows for frontend transformation. Mirrors app.py:1725-3254 endpoints. See migration header for shape contract.';
