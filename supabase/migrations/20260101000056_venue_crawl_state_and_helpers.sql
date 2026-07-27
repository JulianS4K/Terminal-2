-- Cowork migration. Captured into git by code (auditor) on 2026-05-08.
-- Originally applied to prod 2026-05-08 01:44 UTC.
--
-- State + helpers for the venue/performer graph crawl.

CREATE TABLE IF NOT EXISTS venue_crawl_state (
  venue_id          bigint PRIMARY KEY,
  venue_name        text,
  last_crawled_at   timestamptz,
  events_found      integer DEFAULT 0,
  performers_found  integer DEFAULT 0,
  last_error        text
);

CREATE TABLE IF NOT EXISTS performer_crawl_state (
  performer_id      bigint PRIMARY KEY,
  performer_name    text,
  last_crawled_at   timestamptz,
  events_found      integer DEFAULT 0,
  venues_found      integer DEFAULT 0,
  last_error        text
);

INSERT INTO venue_crawl_state (venue_id, venue_name)
SELECT DISTINCT venue_id, venue_name FROM performer_home_venues WHERE venue_id IS NOT NULL
ON CONFLICT (venue_id) DO NOTHING;

INSERT INTO venue_crawl_state (venue_id, venue_name)
SELECT DISTINCT venue_id, venue_name FROM events WHERE venue_id IS NOT NULL
ON CONFLICT (venue_id) DO NOTHING;

CREATE OR REPLACE FUNCTION next_venues_to_crawl(p_limit int DEFAULT 20)
RETURNS TABLE(venue_id bigint, venue_name text) LANGUAGE sql STABLE AS $$
  SELECT venue_id, venue_name FROM venue_crawl_state
  ORDER BY last_crawled_at ASC NULLS FIRST LIMIT p_limit;
$$;

CREATE OR REPLACE FUNCTION next_performers_to_crawl(p_limit int DEFAULT 20)
RETURNS TABLE(performer_id bigint, performer_name text) LANGUAGE sql STABLE AS $$
  SELECT performer_id, performer_name FROM performer_crawl_state
  ORDER BY last_crawled_at ASC NULLS FIRST LIMIT p_limit;
$$;

CREATE OR REPLACE FUNCTION promote_performer_to_aliases(
  p_performer_id bigint, p_performer_name text,
  p_league text DEFAULT NULL, p_city text DEFAULT NULL
) RETURNS int LANGUAGE plpgsql AS $$
DECLARE
  v_added int := 0; v_canonical text; v_last_word text;
BEGIN
  IF p_performer_name IS NULL OR length(p_performer_name) < 2 THEN RETURN 0; END IF;
  v_canonical := lower(trim(p_performer_name));
  INSERT INTO chat_aliases (alias_norm, alias_kind, performer_id, display_name, league, city, source)
  VALUES (v_canonical, 'performer', p_performer_id, p_performer_name, p_league, p_city, 'venue_crawl')
  ON CONFLICT DO NOTHING;
  GET DIAGNOSTICS v_added = ROW_COUNT;

  v_last_word := lower(regexp_replace(p_performer_name, '^.*[\s\-](\S+)$', '\1'));
  IF v_last_word IS NOT NULL AND length(v_last_word) >= 4 AND v_last_word <> v_canonical
     AND v_last_word NOT IN ('team','band','tour','show','concert','live','experience','presents',
                             'world','national','soccer','vs','feat','featuring') THEN
    INSERT INTO chat_aliases (alias_norm, alias_kind, performer_id, display_name, league, city, source)
    VALUES (v_last_word, 'performer', p_performer_id, p_performer_name, p_league, p_city, 'venue_crawl_short')
    ON CONFLICT DO NOTHING;
  END IF;
  RETURN v_added;
END;
$$;

CREATE OR REPLACE FUNCTION promote_venue_to_aliases(
  p_venue_id bigint, p_venue_name text, p_city text DEFAULT NULL
) RETURNS int LANGUAGE plpgsql AS $$
DECLARE v_canonical text; v_short text;
BEGIN
  IF p_venue_name IS NULL OR length(p_venue_name) < 2 THEN RETURN 0; END IF;
  v_canonical := lower(trim(p_venue_name));
  INSERT INTO chat_aliases (alias_norm, alias_kind, venue_id, display_name, city, source)
  VALUES (v_canonical, 'venue', p_venue_id, p_venue_name, p_city, 'venue_crawl')
  ON CONFLICT DO NOTHING;

  v_short := regexp_replace(v_canonical,
    '\s+(arena|stadium|center|centre|park|field|theatre|theater|hall|coliseum|forum|garden)$', '');
  IF v_short <> v_canonical AND length(v_short) >= 3 THEN
    INSERT INTO chat_aliases (alias_norm, alias_kind, venue_id, display_name, city, source)
    VALUES (v_short, 'venue', p_venue_id, p_venue_name, p_city, 'venue_crawl_short')
    ON CONFLICT DO NOTHING;
  END IF;
  RETURN 1;
END;
$$;

GRANT SELECT ON venue_crawl_state, performer_crawl_state TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION next_venues_to_crawl(int), next_performers_to_crawl(int),
  promote_performer_to_aliases(bigint,text,text,text), promote_venue_to_aliases(bigint,text,text)
  TO authenticated, service_role;
