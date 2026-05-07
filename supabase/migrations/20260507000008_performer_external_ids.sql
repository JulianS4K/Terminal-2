-- Foundational join table for external feeds (ESPN, Odds API, SportsDataIO).
-- Maps TEvo performer_id (canonical) to external source IDs.

CREATE TABLE IF NOT EXISTS performer_external_ids (
  performer_id  bigint NOT NULL,
  source        text   NOT NULL,
  external_id   text   NOT NULL,
  external_name text,
  league        text,
  meta          jsonb  DEFAULT '{}'::jsonb,
  set_at        timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (performer_id, source)
);
CREATE INDEX IF NOT EXISTS performer_external_ids_source_idx ON performer_external_ids (source, external_id);
CREATE INDEX IF NOT EXISTS performer_external_ids_league_idx ON performer_external_ids (league, source);
