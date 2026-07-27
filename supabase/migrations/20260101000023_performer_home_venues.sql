-- Maps performer (sports team) to home venue. Lets chatbot interpret
-- "X at home" / "X home game" → filter events by venue_id.

CREATE TABLE IF NOT EXISTS performer_home_venues (
  performer_id    bigint PRIMARY KEY,
  performer_name  text,
  venue_id        bigint NOT NULL,
  venue_name      text,
  venue_location  text,
  league          text NOT NULL,
  source          text NOT NULL DEFAULT 'tevo',
  set_at          timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS performer_home_venues_venue_idx ON performer_home_venues (venue_id);
CREATE INDEX IF NOT EXISTS performer_home_venues_league_idx ON performer_home_venues (league);

CREATE OR REPLACE VIEW events_with_home_flag AS
SELECT e.*, hv.venue_id IS NOT NULL AND hv.venue_id = e.venue_id AS is_home_game,
       hv.venue_id AS home_venue_id, hv.venue_name AS home_venue_name, hv.league
FROM events e
LEFT JOIN performer_home_venues hv ON hv.performer_id = e.primary_performer_id;
