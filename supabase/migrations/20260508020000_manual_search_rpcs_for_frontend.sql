-- 20260508020000_manual_search_rpcs_for_frontend.sql
-- Captured from prod (copilot, applied as version 20260508025555).
-- Captured into git 2026-05-08 by code via audit-and-commit.
--
-- Backend RPCs for the manual-search dropdowns below the chat box.
-- Frontend wires these to a "Performer:" + "Date:" express-lane row.
--
-- NOTE: a later migration (20260508021000_s4k_inventory_only_filters) DROPs
-- and replaces both search_performers_typeahead and search_performers_for_chat
-- with new signatures that include sellable_events_count. This migration
-- captures the version that landed at 20260508025555 — historically accurate.

-- 1. Performer typeahead — what users type in 'Performer:' input
CREATE OR REPLACE FUNCTION search_performers_typeahead(
  p_query text,
  p_limit int DEFAULT 8
) RETURNS TABLE (
  performer_id bigint,
  display_name text,
  alias_kind text,
  league text,
  popularity numeric,
  has_upcoming boolean
) LANGUAGE sql STABLE AS $$
  WITH matches AS (
    SELECT
      a.performer_id, a.display_name, a.alias_kind, a.league,
      coalesce(pm.s4k_popularity_boost, 0) + coalesce(pm.popularity_score, 0) AS popularity,
      EXISTS (SELECT 1 FROM events e
              WHERE (e.primary_performer_id = a.performer_id
                     OR a.performer_id = ANY(coalesce(e.performer_ids, ARRAY[]::integer[])))
                AND e.occurs_at_local::timestamptz >= now()) AS has_upcoming
    FROM chat_aliases a
    LEFT JOIN performer_metadata pm ON pm.performer_id = a.performer_id
    WHERE a.performer_id IS NOT NULL
      AND a.alias_kind IN ('performer','athlete','tournament')
      AND (a.alias_norm ILIKE p_query || '%'
           OR lower(a.display_name) ILIKE '%' || lower(p_query) || '%')
  )
  SELECT DISTINCT ON (performer_id)
    performer_id, display_name, alias_kind, league, popularity, has_upcoming
  FROM matches
  ORDER BY performer_id, has_upcoming DESC, popularity DESC
  LIMIT p_limit * 3;
$$;

CREATE OR REPLACE FUNCTION search_performers_for_chat(
  p_query text,
  p_limit int DEFAULT 8
) RETURNS TABLE (
  performer_id bigint,
  display_name text,
  alias_kind text,
  league text,
  popularity numeric,
  has_upcoming boolean
) LANGUAGE sql STABLE AS $$
  SELECT * FROM search_performers_typeahead(p_query, p_limit)
  ORDER BY has_upcoming DESC, popularity DESC NULLS LAST
  LIMIT p_limit;
$$;

-- 2. Date-anchored event finder
CREATE OR REPLACE FUNCTION search_events_by_date(
  p_date_from date,
  p_date_to   date DEFAULT NULL,
  p_performer_id bigint DEFAULT NULL,
  p_city text DEFAULT NULL,
  p_min_tickets int DEFAULT 1,
  p_limit int DEFAULT 20
) RETURNS TABLE (
  event_id bigint,
  name text,
  what text,
  when_local text,
  where_venue text,
  where_city text,
  min_price numeric,
  s4k_total_tickets integer,
  has_seating_chart boolean,
  popularity numeric
) LANGUAGE sql STABLE AS $$
  WITH latest_snap AS (
    SELECT ls.event_id, max(ls.captured_at) AS captured_at
    FROM listings_snapshots ls
    WHERE ls.is_owned = true AND ls.is_ancillary = false
      AND (ls.type IS NULL OR ls.type='event')
      AND ls.captured_at > now() - interval '24 hours'
    GROUP BY ls.event_id
  ),
  inv AS (
    SELECT ls.event_id, min(ls.retail_price) AS min_price,
           sum(ls.quantity)::int AS s4k_total_tickets
    FROM listings_snapshots ls
    JOIN latest_snap s USING (event_id)
    WHERE ls.captured_at = s.captured_at
      AND ls.is_owned = true AND ls.is_ancillary = false
      AND (ls.type IS NULL OR ls.type='event')
      AND ls.retail_price IS NOT NULL
    GROUP BY ls.event_id
    HAVING sum(ls.quantity) >= p_min_tickets
  )
  SELECT
    e.id, e.name, e.event_type AS what, e.occurs_at_local AS when_local,
    e.venue_name AS where_venue, e.venue_location AS where_city,
    inv.min_price, inv.s4k_total_tickets,
    (e.seating_chart_medium IS NOT NULL AND e.seating_chart_medium <> 'null'
      AND e.seating_chart_medium ILIKE 'http%') AS has_seating_chart,
    coalesce(e.long_term_popularity_score,0) + coalesce(pm.s4k_popularity_boost,0) AS popularity
  FROM inv
  JOIN events e ON e.id = inv.event_id
  LEFT JOIN performer_metadata pm ON pm.performer_id = e.primary_performer_id
  WHERE e.occurs_at_local::timestamptz >= p_date_from
    AND e.occurs_at_local::timestamptz <= COALESCE(p_date_to, p_date_from + interval '1 day')
    AND (p_performer_id IS NULL
         OR e.primary_performer_id = p_performer_id
         OR p_performer_id = ANY(coalesce(e.performer_ids, ARRAY[]::integer[])))
    AND (p_city IS NULL
         OR e.venue_location ILIKE '%' || p_city || '%')
  ORDER BY popularity DESC, inv.s4k_total_tickets DESC
  LIMIT p_limit;
$$;

GRANT EXECUTE ON FUNCTION search_performers_typeahead(text,int),
                          search_performers_for_chat(text,int),
                          search_events_by_date(date,date,bigint,text,int,int)
  TO anon, authenticated, service_role;

COMMENT ON FUNCTION search_performers_for_chat IS
  'Powers the manual "Performer:" typeahead below chat. Sorts has_upcoming DESC, popularity DESC. Returns teams, athletes (route to team), tournaments.';
COMMENT ON FUNCTION search_events_by_date IS
  'Powers the manual "Date:" picker below chat. Optionally narrowed by performer/city. Returns S4K-inventoried events sorted by popularity.';
