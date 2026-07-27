-- Keyword-to-entity NLU layer for the retail chatbot.
-- Pre-resolves user shorthand to structured entities BEFORE the LLM sees the
-- message. 158+ aliases: NBA/NHL/NFL/MLB/WNBA team codes + nicknames + venue
-- aliases (MSG/SoFi/Wrigley/etc) + zone keywords + leagues + FIFA national teams.

CREATE TABLE IF NOT EXISTS chat_aliases (
  id             bigserial PRIMARY KEY,
  alias_norm     text NOT NULL,
  alias_kind     text NOT NULL CHECK (alias_kind IN ('performer','venue','city','zone','league','tournament')),
  performer_id   bigint,
  venue_id       bigint,
  display_name   text NOT NULL,
  league         text,
  city           text,
  source         text NOT NULL DEFAULT 'curated'
);
CREATE UNIQUE INDEX IF NOT EXISTS chat_aliases_dedup_idx
  ON chat_aliases (alias_norm, alias_kind, COALESCE(performer_id, 0), COALESCE(venue_id, 0));
CREATE INDEX IF NOT EXISTS chat_aliases_norm_idx ON chat_aliases (alias_norm);
CREATE INDEX IF NOT EXISTS chat_aliases_kind_idx ON chat_aliases (alias_kind);

-- Big-4 + WNBA team aliases seeded via JOIN against performer_home_venues.
-- (~105 performers, full team rosters)
-- See seed file or inline in deployed migration; see chat_aliases table for live data.

-- Zone keyword aliases.
INSERT INTO chat_aliases (alias_norm, alias_kind, display_name) VALUES
  ('floor','zone','Floor / Pit / GA'),('floors','zone','Floor / Pit / GA'),
  ('courtside','zone','Floor / Pit / GA'),('courtsides','zone','Floor / Pit / GA'),
  ('wood','zone','Floor / Pit / GA'),('woods','zone','Floor / Pit / GA'),
  ('pit','zone','Floor / Pit / GA'),('ga','zone','Floor / Pit / GA'),
  ('vip','zone','Premium / VIP'),('premium','zone','Premium / VIP'),
  ('club','zone','Club (200s)'),('lower','zone','Lower (100s)'),
  ('lower bowl','zone','Lower (100s)'),('upper','zone','Upper (300s)'),
  ('upper deck','zone','Upper (300s)'),('nosebleed','zone','Upper (500s+)'),
  ('nosebleeds','zone','Upper (500s+)'),('balcony','zone','Balcony'),
  ('box','zone','Box'),('loge','zone','Loge'),('bleachers','zone','Bleachers'),
  ('lawn','zone','Lawn / Terrace'),('terrace','zone','Lawn / Terrace')
ON CONFLICT DO NOTHING;

INSERT INTO chat_aliases (alias_norm, alias_kind, display_name, league) VALUES
  ('nba','league','NBA','NBA'),('nhl','league','NHL','NHL'),('nfl','league','NFL','NFL'),
  ('mlb','league','MLB','MLB'),('mls','league','MLS','MLS'),('wnba','league','WNBA','WNBA'),
  ('fifa','league','FIFA','FIFA')
ON CONFLICT DO NOTHING;

-- The extractor: maps user input → structured entities for LLM consumption.
CREATE OR REPLACE FUNCTION extract_chat_entities(p_input text)
RETURNS jsonb LANGUAGE plpgsql STABLE AS $fn$
DECLARE
  v_lower text; v_perfs jsonb; v_venues jsonb; v_zones jsonb; v_leagues jsonb;
  v_filters jsonb := '{}'::jsonb; v_match text[];
BEGIN
  IF p_input IS NULL OR length(trim(p_input)) = 0 THEN
    RETURN jsonb_build_object('performers','[]'::jsonb,'venues','[]'::jsonb,'zones','[]'::jsonb,'leagues','[]'::jsonb,'filters','{}'::jsonb);
  END IF;
  v_lower := lower(p_input);

  SELECT COALESCE(jsonb_agg(DISTINCT jsonb_build_object('id', performer_id, 'name', display_name, 'league', league, 'city', city, 'matched', alias_norm)), '[]'::jsonb)
    INTO v_perfs FROM chat_aliases WHERE alias_kind = 'performer' AND v_lower ~* ('\m' || alias_norm || '\M');

  SELECT COALESCE(jsonb_agg(DISTINCT jsonb_build_object('venue_id', venue_id, 'name', display_name, 'matched', alias_norm)), '[]'::jsonb)
    INTO v_venues FROM chat_aliases WHERE alias_kind = 'venue' AND v_lower ~* ('\m' || alias_norm || '\M');

  SELECT COALESCE(jsonb_agg(DISTINCT jsonb_build_object('zone', display_name, 'matched', alias_norm)), '[]'::jsonb)
    INTO v_zones FROM chat_aliases WHERE alias_kind = 'zone' AND v_lower ~* ('\m' || alias_norm || '\M');

  SELECT COALESCE(jsonb_agg(DISTINCT display_name), '[]'::jsonb)
    INTO v_leagues FROM chat_aliases WHERE alias_kind IN ('league','tournament') AND v_lower ~* ('\m' || alias_norm || '\M');

  v_match := regexp_match(v_lower, '\mgame\s+(?:number\s+)?(\d+)\M');
  IF v_match IS NOT NULL THEN v_filters := v_filters || jsonb_build_object('game_number', v_match[1]::int); END IF;
  v_match := regexp_match(v_lower, '(\d+)\s+(?:tickets?|seats?)');
  IF v_match IS NOT NULL THEN v_filters := v_filters || jsonb_build_object('min_qty', v_match[1]::int); END IF;
  v_match := regexp_match(v_lower, '\munder\s+\$?(\d+)');
  IF v_match IS NOT NULL THEN v_filters := v_filters || jsonb_build_object('max_price', v_match[1]::numeric); END IF;
  IF v_lower ~* '\m(at\s+home|home\s+game|home)\M' THEN v_filters := v_filters || jsonb_build_object('home_or_away','home');
  ELSIF v_lower ~* '\m(on\s+the\s+road|road\s+game|away\s+game|away)\M' THEN v_filters := v_filters || jsonb_build_object('home_or_away','road');
  END IF;
  IF v_lower ~* '\mtonight\M' THEN v_filters := v_filters || jsonb_build_object('when','tonight');
  ELSIF v_lower ~* '\mtomorrow\M' THEN v_filters := v_filters || jsonb_build_object('when','tomorrow');
  ELSIF v_lower ~* '\mthis\s+weekend\M' THEN v_filters := v_filters || jsonb_build_object('when','this_weekend');
  ELSIF v_lower ~* '\mnext\s+weekend\M' THEN v_filters := v_filters || jsonb_build_object('when','next_weekend');
  END IF;

  RETURN jsonb_build_object('performers', v_perfs, 'venues', v_venues, 'zones', v_zones, 'leagues', v_leagues, 'filters', v_filters, 'original_input', p_input);
END $fn$;
