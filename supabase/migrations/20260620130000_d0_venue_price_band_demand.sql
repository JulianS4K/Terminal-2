-- ============================================================================
-- Migration 20260620130000 — D0 venue page: true price band + per-event demand
--
-- Lane:     D0 (author) → A1 (apply)   [D0 has no prod-DB apply authority]
-- Touches:  get_broker_venue_page (W, CREATE OR REPLACE)
--           events (R), event_metrics (R), aq_venue_map (R), venue_assets (R),
--           listings_snapshots (R), seatgeek_event_xref (R),
--           seatgeek_sales_snapshots (R)
-- Pre-reqs: 20260525120000_venue_mlb_resilience.sql (current fn definition)
--
-- WHY: the venue rollup carried NO price metric, and the "EVO MEDIAN" shown in
--   the Market Carpet ticker was computed client-side as a *mean of per-event
--   medians* (mislabeled, and equal-weighted so a 24-ticket season-ticket
--   listing counted the same as a 2,635-ticket game). This adds:
--
--   1. aggregate.price_band — a TRUE venue-level percentile band (getin / p25 /
--      median / p90 / max + listing_rows + market_tickets) computed server-side
--      with percentile_cont over the LATEST listings_snapshots snapshot of every
--      upcoming event at the venue. One real cross-event median, not a mean.
--
--   2. Richer per-event fields already precomputed in event_metrics but never
--      surfaced (retail_min/p25/p90/max, getin_price, retail_mean,
--      price_dispersion, groups_count, sections_count, owned_share) so the
--      frontend can render a price band + demand signals per event.
--
--   3. Per-event SeatGeek sales velocity (sg_sales_7d / sg_tix_7d), DISTINCT ON
--      sg_sale_id per PROJECT_BIBLE §3 (firehose 11-23x overcount), feeding the
--      frontend popularity/heat score. Sparse for some events (e.g. preseason
--      NFL = 0) — the FE score degrades gracefully to price/inventory/momentum.
--
-- §3 LANDMINES honored:
--   • listings_snapshots: query by event_id only (aq_short_event_id 0% pop);
--     non-ancillary, retail_price>0, latest snapshot per event (max captured_at).
--   • seatgeek_sales_snapshots: DISTINCT ON (sg_sale_id) ORDER BY pulled_at DESC
--     before any aggregate; join on sg_event_id (tevo_event_id 0% pop).
--   • events.occurs_at_local is TEXT — regex guard + cast, unchanged from prior.
--
-- Canonical v3 SECDEF: @s4kent.com gate, REVOKE PUBLIC + GRANT anon/auth.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.get_broker_venue_page(p_venue_id integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
DECLARE
  v_email      text;
  v_venue      jsonb;
  v_aggregate  jsonb;
  v_events     jsonb;
  v_sg         jsonb;
  v_price_band jsonb;
BEGIN
  v_email := coalesce(auth.jwt()->>'email', '');
  IF v_email NOT LIKE '%@s4kent.com' THEN
    RAISE EXCEPTION 'forbidden: % is not an @s4kent.com email', v_email USING ERRCODE = '42501';
  END IF;

  -- ── Hero: venue identity (aq_venue_map + venue_assets, events fallback) ──────
  SELECT jsonb_build_object(
    'tevo_venue_id', av.tevo_venue_id, 'venue_name', av.venue_name,
    'city', av.city, 'state', av.state, 'country', av.country,
    'sg_venue_id', av.sg_venue_id, 'tickpick_venue_id', av.tickpick_venue_id,
    'latitude', coalesce(va.latitude, av.latitude),
    'longitude', coalesce(va.longitude, av.longitude),
    'capacity', va.capacity, 'is_indoor', va.is_indoor,
    'hero_image_url', va.hero_image_url
  ) INTO v_venue
  FROM public.aq_venue_map av
  LEFT JOIN public.venue_assets va ON va.tevo_venue_id = av.tevo_venue_id
  WHERE av.tevo_venue_id = p_venue_id LIMIT 1;

  -- Fallback: venue not in aq_venue_map (e.g. MLB stadiums pending the matcher
  -- backfill) — build a minimal header from the events table.
  IF v_venue IS NULL THEN
    SELECT jsonb_build_object(
      'tevo_venue_id', p_venue_id, 'venue_name', e.vn,
      'city', NULLIF(split_part(e.vl, ',', 1), ''),
      'state', NULLIF(trim(split_part(e.vl, ',', 2)), ''), 'country', NULL,
      'sg_venue_id', NULL, 'tickpick_venue_id', NULL,
      'latitude', NULL, 'longitude', NULL, 'capacity', NULL, 'is_indoor', NULL,
      'hero_image_url', NULL
    ) INTO v_venue
    FROM (
      SELECT max(venue_name) AS vn, max(venue_location) AS vl
      FROM public.events WHERE venue_id = p_venue_id
    ) e
    WHERE e.vn IS NOT NULL;
  END IF;

  IF v_venue IS NULL THEN
    RETURN jsonb_build_object('hidden', true, 'reason', 'venue_not_found');
  END IF;

  -- ── Events tab + aggregate: per-event metrics + SG sales velocity ───────────
  WITH ev AS (
    SELECT id, name, primary_performer_name, occurs_at_local
    FROM public.events
    WHERE venue_id = p_venue_id
      AND occurs_at_local ~ '^\d{4}'
      AND occurs_at_local::timestamptz >= now()
      AND occurs_at_local::timestamptz < now() + interval '90 days'
  ),
  -- Per-event SG sales velocity (last 7d) — DISTINCT ON sg_sale_id (§3 dedupe).
  sg_dedup AS (
    SELECT DISTINCT ON (s.sg_sale_id)
      s.sg_sale_id, x.tevo_event_id, s.quantity
    FROM public.seatgeek_sales_snapshots s
    JOIN public.seatgeek_event_xref x ON x.sg_event_id = s.sg_event_id
    JOIN ev ON ev.id = x.tevo_event_id
    WHERE s.sale_at_utc > now() - interval '7 days'
    ORDER BY s.sg_sale_id, s.pulled_at DESC
  ),
  sg_vel AS (
    SELECT tevo_event_id,
           count(*)                  AS sg_sales_7d,
           coalesce(sum(quantity),0) AS sg_tix_7d
    FROM sg_dedup GROUP BY tevo_event_id
  ),
  ev_rows AS (
    SELECT
      ev.id, ev.name, ev.primary_performer_name, ev.occurs_at_local,
      em.tickets_count, em.groups_count, em.sections_count,
      em.retail_min, em.retail_p25, em.retail_median, em.retail_mean,
      em.retail_p75, em.retail_p90, em.retail_max, em.getin_price,
      em.price_dispersion,
      em.owned_tickets_count, em.owned_median_retail, em.owned_share,
      coalesce(sv.sg_sales_7d, 0) AS sg_sales_7d,
      coalesce(sv.sg_tix_7d,   0) AS sg_tix_7d
    FROM ev
    LEFT JOIN LATERAL (
      SELECT tickets_count, groups_count, sections_count,
             retail_min, retail_p25, retail_median, retail_mean,
             retail_p75, retail_p90, retail_max, getin_price, price_dispersion,
             owned_tickets_count, owned_median_retail, owned_share
      FROM public.event_metrics m
      WHERE m.event_id = ev.id ORDER BY captured_at DESC LIMIT 1
    ) em ON true
    LEFT JOIN sg_vel sv ON sv.tevo_event_id = ev.id
  )
  SELECT
    coalesce(jsonb_agg(to_jsonb(r) ORDER BY r.occurs_at_local), '[]'::jsonb),
    jsonb_build_object(
      'events_count',         count(*),
      'distinct_performers',  count(DISTINCT r.primary_performer_name),
      'market_tickets_total', coalesce(sum(r.tickets_count), 0),
      'owned_tickets_total',  coalesce(sum(r.owned_tickets_count), 0),
      'owned_notional',       coalesce(sum(r.owned_tickets_count * r.owned_median_retail), 0)::numeric(20,2),
      'sg_sales_7d_total',    coalesce(sum(r.sg_sales_7d), 0),
      'sg_tix_7d_total',      coalesce(sum(r.sg_tix_7d), 0)
    )
  INTO v_events, v_aggregate FROM ev_rows r;

  -- ── TRUE venue-level price band ─────────────────────────────────────────────
  -- percentile_cont over the LATEST listings snapshot of every upcoming event at
  -- the venue. One real cross-event median (vs the old client-side mean-of-medians).
  WITH ev AS (
    SELECT id FROM public.events
    WHERE venue_id = p_venue_id
      AND occurs_at_local ~ '^\d{4}'
      AND occurs_at_local::timestamptz >= now()
      AND occurs_at_local::timestamptz < now() + interval '90 days'
  ),
  latest AS (
    SELECT ls.retail_price, ls.quantity,
           ls.captured_at,
           max(ls.captured_at) OVER (PARTITION BY ls.event_id) AS max_cap
    FROM public.listings_snapshots ls
    JOIN ev ON ev.id = ls.event_id
    WHERE coalesce(ls.is_ancillary, false) = false
      AND ls.retail_price > 0
  ),
  cur AS (SELECT retail_price, quantity FROM latest WHERE captured_at = max_cap)
  SELECT jsonb_build_object(
    'listing_rows',   count(*),
    'market_tickets', coalesce(sum(quantity), 0),
    'getin',          round(min(retail_price), 2),
    'p25',            round(percentile_cont(0.25) WITHIN GROUP (ORDER BY retail_price)::numeric, 2),
    'median',         round(percentile_cont(0.50) WITHIN GROUP (ORDER BY retail_price)::numeric, 2),
    'p90',            round(percentile_cont(0.90) WITHIN GROUP (ORDER BY retail_price)::numeric, 2),
    'max',            round(max(retail_price), 2)
  ) INTO v_price_band
  FROM cur;

  -- Merge the price band into the aggregate payload.
  v_aggregate := v_aggregate || jsonb_build_object('price_band', coalesce(v_price_band, '{}'::jsonb));

  -- ── SG Activity tab: venue-wide 24h sales (unchanged) ───────────────────────
  WITH event_xrefs AS (
    SELECT x.sg_event_id FROM public.events ev
    JOIN public.seatgeek_event_xref x ON x.tevo_event_id = ev.id
    WHERE ev.venue_id = p_venue_id
  ),
  deduped AS (
    SELECT DISTINCT ON (s.sg_sale_id) s.sg_sale_id, s.sg_event_id, s.broadcast_price, s.quantity
    FROM public.seatgeek_sales_snapshots s
    JOIN event_xrefs ex ON ex.sg_event_id = s.sg_event_id
    WHERE s.sale_at_utc > now() - interval '24 hours'
    ORDER BY s.sg_sale_id, s.pulled_at DESC
  )
  SELECT jsonb_build_object(
    'sales_24h', count(*), 'tickets_24h', coalesce(sum(quantity), 0),
    'gmv_24h', coalesce(sum(broadcast_price * quantity), 0)::numeric(20,2),
    'distinct_events_with_sales', count(DISTINCT sg_event_id)
  ) INTO v_sg FROM deduped;

  RETURN jsonb_build_object(
    'venue', v_venue, 'aggregate', v_aggregate,
    'events', v_events, 'sg_activity', v_sg, 'hidden', false
  );
END $function$;

REVOKE ALL ON FUNCTION public.get_broker_venue_page(integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_broker_venue_page(integer) TO anon, authenticated;

COMMENT ON FUNCTION public.get_broker_venue_page(integer) IS
  'D0 venue page DETAIL — hero + aggregate (now incl. TRUE price_band percentiles over latest listings_snapshots + SG 7d velocity totals) + per-event metrics (full retail percentile band, getin, dispersion, SG 7d velocity) + SG 24h activity. Email-gated. See mig 20260620130000.';
