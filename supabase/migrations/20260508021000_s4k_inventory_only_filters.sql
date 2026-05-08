-- 20260508021000_s4k_inventory_only_filters.sql
-- Captured from prod (cowork) — applied as version 20260508030004
--
-- Canonical "events S4K can sell" filter for retail surfaces. Every chat/web
-- RPC must join through v_s4k_inventoried_events to hide events we cannot
-- sell. Recreates search_performers_for_chat / search_performers_typeahead /
-- search_events_by_date / get_chat_suggestion_chips with the new filter, plus
-- adds event_has_s4k_inventory() predicate for chat fn to filter RESOLVED_CONTEXT.

-- Drop existing functions before recreating with new signatures
DROP FUNCTION IF EXISTS search_performers_for_chat(text, int);
DROP FUNCTION IF EXISTS search_performers_typeahead(text, int);
DROP FUNCTION IF EXISTS search_events_by_date(date, date, bigint, text, int, int);
DROP FUNCTION IF EXISTS get_chat_suggestion_chips(int, int);

-- Canonical "events S4K can sell" view
CREATE OR REPLACE VIEW v_s4k_inventoried_events AS
WITH latest_snap AS (
  SELECT ls.event_id, max(ls.captured_at) AS captured_at
  FROM listings_snapshots ls
  WHERE ls.is_owned = true AND ls.is_ancillary = false
    AND (ls.type IS NULL OR ls.type = 'event')
    AND ls.captured_at > now() - interval '24 hours'
  GROUP BY ls.event_id
)
SELECT
  ls.event_id,
  max(ls.captured_at) AS latest_snap_at,
  count(*)::int AS s4k_listings,
  sum(ls.quantity)::int AS s4k_total_tickets,
  min(ls.retail_price) AS min_price,
  max(ls.retail_price) AS max_price,
  percentile_cont(0.5) WITHIN GROUP (ORDER BY ls.retail_price) AS median_price
FROM listings_snapshots ls
JOIN latest_snap s USING (event_id)
WHERE ls.captured_at = s.captured_at
  AND ls.is_owned = true AND ls.is_ancillary = false
  AND (ls.type IS NULL OR ls.type = 'event')
  AND ls.retail_price IS NOT NULL AND ls.retail_price > 0
GROUP BY ls.event_id;

COMMENT ON VIEW v_s4k_inventoried_events IS
  'CANONICAL filter for retail surfaces: events S4K actually has tickets for (latest snapshot in last 24h). Every chat/web RPC must join through this to hide events we cannot sell.';

CREATE OR REPLACE FUNCTION search_performers_for_chat(
  p_query text, p_limit int DEFAULT 8
) RETURNS TABLE (
  performer_id bigint, display_name text, alias_kind text, league text,
  popularity numeric, has_upcoming boolean, sellable_events_count integer
) LANGUAGE sql STABLE AS $$
  WITH matches AS (
    SELECT
      a.performer_id, a.display_name, a.alias_kind, a.league,
      coalesce(pm.s4k_popularity_boost, 0) + coalesce(pm.popularity_score, 0) AS popularity,
      (SELECT count(*)::int FROM events e
       JOIN v_s4k_inventoried_events s ON s.event_id = e.id
       WHERE (e.primary_performer_id = a.performer_id
              OR a.performer_id = ANY(coalesce(e.performer_ids, ARRAY[]::integer[])))
         AND e.occurs_at_local::timestamptz >= now()) AS sellable_events_count
    FROM chat_aliases a
    LEFT JOIN performer_metadata pm ON pm.performer_id = a.performer_id
    WHERE a.performer_id IS NOT NULL
      AND a.alias_kind IN ('performer','athlete','tournament')
      AND (a.alias_norm ILIKE p_query || '%'
           OR lower(a.display_name) ILIKE '%' || lower(p_query) || '%')
  )
  SELECT DISTINCT ON (performer_id)
    performer_id, display_name, alias_kind, league, popularity,
    (sellable_events_count > 0) AS has_upcoming,
    sellable_events_count
  FROM matches
  WHERE sellable_events_count > 0
  ORDER BY performer_id, popularity DESC NULLS LAST
  LIMIT p_limit * 3;
$$;

CREATE OR REPLACE FUNCTION search_performers_typeahead(
  p_query text, p_limit int DEFAULT 8
) RETURNS TABLE (
  performer_id bigint, display_name text, alias_kind text, league text,
  popularity numeric, has_upcoming boolean, sellable_events_count integer
) LANGUAGE sql STABLE AS $$
  SELECT * FROM search_performers_for_chat(p_query, p_limit)
  ORDER BY sellable_events_count DESC, popularity DESC NULLS LAST
  LIMIT p_limit;
$$;

CREATE OR REPLACE FUNCTION search_events_by_date(
  p_date_from date, p_date_to date DEFAULT NULL,
  p_performer_id bigint DEFAULT NULL, p_city text DEFAULT NULL,
  p_min_tickets int DEFAULT 1, p_limit int DEFAULT 20
) RETURNS TABLE (
  event_id bigint, name text, what text, when_local text,
  where_venue text, where_city text, min_price numeric,
  s4k_total_tickets integer, has_seating_chart boolean, popularity numeric
) LANGUAGE sql STABLE AS $$
  SELECT
    e.id, e.name, e.event_type AS what, e.occurs_at_local AS when_local,
    e.venue_name AS where_venue, e.venue_location AS where_city,
    inv.min_price, inv.s4k_total_tickets,
    (e.seating_chart_medium IS NOT NULL AND e.seating_chart_medium <> 'null'
      AND e.seating_chart_medium ILIKE 'http%') AS has_seating_chart,
    coalesce(e.long_term_popularity_score,0) + coalesce(pm.s4k_popularity_boost,0) AS popularity
  FROM v_s4k_inventoried_events inv
  JOIN events e ON e.id = inv.event_id
  LEFT JOIN performer_metadata pm ON pm.performer_id = e.primary_performer_id
  WHERE e.occurs_at_local::timestamptz >= p_date_from
    AND e.occurs_at_local::timestamptz <= COALESCE(p_date_to, p_date_from + interval '1 day')
    AND inv.s4k_total_tickets >= p_min_tickets
    AND (p_performer_id IS NULL
         OR e.primary_performer_id = p_performer_id
         OR p_performer_id = ANY(coalesce(e.performer_ids, ARRAY[]::integer[])))
    AND (p_city IS NULL OR e.venue_location ILIKE '%' || p_city || '%')
  ORDER BY popularity DESC, inv.s4k_total_tickets DESC
  LIMIT p_limit;
$$;

CREATE OR REPLACE FUNCTION get_chat_suggestion_chips(
  p_count int DEFAULT 6, p_min_tickets int DEFAULT 200
) RETURNS TABLE (
  event_id bigint, name text, what text, when_local text,
  where_venue text, where_city text, min_price numeric, popularity numeric,
  s4k_listings integer, s4k_total_tickets integer,
  has_seating_chart boolean, suggestion_kind text
) LANGUAGE sql STABLE AS $$
WITH candidates AS (
  SELECT
    e.id AS event_id, e.name, e.event_type AS what,
    e.occurs_at_local AS when_local, e.venue_name AS where_venue,
    e.venue_location AS where_city, inv.min_price,
    coalesce(e.long_term_popularity_score, 0)
      + coalesce(pm.s4k_popularity_boost, 0)
      + coalesce(pm.popularity_score, 0)            AS popularity,
    inv.s4k_listings, inv.s4k_total_tickets,
    (e.seating_chart_medium IS NOT NULL AND e.seating_chart_medium <> 'null'
      AND e.seating_chart_medium ILIKE 'http%') AS has_seating_chart
  FROM v_s4k_inventoried_events inv
  JOIN events e ON e.id = inv.event_id
  LEFT JOIN performer_metadata pm ON pm.performer_id = e.primary_performer_id
  WHERE e.occurs_at_local::timestamptz >= now()
    AND e.occurs_at_local::timestamptz <= now() + interval '60 days'
    AND inv.s4k_total_tickets >= p_min_tickets
),
popular  AS (SELECT *, 'popular'::text  AS suggestion_kind, row_number() OVER (ORDER BY popularity DESC, random()) AS rn FROM candidates),
cheap    AS (SELECT *, 'cheap'::text    AS suggestion_kind, row_number() OVER (ORDER BY min_price ASC, random()) AS rn FROM candidates),
wildcard AS (SELECT *, 'wildcard'::text AS suggestion_kind, row_number() OVER (ORDER BY random()) AS rn FROM candidates),
mixed AS (
  SELECT * FROM popular  WHERE rn <= GREATEST(p_count/3, 2)
  UNION SELECT * FROM cheap    WHERE rn <= GREATEST(p_count/3, 2)
  UNION SELECT * FROM wildcard WHERE rn <= GREATEST(p_count/3, 2)
),
deduped AS (
  SELECT DISTINCT ON (event_id) * FROM mixed
  ORDER BY event_id, CASE suggestion_kind WHEN 'popular' THEN 0 WHEN 'cheap' THEN 1 ELSE 2 END
)
SELECT event_id, name, what, when_local, where_venue, where_city,
       min_price, popularity, s4k_listings, s4k_total_tickets,
       has_seating_chart, suggestion_kind
FROM deduped
ORDER BY CASE suggestion_kind WHEN 'popular' THEN 0 WHEN 'cheap' THEN 1 ELSE 2 END,
         popularity DESC, min_price ASC
LIMIT p_count;
$$;

CREATE OR REPLACE FUNCTION event_has_s4k_inventory(p_event_id bigint, p_min_tickets int DEFAULT 1)
RETURNS boolean LANGUAGE sql STABLE AS $$
  SELECT EXISTS (SELECT 1 FROM v_s4k_inventoried_events
                 WHERE event_id = p_event_id AND s4k_total_tickets >= p_min_tickets);
$$;

GRANT SELECT ON v_s4k_inventoried_events TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION search_performers_for_chat(text,int),
                          search_performers_typeahead(text,int),
                          search_events_by_date(date,date,bigint,text,int,int),
                          get_chat_suggestion_chips(int,int),
                          event_has_s4k_inventory(bigint,int)
  TO anon, authenticated, service_role;

COMMENT ON FUNCTION event_has_s4k_inventory IS
  'Cheap predicate. Used by chat fn (next session) to filter RESOLVED_CONTEXT / COMPREHENSIVE_SEARCH_CONTEXT before surfacing — events without S4K inventory get hidden.';
