-- 20260508019000_s4k_popularity_boost_and_athlete_aliases.sql
-- Captured from prod (copilot, applied as version 20260508023948).
-- Captured into git 2026-05-08 by code via audit-and-commit (copilot has no
-- direct git push; chat-side schema lands here via code's proxy).
--
-- (a) S4K popularity boost: performers at big-5-league venues sort first.
-- (b) ESPN athlete names → chat_aliases as alias_kind='athlete', mapped to
--     team's performer_id so 'lebron' search routes to LAL upcoming events.

-- ---- 1. Add s4k_popularity_boost to performer_metadata --------------------------
ALTER TABLE performer_metadata
  ADD COLUMN IF NOT EXISTS s4k_popularity_boost numeric DEFAULT 0;

CREATE INDEX IF NOT EXISTS performer_metadata_boost_idx
  ON performer_metadata ((coalesce(s4k_popularity_boost,0) + coalesce(popularity_score,0)) DESC);

-- ---- 2. Mark big-5 venues + apply boost to ALL performers there ---------------
WITH big5_venues AS (
  SELECT DISTINCT venue_id
  FROM performer_home_venues
  WHERE league IN ('NBA','NFL','MLB','NHL','MLS','WNBA')
),
performers_at_big5 AS (
  SELECT DISTINCT performer_id FROM (
    SELECT primary_performer_id AS performer_id FROM events
      WHERE venue_id IN (SELECT venue_id FROM big5_venues) AND primary_performer_id IS NOT NULL
    UNION
    SELECT unnest(performer_ids) AS performer_id FROM events
      WHERE venue_id IN (SELECT venue_id FROM big5_venues) AND performer_ids IS NOT NULL
  ) p
)
UPDATE performer_metadata pm
SET s4k_popularity_boost = 10
FROM performers_at_big5 b
WHERE pm.performer_id = b.performer_id
  AND coalesce(pm.s4k_popularity_boost, 0) < 10;

-- ---- 3. Expand chat_aliases CHECK to allow 'athlete' kind ----------------------
ALTER TABLE chat_aliases DROP CONSTRAINT IF EXISTS chat_aliases_alias_kind_check;
ALTER TABLE chat_aliases ADD CONSTRAINT chat_aliases_alias_kind_check
  CHECK (alias_kind = ANY (ARRAY[
    'performer'::text, 'venue'::text, 'city'::text, 'zone'::text,
    'league'::text, 'tournament'::text,
    'date'::text, 'selection'::text, 'navigate'::text,
    'budget_basis'::text, 'price_op'::text, 'sort'::text,
    'event_type'::text,
    'athlete'::text
  ]));

-- ---- 4. Bridge: ESPN athlete → TEvo performer via team_xref --------------------
INSERT INTO chat_aliases (alias_norm, alias_kind, performer_id, display_name, league, source)
SELECT DISTINCT ON (alias_norm, performer_id)
  lower(trim(a.full_name))                AS alias_norm,
  'athlete'                               AS alias_kind,
  tx.tevo_performer_id                    AS performer_id,
  a.display_name                          AS display_name,
  a.espn_league                           AS league,
  'espn_roster'                           AS source
FROM espn_athletes a
JOIN team_xref tx ON tx.espn_team_id = a.espn_team_id AND tx.espn_league = a.espn_league
WHERE a.full_name IS NOT NULL
  AND length(a.full_name) >= 4
  AND tx.tevo_performer_id IS NOT NULL
  AND a.status = 'active'
ON CONFLICT DO NOTHING;

-- Last-name short alias (e.g. 'lebron james' → 'james'). Skip surnames < 4 chars
-- and surnames likely to collide with common words.
INSERT INTO chat_aliases (alias_norm, alias_kind, performer_id, display_name, league, source)
SELECT DISTINCT ON (alias_norm, performer_id)
  lower(trim(regexp_replace(a.full_name, '^.*\s(\S+)$', '\1'))) AS alias_norm,
  'athlete'                               AS alias_kind,
  tx.tevo_performer_id                    AS performer_id,
  a.display_name                          AS display_name,
  a.espn_league                           AS league,
  'espn_roster_short'                     AS source
FROM espn_athletes a
JOIN team_xref tx ON tx.espn_team_id = a.espn_team_id AND tx.espn_league = a.espn_league
WHERE a.full_name IS NOT NULL
  AND length(a.full_name) >= 4
  AND tx.tevo_performer_id IS NOT NULL
  AND a.status = 'active'
  AND length(regexp_replace(a.full_name, '^.*\s(\S+)$', '\1')) >= 4
  AND lower(regexp_replace(a.full_name, '^.*\s(\S+)$', '\1')) NOT IN
    ('jr','sr','ii','iii','iv','jr.','sr.','smith','jones','williams','brown','davis','miller','wilson','moore','taylor','anderson','thomas','jackson','white','harris','martin','thompson','garcia','martinez','robinson','clark','rodriguez','lewis','lee','walker','hall','allen','young','hernandez','king','wright','lopez','hill','scott','green','adams','baker','gonzalez','nelson','carter','mitchell','perez','roberts','turner','phillips','campbell','parker','evans','edwards','collins','stewart','sanchez','morris','rogers','reed','cook','morgan','bell','murphy','bailey','rivera','cooper','richardson','cox','howard','ward','torres','peterson','gray','ramirez','james','watson','brooks','kelly','sanders','price','bennett','wood','barnes','ross','henderson','coleman','jenkins','perry','powell','long','patterson','hughes','flores','washington','butler','simmons','foster','gonzales','bryant','alexander','russell','griffin','diaz','hayes')
ON CONFLICT DO NOTHING;

-- ---- 5. Update suggestion chips RPC to use combined boost + popularity ---------
DROP FUNCTION IF EXISTS get_chat_suggestion_chips(int, int);
CREATE OR REPLACE FUNCTION get_chat_suggestion_chips(
  p_count int DEFAULT 6,
  p_min_tickets int DEFAULT 200
)
RETURNS TABLE (
  event_id              bigint,
  name                  text,
  what                  text,
  when_local            text,
  where_venue           text,
  where_city            text,
  min_price             numeric,
  popularity            numeric,
  s4k_listings          integer,
  s4k_total_tickets     integer,
  has_seating_chart     boolean,
  suggestion_kind       text
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
  SELECT
    ls.event_id,
    min(ls.retail_price) AS min_price,
    count(*)::int AS s4k_listings,
    sum(ls.quantity)::int AS s4k_total_tickets
  FROM listings_snapshots ls
  JOIN latest_snap s ON s.event_id = ls.event_id AND s.captured_at = ls.captured_at
  WHERE ls.is_owned = true AND ls.is_ancillary = false
    AND (ls.type IS NULL OR ls.type = 'event')
    AND ls.retail_price IS NOT NULL
  GROUP BY ls.event_id
  HAVING sum(ls.quantity) >= p_min_tickets
),
candidates AS (
  SELECT
    e.id AS event_id, e.name, e.event_type AS what,
    e.occurs_at_local AS when_local,
    e.venue_name AS where_venue, e.venue_location AS where_city,
    ei.min_price,
    coalesce(e.long_term_popularity_score, 0)
      + coalesce(pm.s4k_popularity_boost, 0)
      + coalesce(pm.popularity_score, 0)            AS popularity,
    ei.s4k_listings, ei.s4k_total_tickets,
    (e.seating_chart_medium IS NOT NULL
      AND e.seating_chart_medium <> 'null'
      AND e.seating_chart_medium ILIKE 'http%') AS has_seating_chart
  FROM event_inventory ei
  JOIN events e ON e.id = ei.event_id
  LEFT JOIN performer_metadata pm ON pm.performer_id = e.primary_performer_id
  WHERE e.occurs_at_local::timestamptz >= now()
    AND e.occurs_at_local::timestamptz <= now() + interval '60 days'
    AND ei.min_price > 0
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
  SELECT DISTINCT ON (event_id) *
  FROM mixed
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

GRANT EXECUTE ON FUNCTION get_chat_suggestion_chips(int, int) TO anon, authenticated, service_role;

COMMENT ON COLUMN performer_metadata.s4k_popularity_boost IS
  'S4K-internal sort priority. Default 0. Set to 10 for performers at NBA/NFL/MLB/NHL/MLS/WNBA venues. Sums with TEvo popularity_score for ranking.';
