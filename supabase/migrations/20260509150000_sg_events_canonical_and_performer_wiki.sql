-- ============================================================================
-- Migration 20260509150000 — SG events canonical + performer Wikipedia map
--
-- (a) sg_events_canonical: one row per SG event we have data on. Decoupled
--     from seatgeek_event_xref (which requires tevo_event_id NOT NULL by
--     design). Lets us track SG-only events that have no TEvo equivalent
--     yet, and gives the auto-matcher a stable surface to iterate over.
--
-- (b) performer_wikipedia: one row per TEvo performer mapping to a
--     Wikipedia article. Read-only — Wikipedia REST API is public, no auth.
--     Used to enrich performer pages (description, image, infobox extracts)
--     and seed sentiment search corpora.
--
-- (c) sg_canonical_match_view: convenience view joining canonical SG events
--     to TEvo events via seatgeek_event_xref. NULL tevo_event_id = unmatched.
-- ============================================================================

CREATE TABLE IF NOT EXISTS sg_events_canonical (
  sg_event_id        bigint PRIMARY KEY,
  sg_event_name      text NOT NULL,
  sg_event_date      date,
  sg_datetime_utc    timestamptz,
  sg_category        text,
  sg_url             text,
  sg_venue_id        bigint,
  sg_venue_name      text,
  sg_venue_city      text,
  sg_venue_state     text,
  sg_venue_country   text,
  sg_venue_address   text,
  has_seller_listings    boolean DEFAULT false,
  has_v2_listings_pulled boolean DEFAULT false,
  last_v2_pull_at        timestamptz,
  last_v2_status         int,
  last_v2_listings_count int,
  tevo_event_id      bigint REFERENCES events(id),
  match_method       text,
  match_confidence   numeric(3,2),
  matched_at         timestamptz,
  raw_event_jsonb    jsonb,
  created_at         timestamptz DEFAULT now(),
  updated_at         timestamptz DEFAULT now()
);

CREATE INDEX IF NOT EXISTS sg_events_canonical_tevo_idx
  ON sg_events_canonical(tevo_event_id) WHERE tevo_event_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS sg_events_canonical_unmatched_idx
  ON sg_events_canonical(sg_event_date) WHERE tevo_event_id IS NULL;
CREATE INDEX IF NOT EXISTS sg_events_canonical_category_idx
  ON sg_events_canonical(sg_category, sg_event_date);

COMMENT ON TABLE sg_events_canonical IS
  'One row per SG event we have ANY data on. tevo_event_id NULL = unmatched. '
  'Auto-matcher iterates this table to fill links over time.';

CREATE TABLE IF NOT EXISTS performer_wikipedia (
  tevo_performer_id  bigint PRIMARY KEY,
  performer_name     text NOT NULL,
  wiki_title         text,
  wiki_pageid        bigint,
  wiki_url           text,
  wiki_lang          text DEFAULT 'en',
  description        text,
  extract            text,
  image_url          text,
  match_confidence   numeric(3,2),
  match_method       text,
  is_rejected        boolean DEFAULT false,
  reject_reason      text,
  last_refreshed_at  timestamptz,
  raw_summary_jsonb  jsonb,
  created_at         timestamptz DEFAULT now(),
  updated_at         timestamptz DEFAULT now()
);

CREATE INDEX IF NOT EXISTS performer_wikipedia_name_idx
  ON performer_wikipedia (lower(performer_name));
CREATE INDEX IF NOT EXISTS performer_wikipedia_unmatched_idx
  ON performer_wikipedia (tevo_performer_id) WHERE wiki_pageid IS NULL AND NOT is_rejected;

COMMENT ON TABLE performer_wikipedia IS
  'TEvo performer -> Wikipedia article mapping. Read-only Wikipedia REST API.';

CREATE OR REPLACE VIEW sg_canonical_match_view AS
SELECT
  sgc.sg_event_id, sgc.sg_event_name, sgc.sg_event_date, sgc.sg_category,
  sgc.sg_venue_name, sgc.tevo_event_id,
  e.name              AS tevo_name,
  e.venue_name        AS tevo_venue,
  e.occurs_at_local::date AS tevo_date,
  e.event_type        AS tevo_event_type,
  sgc.match_method, sgc.match_confidence, sgc.matched_at,
  sgc.has_seller_listings, sgc.last_v2_pull_at,
  CASE
    WHEN sgc.tevo_event_id IS NOT NULL THEN 'matched'
    WHEN sgc.sg_event_date < current_date THEN 'past_unmatched'
    ELSE 'pending_match'
  END AS match_status
FROM sg_events_canonical sgc
LEFT JOIN events e ON e.id = sgc.tevo_event_id;

COMMENT ON VIEW sg_canonical_match_view IS
  'Single-row-per-SG-event view with TEvo match details + status bucket.';
