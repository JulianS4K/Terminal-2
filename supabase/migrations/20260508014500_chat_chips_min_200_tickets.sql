-- Cowork migration. Captured into git by code (auditor) on 2026-05-08.
-- Originally applied to prod 2026-05-08 01:56 UTC.
--
-- Replaces get_chat_suggestion_chips with a 2-arg variant that filters to
-- events where S4K owns 200+ total tickets (sum of quantity).

DROP FUNCTION IF EXISTS get_chat_suggestion_chips(int);
DROP FUNCTION IF EXISTS get_chat_suggestion_chips(int, int);

CREATE OR REPLACE FUNCTION get_chat_suggestion_chips(
  p_count int DEFAULT 6,
  p_min_tickets int DEFAULT 200
)
RETURNS TABLE (
  event_id bigint, name text, what text, when_local text,
  where_venue text, where_city text, min_price numeric, popularity numeric,
  s4k_listings integer, s4k_total_tickets integer,
  has_seating_chart boolean, suggestion_kind text
) LANGUAGE sql STABLE AS $$
WITH latest_snap AS (
  SELECT ls.event_id, max(ls.captured_at) AS captured_at
  FROM listings_snapshots ls
  WHERE ls.is_owned = true AND ls.is_ancillary = false
    AND (ls.type IS NULL OR ls.type = 'event')
    AND ls.captured_at > now() - interval '24 hours'
  GROUP BY ls.event_id
),
event_inventory AS (
  SELECT ls.event_id, min(ls.retail_price) AS min_price,
    count(*)::int AS s4k_listings, sum(ls.quantity)::int AS s4k_total_tickets
  FROM listings_snapshots ls
  JOIN latest_snap s ON s.event_id = ls.event_id AND s.captured_at = ls.captured_at
  WHERE ls.is_owned = true AND ls.is_ancillary = false
    AND (ls.type IS NULL OR ls.type = 'event') AND ls.retail_price IS NOT NULL
  GROUP BY ls.event_id
  HAVING sum(ls.quantity) >= p_min_tickets
),
candidates AS (
  SELECT e.id AS event_id, e.name, e.event_type AS what,
    e.occurs_at_local AS when_local, e.venue_name AS where_venue, e.venue_location AS where_city,
    ei.min_price, coalesce(e.long_term_popularity_score, 0) AS popularity,
    ei.s4k_listings, ei.s4k_total_tickets,
    (e.seating_chart_medium IS NOT NULL AND e.seating_chart_medium <> 'null'
     AND e.seating_chart_medium ILIKE 'http%') AS has_seating_chart
  FROM event_inventory ei JOIN events e ON e.id = ei.event_id
  WHERE e.occurs_at_local::timestamptz >= now()
    AND e.occurs_at_local::timestamptz <= now() + interval '60 days'
    AND ei.min_price > 0
),
popular  AS (SELECT *, 'popular'::text AS suggestion_kind,  row_number() OVER (ORDER BY popularity DESC, random()) AS rn FROM candidates),
cheap    AS (SELECT *, 'cheap'::text AS suggestion_kind,    row_number() OVER (ORDER BY min_price ASC, random()) AS rn FROM candidates),
wildcard AS (SELECT *, 'wildcard'::text AS suggestion_kind, row_number() OVER (ORDER BY random()) AS rn FROM candidates),
mixed AS (
  SELECT * FROM popular  WHERE rn <= GREATEST(p_count/3, 2)
  UNION SELECT * FROM cheap    WHERE rn <= GREATEST(p_count/3, 2)
  UNION SELECT * FROM wildcard WHERE rn <= GREATEST(p_count/3, 2)
),
deduped AS (SELECT DISTINCT ON (event_id) * FROM mixed
  ORDER BY event_id, CASE suggestion_kind WHEN 'popular' THEN 0 WHEN 'cheap' THEN 1 ELSE 2 END)
SELECT event_id, name, what, when_local, where_venue, where_city,
  min_price, popularity, s4k_listings, s4k_total_tickets,
  has_seating_chart, suggestion_kind
FROM deduped
ORDER BY CASE suggestion_kind WHEN 'popular' THEN 0 WHEN 'cheap' THEN 1 ELSE 2 END,
  popularity DESC, min_price ASC LIMIT p_count;
$$;
GRANT EXECUTE ON FUNCTION get_chat_suggestion_chips(int, int) TO anon, authenticated, service_role;
