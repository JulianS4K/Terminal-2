-- ============================================================================
-- Migration 20260708152000 — Harden athlete→Wikipedia matching (collision guards)
--
-- Lane:     data plane (A1)
-- Touches:  _ascii_fold() (new), process_athlete_wiki_searches(),
--           process_athlete_wiki_summaries()
--
-- The v1 matcher (20260708151000) worked for pro stars (who have Wikipedia
-- pages) but produced false matches for college players (most of whom don't):
-- "Jay Ducker" -> "Duck Dynasty", "Jeff Sims" -> a same-name COACH, "Will Nixon"
-- -> "David Nixon". Guards:
--   1. search stage — the top-hit title must contain the athlete's SURNAME and a
--      word starting with the athlete's FIRST INITIAL. Suffixes (Jr/Sr/III) are
--      stripped before extracting the surname, and both sides are accent-folded
--      (_ascii_fold) so "Jokic"~"Jokić" and "Aaron Jones Sr."~"Aaron Jones" still
--      match while "Will Nixon" != "David Nixon" and "Jay Ducker" != "Duck
--      Dynasty" are rejected.
--   2. summary stage — a description naming a non-player role (coach/manager/
--      broadcaster/…) is rejected even if it mentions the sport (kills the
--      same-name-coach false positive that passed sport validation).
-- Rejected athletes stay unmatched (NULL page) rather than carrying a wrong one.
-- ============================================================================

-- Accent/diacritic folding (avoids the unaccent extension dependency).
CREATE OR REPLACE FUNCTION _ascii_fold(t text) RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT translate(lower(coalesce(t,'')),
    'áàâäãåāçćčéèêëēíìîïīñóòôöõøúùûüūýÿžš',
    'aaaaaaaccceeeeeiiiiinoooooouuuuuyyzs')
$$;

CREATE OR REPLACE FUNCTION process_athlete_wiki_searches()
RETURNS TABLE(processed int, hits int, misses int, summary_fired int)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  r RECORD; v_body jsonb; v_title text; v_sreq bigint;
  v_clean text; v_lastname text; v_firstinit text; v_titlef text;
  v_ua jsonb := jsonb_build_object('User-Agent',
    'Terminal2-S4K/1.0 (https://github.com/JulianS4K/Terminal-2; admin@s4kent.com)',
    'Accept','application/json');
  v_p int := 0; v_h int := 0; v_m int := 0; v_s int := 0;
BEGIN
  FOR r IN
    SELECT pd.espn_athlete_id, pd.search_term, h.content, h.status_code, ap.full_name, ap.espn_league
    FROM athlete_wiki_pending pd
    JOIN net._http_response h ON h.id = pd.search_request_id
    JOIN athlete_pages ap ON ap.espn_athlete_id = pd.espn_athlete_id
    WHERE pd.stage = 'search' AND pd.resolved_at IS NULL
  LOOP
    v_p := v_p + 1;
    IF r.status_code = 429 THEN
      DELETE FROM athlete_wiki_pending WHERE espn_athlete_id = r.espn_athlete_id AND stage = 'search';
      CONTINUE;
    END IF;
    IF r.status_code <> 200 THEN
      INSERT INTO athlete_wikipedia(espn_athlete_id, athlete_name, espn_league, is_rejected, reject_reason, match_method, updated_at)
      VALUES (r.espn_athlete_id, r.full_name, r.espn_league, true, 'search HTTP ' || r.status_code, 'rejected', now())
      ON CONFLICT (espn_athlete_id) DO UPDATE SET is_rejected=true, reject_reason=EXCLUDED.reject_reason, updated_at=now();
      UPDATE athlete_wiki_pending SET resolved_at=now() WHERE espn_athlete_id=r.espn_athlete_id AND stage='search';
      v_m := v_m + 1; CONTINUE;
    END IF;
    BEGIN v_body := r.content::jsonb; EXCEPTION WHEN OTHERS THEN v_body := NULL; END;
    v_title := v_body -> 'query' -> 'search' -> 0 ->> 'title';
    v_clean := regexp_replace(trim(r.full_name), '\s+(jr|sr|ii|iii|iv|v)\.?$', '', 'i');
    v_lastname  := _ascii_fold(regexp_replace(v_clean, '^.*\s', ''));
    v_firstinit := left(_ascii_fold(v_clean), 1);
    v_titlef := _ascii_fold(v_title);
    IF v_title IS NULL
       OR (length(v_lastname) >= 3 AND position(v_lastname in v_titlef) = 0)
       OR (v_firstinit ~ '[a-z]' AND v_titlef !~ ('\m' || v_firstinit)) THEN
      INSERT INTO athlete_wikipedia(espn_athlete_id, athlete_name, espn_league, is_rejected, reject_reason, match_method, updated_at)
      VALUES (r.espn_athlete_id, r.full_name, r.espn_league, true,
              CASE WHEN v_title IS NULL THEN 'search returned no hits' ELSE 'name guard: ' || v_title END,
              'rejected', now())
      ON CONFLICT (espn_athlete_id) DO UPDATE SET is_rejected=true, reject_reason=EXCLUDED.reject_reason, updated_at=now();
      UPDATE athlete_wiki_pending SET resolved_at=now() WHERE espn_athlete_id=r.espn_athlete_id AND stage='search';
      v_m := v_m + 1; CONTINUE;
    END IF;
    SELECT net.http_get(
      url := 'https://en.wikipedia.org/api/rest_v1/page/summary/' || replace(v_title, ' ', '_'),
      headers := v_ua, timeout_milliseconds := 12000
    ) INTO v_sreq;
    INSERT INTO athlete_wiki_pending(espn_athlete_id, stage, summary_request_id, search_term)
    VALUES (r.espn_athlete_id, 'summary', v_sreq, r.search_term)
    ON CONFLICT (espn_athlete_id, stage) DO UPDATE
      SET summary_request_id = EXCLUDED.summary_request_id, fired_at = now(), resolved_at = NULL;
    INSERT INTO athlete_wikipedia(espn_athlete_id, athlete_name, espn_league, wiki_title,
                                  match_confidence, match_method, is_rejected, updated_at)
    VALUES (r.espn_athlete_id, r.full_name, r.espn_league, v_title, 0.6, 'search_top', false, now())
    ON CONFLICT (espn_athlete_id) DO UPDATE
      SET wiki_title=EXCLUDED.wiki_title, match_confidence=0.6, match_method='search_top',
          is_rejected=false, reject_reason=NULL, updated_at=now();
    UPDATE athlete_wiki_pending SET resolved_at=now() WHERE espn_athlete_id=r.espn_athlete_id AND stage='search';
    v_h := v_h + 1; v_s := v_s + 1;
  END LOOP;
  RETURN QUERY SELECT v_p, v_h, v_m, v_s;
END $$;

CREATE OR REPLACE FUNCTION process_athlete_wiki_summaries()
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  r RECORD; v_body jsonb; v_kw text[]; v_desc text; v_hay text;
  v_sport_ok boolean; v_is_player boolean; v_conf numeric; v_method text; v_n int := 0;
BEGIN
  FOR r IN
    SELECT pd.espn_athlete_id, h.content, h.status_code, w.espn_league
    FROM athlete_wiki_pending pd
    JOIN net._http_response h ON h.id = pd.summary_request_id
    LEFT JOIN athlete_wikipedia w ON w.espn_athlete_id = pd.espn_athlete_id
    WHERE pd.stage = 'summary' AND pd.resolved_at IS NULL
  LOOP
    IF r.status_code = 429 THEN
      DELETE FROM athlete_wiki_pending WHERE espn_athlete_id = r.espn_athlete_id AND stage = 'summary';
      CONTINUE;
    END IF;
    IF r.status_code = 404 THEN
      UPDATE athlete_wikipedia SET is_rejected=true, reject_reason='summary 404', match_method='rejected', updated_at=now()
        WHERE espn_athlete_id = r.espn_athlete_id;
      UPDATE athlete_wiki_pending SET resolved_at=now() WHERE espn_athlete_id=r.espn_athlete_id AND stage='summary';
      CONTINUE;
    END IF;
    IF r.status_code <> 200 THEN
      UPDATE athlete_wiki_pending SET resolved_at=now() WHERE espn_athlete_id=r.espn_athlete_id AND stage='summary';
      CONTINUE;
    END IF;
    BEGIN v_body := r.content::jsonb; EXCEPTION WHEN OTHERS THEN v_body := NULL; END;
    IF v_body IS NULL THEN
      UPDATE athlete_wiki_pending SET resolved_at=now() WHERE espn_athlete_id=r.espn_athlete_id AND stage='summary';
      CONTINUE;
    END IF;
    v_desc := lower(coalesce(v_body->>'description',''));
    v_hay  := v_desc || ' ' || lower(coalesce(v_body->>'extract',''));
    v_kw := _athlete_sport_keywords(r.espn_league);
    v_sport_ok := v_kw IS NULL OR EXISTS (SELECT 1 FROM unnest(v_kw) k WHERE v_hay LIKE '%'||k||'%');
    v_is_player := v_desc !~ '\y(coach|manager|executive|broadcaster|announcer|official|referee|owner|politician|singer|actor|actress|musician)\y';

    IF NOT v_is_player THEN
      UPDATE athlete_wikipedia SET wiki_pageid=NULL, is_rejected=true,
        reject_reason='non-player description: '||left(coalesce(v_body->>'description',''),60),
        match_method='rejected', description=v_body->>'description', updated_at=now()
        WHERE espn_athlete_id = r.espn_athlete_id;
      UPDATE athlete_wiki_pending SET resolved_at=now() WHERE espn_athlete_id=r.espn_athlete_id AND stage='summary';
      v_n := v_n + 1; CONTINUE;
    END IF;

    v_conf   := CASE WHEN v_sport_ok THEN 0.9 ELSE 0.5 END;
    v_method := CASE WHEN v_sport_ok THEN 'summary_sport_verified' ELSE 'summary_unverified' END;
    UPDATE athlete_wikipedia SET
      wiki_pageid = (v_body->>'pageid')::bigint,
      wiki_url    = v_body->'content_urls'->'desktop'->>'page',
      description = v_body->>'description', extract = v_body->>'extract',
      image_url   = v_body->'thumbnail'->>'source',
      match_confidence = v_conf, match_method = v_method,
      is_rejected = false, reject_reason = NULL,
      raw_summary_jsonb = v_body, last_refreshed_at = now(), updated_at = now()
    WHERE espn_athlete_id = r.espn_athlete_id;
    UPDATE athlete_wiki_pending SET resolved_at=now() WHERE espn_athlete_id=r.espn_athlete_id AND stage='summary';
    v_n := v_n + 1;
  END LOOP;
  RETURN v_n;
END $$;
