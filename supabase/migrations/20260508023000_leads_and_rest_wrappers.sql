-- 20260508023000_leads_and_rest_wrappers.sql
-- Captured from prod (copilot, applied as version 20260508171559).
-- Captured into git 2026-05-08 by code via audit-and-commit.
--
-- Adds leads table + public REST wrappers for the retail web flow:
--   get_event_zones_public, get_event_listings_public,
--   get_events_by_performer_public, get_events_by_venue_public,
--   get_performer_landing_public, submit_lead_public
-- HARD RESTRICT (rule 15): retail leads write to leads table, NOT TEvo orders.
-- Human rep handles purchase off-platform.

CREATE TABLE IF NOT EXISTS leads (
  id                  bigserial PRIMARY KEY,
  event_id            bigint REFERENCES events(id) ON DELETE SET NULL,
  ticket_group_id     bigint,
  qty                 integer,
  zone                text,
  max_price           numeric,
  budget_basis        text,
  name                text,
  email               text,
  phone               text,
  notes               text,
  channel             text NOT NULL DEFAULT 'web',
  source_url          text,
  anon_id             text,
  status              text NOT NULL DEFAULT 'new',
  assigned_to         text,
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now(),
  contacted_at        timestamptz,
  closed_at           timestamptz
);
CREATE INDEX IF NOT EXISTS leads_status_created_idx ON leads (status, created_at DESC);
CREATE INDEX IF NOT EXISTS leads_event_idx          ON leads (event_id);
CREATE INDEX IF NOT EXISTS leads_email_idx          ON leads (lower(email)) WHERE email IS NOT NULL;
CREATE INDEX IF NOT EXISTS leads_channel_idx        ON leads (channel);
COMMENT ON TABLE leads IS 'Reserve-via-rep submissions. HARD RESTRICT (rule 15): no auto-purchase.';

DROP FUNCTION IF EXISTS get_event_zones_public(bigint, boolean);
CREATE OR REPLACE FUNCTION get_event_zones_public(
  p_event_id bigint, p_include_all boolean DEFAULT false
) RETURNS TABLE (
  zone_name text, zone_source text, display_order integer,
  listings integer, total_tickets integer,
  cheapest numeric, median numeric, most_expensive numeric
) LANGUAGE plpgsql STABLE AS $$
DECLARE v_perf bigint; v_venue bigint;
BEGIN
  SELECT primary_performer_id, venue_id INTO v_perf, v_venue FROM events WHERE id = p_event_id;
  RETURN QUERY
  WITH latest_snap AS (
    SELECT max(captured_at) AS captured_at
    FROM listings_snapshots
    WHERE event_id = p_event_id AND is_ancillary = false
      AND (type IS NULL OR type = 'event')
      AND captured_at > now() - interval '24 hours'
  ),
  filtered AS (
    SELECT ls.section, ls.retail_price, ls.quantity
    FROM listings_snapshots ls, latest_snap s
    WHERE ls.event_id = p_event_id AND ls.captured_at = s.captured_at
      AND ls.is_ancillary = false AND (ls.type IS NULL OR ls.type = 'event')
      AND ls.retail_price IS NOT NULL AND ls.retail_price > 0
      AND (p_include_all OR ls.is_owned = true)
  ),
  zoned AS (
    SELECT f.*,
      COALESCE(
        (SELECT pz.name FROM performer_zones pz
         JOIN performer_zone_rules pr ON pr.zone_id = pz.id
         WHERE pz.performer_id = v_perf AND pz.venue_id = v_venue
           AND COALESCE(pz.source,'curated') = 'curated'
           AND f.section ILIKE pr.section_from LIMIT 1),
        classify_zone_canonical(f.section)
      ) AS zname,
      COALESCE(
        (SELECT pz.source FROM performer_zones pz
         JOIN performer_zone_rules pr ON pr.zone_id = pz.id
         WHERE pz.performer_id = v_perf AND pz.venue_id = v_venue
           AND f.section ILIKE pr.section_from LIMIT 1),
        'system'
      ) AS zsource,
      COALESCE(
        (SELECT pz.display_order FROM performer_zones pz
         JOIN performer_zone_rules pr ON pr.zone_id = pz.id
         WHERE pz.performer_id = v_perf AND pz.venue_id = v_venue
           AND f.section ILIKE pr.section_from LIMIT 1),
        9000
      ) AS dorder
    FROM filtered f
  )
  SELECT zname, zsource, MIN(dorder)::int,
         count(*)::int, sum(quantity)::int,
         min(retail_price), percentile_cont(0.5) WITHIN GROUP (ORDER BY retail_price), max(retail_price)
  FROM zoned
  GROUP BY zname, zsource
  ORDER BY (zsource = 'curated') DESC, MIN(dorder), MIN(retail_price);
END;
$$;

DROP FUNCTION IF EXISTS get_event_listings_public(bigint, text, integer, numeric, integer, boolean);
CREATE OR REPLACE FUNCTION get_event_listings_public(
  p_event_id bigint, p_zone text DEFAULT NULL,
  p_min_qty integer DEFAULT 1, p_max_price numeric DEFAULT NULL,
  p_limit integer DEFAULT 25, p_include_all boolean DEFAULT false
) RETURNS TABLE (
  ticket_group_id bigint, section text, seat_row text, quantity integer,
  retail_price numeric, format text, splits integer[],
  instant_delivery boolean, wheelchair boolean, is_owned boolean,
  brokerage_provenance text, resolved_zone text
) LANGUAGE plpgsql STABLE AS $$
DECLARE
  v_zones text[]; v_perf bigint; v_venue bigint;
BEGIN
  SELECT primary_performer_id, venue_id INTO v_perf, v_venue FROM events WHERE id = p_event_id;
  IF p_zone IS NOT NULL THEN
    SELECT array_agg(zone_name) INTO v_zones
    FROM expand_user_zone_token_to_zones(v_perf, v_venue, p_zone);
  END IF;
  RETURN QUERY
  WITH latest_snap AS (
    SELECT max(captured_at) AS captured_at
    FROM listings_snapshots
    WHERE event_id = p_event_id AND is_ancillary = false
      AND (type IS NULL OR type = 'event')
      AND captured_at > now() - interval '24 hours'
  ),
  filtered AS (
    SELECT ls.tevo_ticket_group_id::bigint AS tgid,
      ls.section, ls.row AS srow, ls.quantity, ls.retail_price,
      ls.format, ls.splits, ls.instant_delivery, ls.wheelchair, ls.is_owned,
      COALESCE(
        (SELECT pz.name FROM performer_zones pz
         JOIN performer_zone_rules pr ON pr.zone_id = pz.id
         WHERE pz.performer_id = v_perf AND pz.venue_id = v_venue
           AND COALESCE(pz.source,'curated') = 'curated'
           AND ls.section ILIKE pr.section_from LIMIT 1),
        classify_zone_canonical(ls.section)
      ) AS rzone
    FROM listings_snapshots ls, latest_snap s
    WHERE ls.event_id = p_event_id AND ls.captured_at = s.captured_at
      AND ls.is_ancillary = false AND (ls.type IS NULL OR ls.type = 'event')
      AND ls.retail_price IS NOT NULL AND ls.retail_price > 0
      AND (p_include_all OR ls.is_owned = true)
      AND ls.quantity >= p_min_qty
      AND (p_max_price IS NULL OR ls.retail_price <= p_max_price)
  )
  SELECT f.tgid, f.section, f.srow, f.quantity, f.retail_price, f.format,
         f.splits::integer[], f.instant_delivery, f.wheelchair, f.is_owned,
         CASE WHEN f.is_owned THEN 's4k_owned' ELSE 'tevo_marketplace' END,
         f.rzone
  FROM filtered f
  WHERE v_zones IS NULL OR f.rzone = ANY(v_zones)
  ORDER BY f.retail_price ASC
  LIMIT p_limit;
END;
$$;

DROP FUNCTION IF EXISTS get_events_by_performer_public(bigint, integer, integer);
CREATE OR REPLACE FUNCTION get_events_by_performer_public(
  p_performer_id bigint, p_days_ahead integer DEFAULT 60, p_limit integer DEFAULT 25
) RETURNS TABLE (
  event_id bigint, name text, what text, when_local text,
  where_venue text, where_city text, min_price numeric,
  s4k_total_tickets integer, has_seating_chart boolean, popularity numeric
) LANGUAGE sql STABLE AS $$
  SELECT
    e.id, e.name, e.event_type, e.occurs_at_local,
    e.venue_name, e.venue_location, inv.min_price, inv.s4k_total_tickets,
    (e.seating_chart_medium IS NOT NULL AND e.seating_chart_medium <> 'null'
      AND e.seating_chart_medium ILIKE 'http%'),
    coalesce(e.long_term_popularity_score,0) + coalesce(pm.s4k_popularity_boost,0)
  FROM v_s4k_inventoried_events inv
  JOIN events e ON e.id = inv.event_id
  LEFT JOIN performer_metadata pm ON pm.performer_id = e.primary_performer_id
  WHERE (e.primary_performer_id = p_performer_id
         OR p_performer_id = ANY(coalesce(e.performer_ids, ARRAY[]::integer[])))
    AND e.occurs_at_local::timestamptz >= now()
    AND e.occurs_at_local::timestamptz <= now() + (p_days_ahead || ' days')::interval
  ORDER BY e.occurs_at_local LIMIT p_limit;
$$;

DROP FUNCTION IF EXISTS get_events_by_venue_public(bigint, integer, integer);
CREATE OR REPLACE FUNCTION get_events_by_venue_public(
  p_venue_id bigint, p_days_ahead integer DEFAULT 60, p_limit integer DEFAULT 25
) RETURNS TABLE (
  event_id bigint, name text, what text, when_local text,
  where_venue text, where_city text, min_price numeric,
  s4k_total_tickets integer, has_seating_chart boolean, popularity numeric
) LANGUAGE sql STABLE AS $$
  SELECT
    e.id, e.name, e.event_type, e.occurs_at_local,
    e.venue_name, e.venue_location, inv.min_price, inv.s4k_total_tickets,
    (e.seating_chart_medium IS NOT NULL AND e.seating_chart_medium <> 'null'
      AND e.seating_chart_medium ILIKE 'http%'),
    coalesce(e.long_term_popularity_score,0) + coalesce(pm.s4k_popularity_boost,0)
  FROM v_s4k_inventoried_events inv
  JOIN events e ON e.id = inv.event_id
  LEFT JOIN performer_metadata pm ON pm.performer_id = e.primary_performer_id
  WHERE e.venue_id = p_venue_id
    AND e.occurs_at_local::timestamptz >= now()
    AND e.occurs_at_local::timestamptz <= now() + (p_days_ahead || ' days')::interval
  ORDER BY e.occurs_at_local LIMIT p_limit;
$$;

DROP FUNCTION IF EXISTS get_performer_landing_public(bigint);
CREATE OR REPLACE FUNCTION get_performer_landing_public(p_performer_id bigint)
RETURNS TABLE (
  performer_id bigint, name text, slug text,
  category_name text, top_category text, genre text,
  popularity numeric, home_venue_id bigint, home_venue_name text,
  upcoming_first timestamptz, upcoming_last timestamptz
) LANGUAGE sql STABLE AS $$
  SELECT
    pm.performer_id, pm.name, pm.slug,
    pm.category_name, pm.top_category_name, pm.genre,
    coalesce(pm.s4k_popularity_boost, 0) + coalesce(pm.popularity_score, 0),
    hv.venue_id, hv.venue_name, pm.upcoming_first, pm.upcoming_last
  FROM performer_metadata pm
  LEFT JOIN performer_home_venues hv ON hv.performer_id = pm.performer_id
  WHERE pm.performer_id = p_performer_id LIMIT 1;
$$;

-- Initial submit_lead_public (note: superseded by 20260508023700 which drops
-- the bot_messages mirror — keeping this here for migration history accuracy).
DROP FUNCTION IF EXISTS submit_lead_public(bigint, bigint, integer, text, numeric, text, text, text, text, text, text, text, text);
CREATE OR REPLACE FUNCTION submit_lead_public(
  p_event_id bigint,
  p_ticket_group_id bigint DEFAULT NULL,
  p_qty integer DEFAULT NULL,
  p_zone text DEFAULT NULL,
  p_max_price numeric DEFAULT NULL,
  p_budget_basis text DEFAULT NULL,
  p_name text DEFAULT NULL,
  p_email text DEFAULT NULL,
  p_phone text DEFAULT NULL,
  p_notes text DEFAULT NULL,
  p_channel text DEFAULT 'web',
  p_source_url text DEFAULT NULL,
  p_anon_id text DEFAULT NULL
) RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE v_id bigint;
BEGIN
  IF p_event_id IS NULL THEN RAISE EXCEPTION 'event_id required'; END IF;
  IF (p_email IS NULL OR length(trim(p_email)) = 0)
     AND (p_phone IS NULL OR length(trim(p_phone)) = 0) THEN
    RAISE EXCEPTION 'email or phone required';
  END IF;
  INSERT INTO leads (
    event_id, ticket_group_id, qty, zone, max_price, budget_basis,
    name, email, phone, notes, channel, source_url, anon_id
  ) VALUES (
    p_event_id, p_ticket_group_id, p_qty, p_zone, p_max_price, p_budget_basis,
    NULLIF(trim(p_name), ''), NULLIF(trim(lower(p_email)), ''), NULLIF(trim(p_phone), ''),
    NULLIF(trim(p_notes), ''),
    coalesce(p_channel, 'web'), NULLIF(trim(p_source_url), ''), NULLIF(trim(p_anon_id), '')
  ) RETURNING id INTO v_id;
  INSERT INTO bot_messages (channel, direction, phone, body, meta)
  VALUES (
    coalesce(p_channel, 'web'), 'lead',
    coalesce(p_phone, p_email, p_anon_id, 'anon'),
    'Lead: ' || coalesce(p_name, 'anon')
      || ' wants ' || coalesce(p_qty::text, '?') || ' tix for event ' || p_event_id::text
      || coalesce(' in ' || p_zone, '')
      || coalesce(' under $' || p_max_price::text || ' ' || coalesce(p_budget_basis,''), ''),
    jsonb_build_object('lead_id', v_id, 'event_id', p_event_id,
                       'ticket_group_id', p_ticket_group_id, 'qty', p_qty)
  );
  RETURN v_id;
END;
$$;

GRANT EXECUTE ON FUNCTION
  get_event_zones_public(bigint, boolean),
  get_event_listings_public(bigint, text, integer, numeric, integer, boolean),
  get_events_by_performer_public(bigint, integer, integer),
  get_events_by_venue_public(bigint, integer, integer),
  get_performer_landing_public(bigint),
  submit_lead_public(bigint, bigint, integer, text, numeric, text, text, text, text, text, text, text, text)
TO anon, authenticated, service_role;

ALTER TABLE leads ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS leads_anon_insert ON leads;
CREATE POLICY leads_anon_insert ON leads FOR INSERT TO anon WITH CHECK (true);
DROP POLICY IF EXISTS leads_service_all ON leads;
CREATE POLICY leads_service_all ON leads FOR ALL TO service_role USING (true) WITH CHECK (true);
DROP POLICY IF EXISTS leads_authenticated_read ON leads;
CREATE POLICY leads_authenticated_read ON leads FOR SELECT TO authenticated USING (true);
GRANT INSERT ON leads TO anon;
GRANT SELECT, INSERT, UPDATE ON leads TO authenticated, service_role;
GRANT USAGE ON SEQUENCE leads_id_seq TO anon, authenticated, service_role;

COMMENT ON FUNCTION submit_lead_public IS
  'HARD RESTRICT (rule 15): retail leads write here, NOT to TEvo orders. Human rep handles purchase off-platform.';
