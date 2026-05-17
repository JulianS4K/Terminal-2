-- Migration 20260518020000 · lane:D0 (author) → A1 (apply) · writes:get_broker_venue_index + get_broker_venue_page · reads:events,aq_performer_map,performer_espn_team_xref,aq_venue_map,venue_assets,event_metrics,seatgeek_sales_snapshots,seatgeek_event_xref · pre:20260518010000 · auth:operator-approved 2026-05-17
--
-- D0 Phase 2b — two SECDEF RPCs powering the new venue page:
--   1. get_broker_venue_index()      — 4-league directory of major-league venues
--   2. get_broker_venue_page(p_id)   — hero + aggregate + events + SG activity for DETAIL tabs
--
-- Per A1 pre-flight audit (bot_chat #299):
--   #5 Venue→league derived via events→performer→performer_espn_team_xref
--      (entity_venue_map has no espn_league column)
--   #4 events.occurs_at_local is TEXT — regex guard + cast to timestamptz
--
-- Index sort: dedupe on (tevo_venue_id, espn_league) — a venue serving two
-- leagues (MetLife = NFL + MLS) appears once per league it serves.
--
-- Both follow canonical v3 SECDEF: @s4kent.com gate, REVOKE PUBLIC + GRANT anon/auth.

-- ============================================================
-- 1. Venue Index (4-league directory)
-- ============================================================
CREATE OR REPLACE FUNCTION public.get_broker_venue_index()
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, extensions, pg_temp
AS $func$
DECLARE
  v_email  text;
  v_result jsonb;
BEGIN
  v_email := coalesce(auth.jwt()->>'email', '');
  IF v_email NOT LIKE '%@s4kent.com' THEN
    RAISE EXCEPTION 'forbidden: % is not an @s4kent.com email', v_email USING ERRCODE = '42501';
  END IF;

  WITH ev_join AS (
    SELECT
      av.tevo_venue_id,
      av.venue_name,
      av.city,
      av.state,
      av.latitude,
      av.longitude,
      va.capacity,
      va.is_indoor,
      xt.espn_league,
      ev.id AS event_id,
      ap.performer_name
    FROM public.events ev
    JOIN public.aq_venue_map av ON av.tevo_venue_id = ev.venue_id
    LEFT JOIN public.venue_assets va ON va.tevo_venue_id = av.tevo_venue_id
    JOIN public.performer_espn_team_xref xt ON xt.tevo_performer_id = ev.primary_performer_id
    LEFT JOIN public.aq_performer_map ap ON ap.tevo_performer_id = ev.primary_performer_id
    WHERE xt.espn_league IN ('NFL','NBA','MLB','MLS')
      AND ev.occurs_at_local ~ '^\d{4}'
      AND ev.occurs_at_local::timestamptz >= now()
      AND ev.occurs_at_local::timestamptz < now() + interval '90 days'
  ),
  agg AS (
    SELECT
      espn_league,
      tevo_venue_id,
      max(venue_name)   AS venue_name,
      max(city)         AS city,
      max(state)        AS state,
      max(latitude)     AS latitude,
      max(longitude)    AS longitude,
      max(capacity)     AS capacity,
      bool_or(is_indoor) AS is_indoor,
      COUNT(DISTINCT event_id) AS events_count_next_90d,
      (array_agg(performer_name ORDER BY performer_name) FILTER (WHERE performer_name IS NOT NULL))[1] AS top_performer_name
    FROM ev_join
    GROUP BY espn_league, tevo_venue_id
  ),
  per_league AS (
    SELECT espn_league,
      jsonb_agg(
        jsonb_build_object(
          'tevo_venue_id', tevo_venue_id,
          'venue_name',    venue_name,
          'city',          city,
          'state',         state,
          'capacity',      capacity,
          'is_indoor',     is_indoor,
          'latitude',      latitude,
          'longitude',     longitude,
          'top_performer_name',    top_performer_name,
          'events_count_next_90d', events_count_next_90d
        )
        ORDER BY venue_name
      ) AS venues,
      COUNT(*) AS venue_count
    FROM agg
    GROUP BY espn_league
  )
  SELECT jsonb_build_object(
    'counts',  jsonb_object_agg(espn_league, venue_count) ||
               jsonb_build_object(
                 'total_distinct_venues',
                 (SELECT COUNT(DISTINCT tevo_venue_id) FROM agg)
               ),
    'leagues', jsonb_object_agg(espn_league, venues)
  )
  INTO v_result
  FROM per_league;

  RETURN coalesce(v_result, jsonb_build_object('counts', '{}'::jsonb, 'leagues', '{}'::jsonb));
END $func$;

REVOKE ALL ON FUNCTION public.get_broker_venue_index() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_broker_venue_index() TO anon, authenticated;

COMMENT ON FUNCTION public.get_broker_venue_index() IS
  'D0 venue page INDEX mode — NFL/NBA/MLB/MLS venues derived via events→performer→performer_espn_team_xref. Deduped on (tevo_venue_id, espn_league); MetLife appears under both NFL and MLS. Email-gated.';

-- ============================================================
-- 2. Venue Page (DETAIL with 4 tab payloads in one round-trip)
-- ============================================================
CREATE OR REPLACE FUNCTION public.get_broker_venue_page(p_venue_id integer)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, extensions, pg_temp
AS $func$
DECLARE
  v_email     text;
  v_venue     jsonb;
  v_aggregate jsonb;
  v_events    jsonb;
  v_sg        jsonb;
BEGIN
  v_email := coalesce(auth.jwt()->>'email', '');
  IF v_email NOT LIKE '%@s4kent.com' THEN
    RAISE EXCEPTION 'forbidden: % is not an @s4kent.com email', v_email USING ERRCODE = '42501';
  END IF;

  -- Hero: venue identity + capacity / indoor / coords
  SELECT jsonb_build_object(
    'tevo_venue_id', av.tevo_venue_id,
    'venue_name',    av.venue_name,
    'city',          av.city,
    'state',         av.state,
    'country',       av.country,
    'sg_venue_id',   av.sg_venue_id,
    'tickpick_venue_id', av.tickpick_venue_id,
    'latitude',      coalesce(va.latitude,  av.latitude),
    'longitude',     coalesce(va.longitude, av.longitude),
    'capacity',      va.capacity,
    'is_indoor',     va.is_indoor,
    'hero_image_url', va.hero_image_url
  )
  INTO v_venue
  FROM public.aq_venue_map av
  LEFT JOIN public.venue_assets va ON va.tevo_venue_id = av.tevo_venue_id
  WHERE av.tevo_venue_id = p_venue_id
  LIMIT 1;

  IF v_venue IS NULL THEN
    RETURN jsonb_build_object('hidden', true, 'reason', 'venue_not_found');
  END IF;

  -- Events tab: next-90d events at this venue with per-event metrics
  WITH ev_rows AS (
    SELECT
      ev.id,
      ev.name,
      ev.primary_performer_name,
      ev.occurs_at_local,
      em.tickets_count,
      em.retail_median,
      em.owned_tickets_count,
      em.owned_median_retail
    FROM public.events ev
    LEFT JOIN LATERAL (
      SELECT tickets_count, retail_median, owned_tickets_count, owned_median_retail
      FROM public.event_metrics em
      WHERE em.event_id = ev.id
      ORDER BY captured_at DESC
      LIMIT 1
    ) em ON true
    WHERE ev.venue_id = p_venue_id
      AND ev.occurs_at_local ~ '^\d{4}'
      AND ev.occurs_at_local::timestamptz >= now()
      AND ev.occurs_at_local::timestamptz < now() + interval '90 days'
  )
  SELECT
    coalesce(jsonb_agg(to_jsonb(r) ORDER BY r.occurs_at_local), '[]'::jsonb),
    jsonb_build_object(
      'events_count',          count(*),
      'distinct_performers',   count(DISTINCT r.primary_performer_name),
      'market_tickets_total',  coalesce(sum(r.tickets_count), 0),
      'owned_tickets_total',   coalesce(sum(r.owned_tickets_count), 0),
      'owned_notional',        coalesce(sum(r.owned_tickets_count * r.owned_median_retail), 0)::numeric(20,2)
    )
  INTO v_events, v_aggregate
  FROM ev_rows r;

  -- SG Activity tab: 24h SG sales count across all events at this venue
  -- (DISTINCT ON sg_sale_id mandatory per PROJECT_BIBLE §3 — 11x firehose dedup)
  WITH event_xrefs AS (
    SELECT x.sg_event_id
    FROM public.events ev
    JOIN public.seatgeek_event_xref x ON x.tevo_event_id = ev.id
    WHERE ev.venue_id = p_venue_id
  ),
  deduped AS (
    SELECT DISTINCT ON (s.sg_sale_id)
      s.sg_sale_id, s.sg_event_id, s.broadcast_price, s.quantity
    FROM public.seatgeek_sales_snapshots s
    JOIN event_xrefs ex ON ex.sg_event_id = s.sg_event_id
    WHERE s.sale_at_utc > now() - interval '24 hours'
    ORDER BY s.sg_sale_id, s.pulled_at DESC
  )
  SELECT jsonb_build_object(
    'sales_24h', count(*),
    'tickets_24h', coalesce(sum(quantity), 0),
    'gmv_24h', coalesce(sum(broadcast_price * quantity), 0)::numeric(20,2),
    'distinct_events_with_sales', count(DISTINCT sg_event_id)
  )
  INTO v_sg
  FROM deduped;

  RETURN jsonb_build_object(
    'venue',     v_venue,
    'aggregate', v_aggregate,
    'events',    v_events,
    'sg_activity', v_sg,
    'hidden',    false
  );
END $func$;

REVOKE ALL ON FUNCTION public.get_broker_venue_page(integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_broker_venue_page(integer) TO anon, authenticated;

COMMENT ON FUNCTION public.get_broker_venue_page(integer) IS
  'D0 venue page DETAIL — hero (aq_venue_map + venue_assets) + aggregate + upcoming events (event_metrics) + SG activity (24h DISTINCT ON sg_sale_id). Email-gated.';
