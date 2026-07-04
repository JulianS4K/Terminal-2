-- Add an `espn_attendance` block to get_broker_venue_page: a venue's home
-- attendance is its resident team(s)' home attendance. Resolves the team(s) that
-- play home games at the venue (events -> performer_espn_team_xref) and returns
-- each one's latest attendance snapshot (rank, home avg/total), ordered by how
-- many home events they hold there — so a shared arena (e.g. MSG: Knicks +
-- Rangers) lists both. Slice-2 attendance pipeline.
--
-- Only v_att + the return key are new vs the live definition; the rest is verbatim.

CREATE OR REPLACE FUNCTION public.get_broker_venue_page(p_venue_id integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
DECLARE v_email text; v_venue jsonb; v_aggregate jsonb; v_events jsonb; v_sg jsonb; v_att jsonb;
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

  -- ESPN attendance for the venue's resident team(s), ordered by home-event count.
  WITH resident AS (
    SELECT x.espn_team_id, x.espn_league, count(*) AS home_events
    FROM public.events ev
    JOIN public.performer_espn_team_xref x ON x.tevo_performer_id = ev.primary_performer_id
    WHERE ev.venue_id = p_venue_id
    GROUP BY x.espn_team_id, x.espn_league
  )
  SELECT coalesce(jsonb_agg(j.a ORDER BY r.home_events DESC), '[]'::jsonb)
  INTO v_att
  FROM resident r
  JOIN LATERAL (
    SELECT jsonb_build_object(
      'team_name', al.team_name, 'espn_league', al.espn_league, 'season', al.season,
      'rank', al.rank, 'home_games', al.home_games, 'home_avg', al.home_avg,
      'home_total', al.home_total, 'home_pct', al.home_pct, 'captured_at', al.captured_at
    ) AS a
    FROM public.espn_attendance_latest al
    WHERE al.espn_team_id = r.espn_team_id AND al.espn_league = r.espn_league
  ) j ON true;

  RETURN jsonb_build_object(
    'venue', v_venue, 'aggregate', v_aggregate,
    'events', v_events, 'sg_activity', v_sg,
    'espn_attendance', coalesce(v_att, '[]'::jsonb), 'hidden', false
  );
END $function$;
