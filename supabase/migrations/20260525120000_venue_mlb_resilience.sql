-- 20260525120000_venue_mlb_resilience.sql
--   (renamed from 20260524150000 → 20260525120000 on 2026-05-25: D4's
--    20260524150000_exos_public_marketing landed on main first; rebased to a
--    post-main slot to avoid a duplicate migration-sequence collision.)
--
-- ## Already applied to prod — applied via MCP apply_migration 2026-05-24.
--
-- D0 (operator-directed; A1 migration lane via "fix them in the current PR" 2026-05-24).
--
-- PROBLEM: aq_venue_map has 0 of 1,085 MLB events' venues (verified live) — the
--   venue matcher hasn't generated venue_short_ids for MLB stadiums. Both venue
--   RPCs key on aq_venue_map (index INNER-joins it; detail early-returns
--   'venue_not_found' if absent), so MLB drops out entirely (Venue index MLB=0;
--   MLB venue detail pages 404). The proper fix is an A1/pipeline backfill of
--   aq_venue_map (the matcher owns the venue_short_id canonical key — unsafe to
--   hand-generate). This is the in-PR RESILIENCE stopgap until that lands:
--   source venue identity from the events table when aq_venue_map is absent.
--
-- SAFETY: NFL/NBA/MLS are unchanged — they match aq_venue_map, so COALESCE()
--   resolves to the aq_venue_map values exactly as before. Only MLB (no match)
--   falls back to events. lat/lon/capacity/is_indoor stay NULL for the fallback
--   (enrichment the backfill will fill later). The detail's rollup/events/SG
--   blocks already query by ev.venue_id, so they work for any venue id.

-- 1) Venue index — LEFT JOIN aq_venue_map + COALESCE identity from events
CREATE OR REPLACE FUNCTION public.get_broker_venue_index()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
DECLARE v_email text; v_result jsonb;
BEGIN
  v_email := coalesce(auth.jwt()->>'email', '');
  IF v_email NOT LIKE '%@s4kent.com' THEN
    RAISE EXCEPTION 'forbidden: % is not an @s4kent.com email', v_email USING ERRCODE = '42501';
  END IF;

  WITH ev_join AS (
    SELECT ev.venue_id AS tevo_venue_id,
      COALESCE(av.venue_name, ev.venue_name) AS venue_name,
      COALESCE(av.city, NULLIF(split_part(ev.venue_location, ',', 1), '')) AS city,
      COALESCE(av.state, NULLIF(trim(split_part(ev.venue_location, ',', 2)), '')) AS state,
      av.latitude, av.longitude, va.capacity, va.is_indoor,
      xt.espn_league, ev.id AS event_id, ap.performer_name
    FROM public.events ev
    LEFT JOIN public.aq_venue_map av ON av.tevo_venue_id = ev.venue_id
    LEFT JOIN public.venue_assets va ON va.tevo_venue_id = ev.venue_id
    JOIN public.performer_espn_team_xref xt ON xt.tevo_performer_id = ev.primary_performer_id
    LEFT JOIN public.aq_performer_map ap ON ap.tevo_performer_id = ev.primary_performer_id
    WHERE xt.espn_league IN ('NFL','NBA','MLB','MLS')
      AND ev.venue_id IS NOT NULL
      AND ev.occurs_at_local ~ '^\d{4}'
      AND ev.occurs_at_local::timestamptz >= now()
      AND ev.occurs_at_local::timestamptz < now() + interval '90 days'
  ),
  agg AS (
    SELECT espn_league, tevo_venue_id,
      max(venue_name) AS venue_name, max(city) AS city, max(state) AS state,
      max(latitude) AS latitude, max(longitude) AS longitude,
      max(capacity) AS capacity, bool_or(is_indoor) AS is_indoor,
      COUNT(DISTINCT event_id) AS events_count_next_90d,
      (array_agg(performer_name ORDER BY performer_name) FILTER (WHERE performer_name IS NOT NULL))[1] AS top_performer_name
    FROM ev_join GROUP BY espn_league, tevo_venue_id
  ),
  per_league AS (
    SELECT espn_league,
      jsonb_agg(jsonb_build_object(
        'tevo_venue_id', tevo_venue_id, 'venue_name', venue_name,
        'city', city, 'state', state, 'capacity', capacity,
        'is_indoor', is_indoor, 'latitude', latitude, 'longitude', longitude,
        'top_performer_name', top_performer_name,
        'events_count_next_90d', events_count_next_90d
      ) ORDER BY venue_name) AS venues, COUNT(*) AS venue_count
    FROM agg GROUP BY espn_league
  )
  SELECT jsonb_build_object(
    'counts', jsonb_object_agg(espn_league, venue_count) ||
              jsonb_build_object('total_distinct_venues', (SELECT COUNT(DISTINCT tevo_venue_id) FROM agg)),
    'leagues', jsonb_object_agg(espn_league, venues)
  ) INTO v_result FROM per_league;

  RETURN coalesce(v_result, jsonb_build_object('counts', '{}'::jsonb, 'leagues', '{}'::jsonb));
END $function$;

-- 2) Venue detail — fall back to events when the venue isn't in aq_venue_map
CREATE OR REPLACE FUNCTION public.get_broker_venue_page(p_venue_id integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
DECLARE v_email text; v_venue jsonb; v_aggregate jsonb; v_events jsonb; v_sg jsonb;
BEGIN
  v_email := coalesce(auth.jwt()->>'email', '');
  IF v_email NOT LIKE '%@s4kent.com' THEN
    RAISE EXCEPTION 'forbidden: % is not an @s4kent.com email', v_email USING ERRCODE = '42501';
  END IF;

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
  -- backfill) — build a minimal header from the events table. Enrichment
  -- (lat/lon/capacity/indoor/hero) stays null until the backfill lands.
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

  WITH ev_rows AS (
    SELECT ev.id, ev.name, ev.primary_performer_name, ev.occurs_at_local,
      em.tickets_count, em.retail_median, em.owned_tickets_count, em.owned_median_retail
    FROM public.events ev
    LEFT JOIN LATERAL (
      SELECT tickets_count, retail_median, owned_tickets_count, owned_median_retail
      FROM public.event_metrics em
      WHERE em.event_id = ev.id ORDER BY captured_at DESC LIMIT 1
    ) em ON true
    WHERE ev.venue_id = p_venue_id
      AND ev.occurs_at_local ~ '^\d{4}'
      AND ev.occurs_at_local::timestamptz >= now()
      AND ev.occurs_at_local::timestamptz < now() + interval '90 days'
  )
  SELECT
    coalesce(jsonb_agg(to_jsonb(r) ORDER BY r.occurs_at_local), '[]'::jsonb),
    jsonb_build_object(
      'events_count', count(*),
      'distinct_performers', count(DISTINCT r.primary_performer_name),
      'market_tickets_total', coalesce(sum(r.tickets_count), 0),
      'owned_tickets_total', coalesce(sum(r.owned_tickets_count), 0),
      'owned_notional', coalesce(sum(r.owned_tickets_count * r.owned_median_retail), 0)::numeric(20,2)
    )
  INTO v_events, v_aggregate FROM ev_rows r;

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