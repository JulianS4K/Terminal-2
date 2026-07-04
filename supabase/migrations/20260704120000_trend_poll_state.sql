-- Migration 20260704120000 · level:data-collection · lane:a1 · writes:trend_poll_state · reads:cast_price_ref,espn_athletes,performer_metadata,events · pre:20260703210000
-- Google-Trends cast-pool target queue. One row per entity we poll search-interest
-- for: teams/shows (from cast_price_ref → why_signals scope=performer, flows to events)
-- + individual athletes whose team has upcoming events (scope=athlete, informational +
-- future injury star-weighting). Rate-budgeted round-robin by last_polled_at, so the
-- ~thousands of athletes are covered over days without tripping Google's soft-ban.
-- The trends-collect edge fn drains this + writes signal_kind='search_interest'.

CREATE TABLE IF NOT EXISTS trend_poll_state (
  id                bigserial PRIMARY KEY,
  entity_type       text NOT NULL,            -- 'team' | 'show' | 'athlete'
  term              text NOT NULL,            -- the Google-Trends search query
  tevo_performer_id bigint,                   -- team/show → why_signals scope='performer'
  espn_athlete_id   text,                     -- athlete → scope='athlete' (ESPN ids are text)
  espn_league       text,
  priority          int NOT NULL DEFAULT 0,   -- higher = polled sooner (upcoming-event weight)
  active            boolean NOT NULL DEFAULT true,
  last_polled_at    timestamptz,
  last_value        numeric,                  -- last momentum written (-1..1)
  last_status       text,
  created_at        timestamptz NOT NULL DEFAULT now(),
  UNIQUE (entity_type, term)
);
-- drain order: active, highest priority, least-recently polled first
CREATE INDEX IF NOT EXISTS trend_poll_due_idx
  ON trend_poll_state (active, priority DESC, last_polled_at NULLS FIRST);

-- Rebuild/refresh the target set. Teams+shows always; athletes only where their team
-- has an upcoming event (keeps the pool relevant + bounded).
CREATE OR REPLACE FUNCTION seed_trend_poll_state() RETURNS integer
LANGUAGE plpgsql AS $$
DECLARE n integer;
BEGIN
  -- upcoming-event weight per performer (home games in the next 90d)
  WITH up AS (
    SELECT primary_performer_id pid, count(*) ev
    FROM events
    WHERE occurs_at_local::timestamptz BETWEEN now() AND now() + interval '90 days'
    GROUP BY primary_performer_id
  ),
  teams_shows AS (
    SELECT c.entity_type, c.entity_name AS term, c.tevo_performer_id,
           NULL::text AS espn_athlete_id, c.league AS espn_league,
           100 + COALESCE(u.ev,0) AS priority
    FROM cast_price_ref c
    LEFT JOIN up u ON u.pid = c.tevo_performer_id
  ),
  athletes AS (
    SELECT 'athlete'::text entity_type, a.full_name AS term,
           NULL::bigint AS tevo_performer_id, a.espn_athlete_id, a.espn_league,
           50 + COALESCE(u.ev,0) AS priority
    FROM espn_athletes a
    JOIN performer_metadata pm ON pm.espn_team_id = a.espn_team_id
    JOIN up u ON u.pid = pm.performer_id            -- only athletes whose team plays soon
    WHERE a.full_name IS NOT NULL
      AND lower(coalesce(a.status,'active')) NOT IN ('inactive','retired')
  )
  INSERT INTO trend_poll_state (entity_type, term, tevo_performer_id, espn_athlete_id, espn_league, priority)
  SELECT DISTINCT ON (entity_type, term)
         entity_type, term, tevo_performer_id, espn_athlete_id, espn_league, priority
  FROM (SELECT * FROM teams_shows UNION ALL SELECT * FROM athletes) s
  WHERE term <> ''
  ORDER BY entity_type, term, priority DESC   -- collapse same-name dups, keep highest priority
  ON CONFLICT (entity_type, term) DO UPDATE SET
     tevo_performer_id = EXCLUDED.tevo_performer_id,
     espn_athlete_id   = EXCLUDED.espn_athlete_id,
     espn_league       = EXCLUDED.espn_league,
     priority          = EXCLUDED.priority,
     active            = true;
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END;
$$;
