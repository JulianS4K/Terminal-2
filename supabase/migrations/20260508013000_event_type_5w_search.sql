-- Cowork migration. Captured into git by code (auditor) on 2026-05-08.
-- Originally applied to prod 2026-05-08 01:52 UTC.
--
-- v28 5W search structure: WHAT/WHEN/WHO/WHERE/WHY.

DELETE FROM chat_stopwords WHERE word IN ('show','game');

ALTER TABLE chat_aliases DROP CONSTRAINT IF EXISTS chat_aliases_alias_kind_check;
ALTER TABLE chat_aliases ADD CONSTRAINT chat_aliases_alias_kind_check
  CHECK (alias_kind = ANY (ARRAY[
    'performer'::text, 'venue'::text, 'city'::text, 'zone'::text,
    'league'::text, 'tournament'::text,
    'date'::text, 'selection'::text, 'navigate'::text,
    'budget_basis'::text, 'price_op'::text, 'sort'::text,
    'event_type'::text
  ]));

INSERT INTO chat_aliases (alias_norm, alias_kind, display_name, source) VALUES
  ('game','event_type','game','event_type_seed'), ('games','event_type','game','event_type_seed'),
  ('match','event_type','game','event_type_seed'), ('matchup','event_type','game','event_type_seed'),
  ('matchups','event_type','game','event_type_seed'), ('basketball','event_type','game','event_type_seed'),
  ('football','event_type','game','event_type_seed'), ('baseball','event_type','game','event_type_seed'),
  ('hockey','event_type','game','event_type_seed'), ('soccer','event_type','game','event_type_seed'),
  ('sports','event_type','game','event_type_seed'), ('playoff','event_type','game','event_type_seed'),
  ('playoffs','event_type','game','event_type_seed'), ('finals','event_type','game','event_type_seed'),
  ('concert','event_type','concert','event_type_seed'), ('concerts','event_type','concert','event_type_seed'),
  ('music','event_type','concert','event_type_seed'), ('tour','event_type','concert','event_type_seed'),
  ('tours','event_type','concert','event_type_seed'), ('live music','event_type','concert','event_type_seed'),
  ('gig','event_type','concert','event_type_seed'), ('gigs','event_type','concert','event_type_seed'),
  ('residency','event_type','concert','event_type_seed'),
  ('festival','event_type','festival','event_type_seed'), ('festivals','event_type','festival','event_type_seed'),
  ('comedy','event_type','comedy','event_type_seed'), ('comedian','event_type','comedy','event_type_seed'),
  ('standup','event_type','comedy','event_type_seed'), ('stand up','event_type','comedy','event_type_seed'),
  ('stand-up','event_type','comedy','event_type_seed'),
  ('show','event_type','show','event_type_seed'), ('shows','event_type','show','event_type_seed'),
  ('theater','event_type','show','event_type_seed'), ('theatre','event_type','show','event_type_seed'),
  ('musical','event_type','show','event_type_seed'), ('musicals','event_type','show','event_type_seed'),
  ('broadway','event_type','show','event_type_seed'), ('play','event_type','show','event_type_seed'),
  ('plays','event_type','show','event_type_seed'), ('opera','event_type','show','event_type_seed'),
  ('family','event_type','family','event_type_seed'), ('kids','event_type','family','event_type_seed'),
  ('disney','event_type','family','event_type_seed'), ('circus','event_type','family','event_type_seed'),
  ('ice show','event_type','family','event_type_seed'), ('monster truck','event_type','family','event_type_seed')
ON CONFLICT DO NOTHING;

ALTER TABLE events ADD COLUMN IF NOT EXISTS event_type text;
CREATE INDEX IF NOT EXISTS events_event_type_idx ON events (event_type);

UPDATE events e
SET event_type = CASE
  WHEN EXISTS (
    SELECT 1 FROM performer_external_ids pei
    WHERE pei.source = 'espn'
      AND pei.league IN ('NBA','WNBA','NFL','MLB','NHL','MLS','World Cup','NCAAF','NCAAM')
      AND (pei.performer_id = e.primary_performer_id
           OR pei.performer_id = ANY(COALESCE(e.performer_ids, ARRAY[]::integer[])))
  ) THEN 'game'
  WHEN e.name ILIKE '%comedy%' OR e.name ILIKE '%comedian%' OR e.name ILIKE '%standup%' THEN 'comedy'
  WHEN e.name ILIKE '%musical%' OR e.name ILIKE '%broadway%' OR e.name ILIKE '%opera%'
       OR e.name ILIKE '%theater%' OR e.name ILIKE '%theatre%' THEN 'show'
  WHEN e.name ILIKE '%disney%' OR e.name ILIKE '%circus%' OR e.name ILIKE '%monster jam%'
       OR e.name ILIKE '%ice show%' OR e.name ILIKE '%paw patrol%' THEN 'family'
  WHEN e.name ILIKE '%festival%' OR e.name ILIKE '%fest %' THEN 'festival'
  ELSE 'concert'
END
WHERE event_type IS NULL;

CREATE OR REPLACE VIEW v_events_5w AS
SELECT
  e.id AS event_id, e.event_type AS what, e.occurs_at_local AS when_local,
  e.primary_performer_id AS who_performer_id, e.primary_performer_name AS who_performer_name,
  e.performer_ids AS who_all_performers,
  e.venue_id AS where_venue_id, e.venue_name AS where_venue_name, e.venue_location AS where_city,
  e.long_term_popularity_score AS popularity,
  (e.seating_chart_medium IS NOT NULL AND e.seating_chart_medium <> 'null'
    AND e.seating_chart_medium ILIKE 'http%') AS has_seating_chart
FROM events e
WHERE e.occurs_at_local::timestamptz >= now();

GRANT SELECT ON v_events_5w TO authenticated, service_role;

COMMENT ON COLUMN events.event_type IS 'WHAT slot (5W). Values: game|concert|comedy|show|family|festival.';
COMMENT ON VIEW v_events_5w IS 'WHAT/WHEN/WHO/WHERE projection of upcoming events. Powers v28 chatbot discovery.';
