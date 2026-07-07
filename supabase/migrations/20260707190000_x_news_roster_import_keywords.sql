-- ============================================================================
-- Migration 20260707190000 — X news wire: full roster import + keyword tagging
--
-- Lane:     xref+macro (A1 data plane)
-- Touches:  important_x_accounts (W: +86 delta), x_news_sources (W: full import),
--           x_news (W: +matched_keywords col), x_news_queue (W/function),
--           x_news_process (W/function), v_x_news_ticker (W/view),
--           get_terminal_news_ticker (W/function); news_keywords (R)
-- Pre-reqs: 20260706114500 (X pipeline), 20260509420000 (match_news_keywords +
--           news_keywords — all 20 spreadsheet keywords verified present on prod)
--
-- Operator directive (2026-07-07): "import these handles, under twitter, and
-- assign their respective categories and keywords" — the Ticket_news_ticker
-- spreadsheet (the same one that seeded important_x_accounts in 20260509420000).
--
-- WHAT THIS DOES:
--   (1) Catalog delta: 86 spreadsheet handles missing from prod
--       important_x_accounts (Broadway theaters/producers/reporters/touring,
--       concert venues/promoters/reporters, 3 artists) — the sheet's Category
--       column maps to account_type. Prod verified a strict subset of the
--       sheet before this restatement (341 of 427).
--   (2) Roster import: ALL catalog handles -> x_news_sources (enabled), each
--       carrying its category (notes) + normalized league, with the polling
--       budget TIERED by category via poll_interval_minutes:
--         insider 15 · beat_reporter 120 · league_official 180 ·
--         team_official 360 · broadway org/reporter/touring 240 ·
--         broadway theater/show/producer 360 · concert promoter/reporter 240 ·
--         concert venue 360 · concert artist 720
--       Global spend stays capped by the 1-call/min queue tick (~1,440/day);
--       tiers set each category's SHARE of that budget, not extra spend.
--   (3) Queue priority: x_news_queue ORDER BY switches from pure LRU to
--       overdue-ratio (age / poll_interval — the EVO band-priority precedent,
--       mig 20260701191500), so under saturation insiders keep a ~40-60 min
--       effective cadence instead of being diluted to the roster average.
--       Never-polled sources go first, tightest interval first.
--   (4) Keyword assignment: every ingested post is scored at write time with
--       the EXISTING match_news_keywords() (word-boundary matcher over
--       news_keywords — the sheet's injury/trade/closing/onsale/... sets, all
--       already present). Hits + categories + weight land in
--       x_news.matched_keywords (jsonb, NULL when no hits); the ticker
--       surfaces the hit list as the row summary (searchable in the FE).
-- ============================================================================

-- ----------------------------------------------------------------------------
-- (1) Catalog delta — spreadsheet handles missing from important_x_accounts.
-- ----------------------------------------------------------------------------
INSERT INTO important_x_accounts (handle, name, account_type, league, team_name, priority) VALUES
  ('@DarylRoth', 'Daryl Roth', 'broadway_producer', 'Broadway', NULL, 'medium'),
  ('@HunterArnold', 'Hunter Arnold', 'broadway_producer', 'Broadway', NULL, 'medium'),
  ('@Jordan_Roth', 'Jordan Roth', 'broadway_producer', 'Broadway', NULL, 'medium'),
  ('@KevinMcCollum', 'Kevin McCollum', 'broadway_producer', 'Broadway', NULL, 'medium'),
  ('@ScottRudin', 'Scott Rudin', 'broadway_producer', 'Broadway', NULL, 'medium'),
  ('@SoniaFriedman', 'Sonia Friedman', 'broadway_producer', 'Broadway', NULL, 'medium'),
  ('@davidmstone', 'David Stone', 'broadway_producer', 'Broadway', NULL, 'medium'),
  ('@jeffrey_seller', 'Jeffrey Seller', 'broadway_producer', 'Broadway', NULL, 'medium'),
  ('@kendavenport', 'Ken Davenport', 'broadway_producer', 'Broadway', NULL, 'medium'),
  ('@AndrewGans', 'Andrew Gans', 'broadway_reporter', 'Broadway', NULL, 'medium'),
  ('@ChrisJonesTrib', 'Chris Jones', 'broadway_reporter', 'Broadway', NULL, 'medium'),
  ('@GordonCox', 'Gordon Cox', 'broadway_reporter', 'Broadway', NULL, 'medium'),
  ('@JesseKGreen', 'Jesse Green', 'broadway_reporter', 'Broadway', NULL, 'medium'),
  ('@MichaelPaulson', 'Michael Paulson', 'broadway_reporter', 'Broadway', NULL, 'medium'),
  ('@RyanMcPhee', 'Ryan McPhee', 'broadway_reporter', 'Broadway', NULL, 'medium'),
  ('@fdilella', 'Frank DiLella', 'broadway_reporter', 'Broadway', NULL, 'medium'),
  ('@frankjrizzo', 'Frank Rizzo', 'broadway_reporter', 'Broadway', NULL, 'medium'),
  ('@mattwindman', 'Matt Windman', 'broadway_reporter', 'Broadway', NULL, 'medium'),
  ('@mrdavegordon', 'David Gordon', 'broadway_reporter', 'Broadway', NULL, 'medium'),
  ('@BarrymoreBway', 'Ethel Barrymore Theatre', 'broadway_theater', 'Broadway', NULL, 'medium'),
  ('@BelascoTheatre', 'Belasco Theatre', 'broadway_theater', 'Broadway', NULL, 'medium'),
  ('@BoothTheatreNY', 'Booth Theatre', 'broadway_theater', 'Broadway', NULL, 'medium'),
  ('@BroadhurstThtr', 'Broadhurst Theatre', 'broadway_theater', 'Broadway', NULL, 'medium'),
  ('@FriedmanTheatre', 'Friedman Theatre', 'broadway_theater', 'Broadway', NULL, 'medium'),
  ('@GershwinTheatre', 'Gershwin Theatre', 'broadway_theater', 'Broadway', NULL, 'medium'),
  ('@HirschfeldBroadway', 'Al Hirschfeld Theatre', 'broadway_theater', 'Broadway', NULL, 'medium'),
  ('@ImperialBroadway', 'Imperial Theatre', 'broadway_theater', 'Broadway', NULL, 'medium'),
  ('@LongacreTheatre', 'Longacre Theatre', 'broadway_theater', 'Broadway', NULL, 'medium'),
  ('@LyricBroadway', 'Lyric Theatre', 'broadway_theater', 'Broadway', NULL, 'medium'),
  ('@MajesticBroadway', 'Majestic Theatre', 'broadway_theater', 'Broadway', NULL, 'medium'),
  ('@MinskoffTheatre', 'Minskoff Theatre', 'broadway_theater', 'Broadway', NULL, 'medium'),
  ('@MusicBoxNYC', 'Music Box Theatre', 'broadway_theater', 'Broadway', NULL, 'medium'),
  ('@NewAmsterdam', 'New Amsterdam Theatre', 'broadway_theater', 'Broadway', NULL, 'medium'),
  ('@PalaceTheatreNY', 'Palace Theatre', 'broadway_theater', 'Broadway', NULL, 'medium'),
  ('@ShubertTheatre', 'Shubert Theatre', 'broadway_theater', 'Broadway', NULL, 'medium'),
  ('@StJamesTheatre', 'St. James Theatre', 'broadway_theater', 'Broadway', NULL, 'medium'),
  ('@WalterKerrBway', 'Walter Kerr Theatre', 'broadway_theater', 'Broadway', NULL, 'medium'),
  ('@WinterGardenNYC', 'Winter Garden Theatre', 'broadway_theater', 'Broadway', NULL, 'medium'),
  ('@BOS_Broadway', 'Broadway in Boston', 'broadway_touring', 'Broadway', NULL, 'medium'),
  ('@BroadwayDC', 'Broadway in DC', 'broadway_touring', 'Broadway', NULL, 'medium'),
  ('@BroadwayInChi', 'Broadway in Chicago', 'broadway_touring', 'Broadway', NULL, 'medium'),
  ('@BroadwayLA', 'Broadway in Hollywood', 'broadway_touring', 'Broadway', NULL, 'medium'),
  ('@BroadwaySF', 'BroadwaySF', 'broadway_touring', 'Broadway', NULL, 'medium'),
  ('@BwayAcrossUSA', 'Broadway Across America', 'broadway_touring', 'Broadway', NULL, 'medium'),
  ('@BwayAtlanta', 'Broadway in Atlanta', 'broadway_touring', 'Broadway', NULL, 'medium'),
  ('@BwayDallas', 'Broadway in Dallas', 'broadway_touring', 'Broadway', NULL, 'medium'),
  ('@Mirvish', 'Broadway in Toronto', 'broadway_touring', 'Broadway', NULL, 'medium'),
  ('@NationalTourNews', 'National Tour News', 'broadway_touring', 'Broadway', NULL, 'medium'),
  ('@Imaginedragons', 'Imagine Dragons', 'concert_artist', 'Concerts', NULL, 'medium'),
  ('@the1975', 'The 1975', 'concert_artist', 'Concerts', NULL, 'medium'),
  ('@tylerthecreator', 'Tyler, The Creator', 'concert_artist', 'Concerts', NULL, 'medium'),
  ('@OutbackPresents', 'Outback Presents', 'concert_promoter', 'Concerts', NULL, 'medium'),
  ('@SJMConcerts', 'SJM Concerts', 'concert_promoter', 'Concerts', NULL, 'medium'),
  ('@apeconcerts', 'Another Planet Entertainment', 'concert_promoter', 'Concerts', NULL, 'medium'),
  ('@bowerypresents', 'Bowery Presents', 'concert_promoter', 'Concerts', NULL, 'medium'),
  ('@eventim', 'Eventim', 'concert_promoter', 'Concerts', NULL, 'medium'),
  ('@goldenvoice', 'Goldenvoice', 'concert_promoter', 'Concerts', NULL, 'medium'),
  ('@kililive', 'Kilimanjaro Live', 'concert_promoter', 'Concerts', NULL, 'medium'),
  ('@mammothlive', 'Mammoth Live', 'concert_promoter', 'Concerts', NULL, 'medium'),
  ('@ComplexMusic', 'Complex Music', 'concert_reporter', 'Concerts', NULL, 'medium'),
  ('@HITSDD', 'HITS Daily Double', 'concert_reporter', 'Concerts', NULL, 'medium'),
  ('@Loudwire', 'Loudwire', 'concert_reporter', 'Concerts', NULL, 'medium'),
  ('@NME', 'NME', 'concert_reporter', 'Concerts', NULL, 'medium'),
  ('@consequence', 'Consequence', 'concert_reporter', 'Concerts', NULL, 'medium'),
  ('@livenation', 'Live Music Industry', 'concert_reporter', 'Concerts', NULL, 'medium'),
  ('@musicbizworld', 'Music Business Worldwide', 'concert_reporter', 'Concerts', NULL, 'medium'),
  ('@thefader', 'The FADER', 'concert_reporter', 'Concerts', NULL, 'medium'),
  ('@AllegiantStadm', 'Allegiant Stadium', 'concert_venue', 'Concerts', NULL, 'medium'),
  ('@BeaconTheatre', 'Beacon Theatre', 'concert_venue', 'Concerts', NULL, 'medium'),
  ('@ForestHillsStdm', 'Forest Hills Stadium', 'concert_venue', 'Concerts', NULL, 'medium'),
  ('@GreekTheatreLA', 'The Greek Theatre LA', 'concert_venue', 'Concerts', NULL, 'medium'),
  ('@HollywoodBowl', 'Hollywood Bowl', 'concert_venue', 'Concerts', NULL, 'medium'),
  ('@MGMGrand', 'MGM Grand Garden Arena', 'concert_venue', 'Concerts', NULL, 'medium'),
  ('@RadioCity', 'Radio City Music Hall', 'concert_venue', 'Concerts', NULL, 'medium'),
  ('@RedRocksCO', 'Red Rocks Amphitheatre', 'concert_venue', 'Concerts', NULL, 'medium'),
  ('@SoFiStadium', 'SoFi Stadium', 'concert_venue', 'Concerts', NULL, 'medium'),
  ('@TMobileArena', 'T-Mobile Arena', 'concert_venue', 'Concerts', NULL, 'medium'),
  ('@TheAnthemDC', 'The Anthem DC', 'concert_venue', 'Concerts', NULL, 'medium'),
  ('@TheForum', 'The Forum LA', 'concert_venue', 'Concerts', NULL, 'medium'),
  ('@TheO2', 'O2 Arena London', 'concert_venue', 'Concerts', NULL, 'medium'),
  ('@UnitedCenter', 'United Center', 'concert_venue', 'Concerts', NULL, 'medium'),
  ('@barclayscenter', 'Barclays Center', 'concert_venue', 'Concerts', NULL, 'medium'),
  ('@cryptocomarena', 'Crypto.com Arena', 'concert_venue', 'Concerts', NULL, 'medium'),
  ('@opry', 'Grand Ole Opry', 'concert_venue', 'Concerts', NULL, 'medium'),
  ('@theryman', 'Ryman Auditorium', 'concert_venue', 'Concerts', NULL, 'medium'),
  ('@wembleystadium', 'Wembley Stadium', 'concert_venue', 'Concerts', NULL, 'medium')
ON CONFLICT (handle) DO NOTHING;

-- ----------------------------------------------------------------------------
-- (2) Roster import — every catalog handle becomes an enabled x_news_sources
--     row with tiered poll_interval_minutes + category in notes. Idempotent:
--     re-run refreshes tier/league/notes and re-enables.
-- ----------------------------------------------------------------------------
INSERT INTO x_news_sources (source_value, kind, league, enabled, poll_interval_minutes, notes)
SELECT
  ia.handle,
  'handle',
  CASE
    WHEN ia.account_type = 'insider'                THEN NULL          -- multi-sport
    WHEN ia.league IS NULL                          THEN NULL
    WHEN ia.league ~ '^(NFL|NBA|MLB|NHL|NCAA)'      THEN substring(ia.league from '^(NFL|NBA|MLB|NHL|NCAA)')
    WHEN ia.league = 'Major League Soccer'          THEN 'MLS'
    WHEN ia.league = 'Formula 1'                    THEN 'F1'
    ELSE ia.league
  END,
  true,
  CASE ia.account_type
    WHEN 'insider'           THEN 15
    WHEN 'beat_reporter'     THEN 120
    WHEN 'league_official'   THEN 180
    WHEN 'team_official'     THEN 360
    WHEN 'broadway_org'      THEN 240
    WHEN 'broadway_reporter' THEN 240
    WHEN 'broadway_touring'  THEN 240
    WHEN 'broadway_theater'  THEN 360
    WHEN 'broadway_show'     THEN 360
    WHEN 'broadway_producer' THEN 360
    WHEN 'concert_promoter'  THEN 240
    WHEN 'concert_reporter'  THEN 240
    WHEN 'concert_venue'     THEN 360
    WHEN 'concert_artist'    THEN 720
    ELSE 240
  END,
  'catalog: ' || ia.account_type || ' — ' || ia.name
FROM important_x_accounts ia
ON CONFLICT (source_value) DO UPDATE SET
  enabled = true,
  league = EXCLUDED.league,
  poll_interval_minutes = EXCLUDED.poll_interval_minutes,
  notes = EXCLUDED.notes;

-- ----------------------------------------------------------------------------
-- (3) Queue priority — overdue-ratio ordering (age vs interval), so the tiers
--     above allocate the fixed 1-call/min budget instead of pure LRU fairness.
--     Never-polled sources first, tightest tier first (insiders lead the
--     initial sweep when the key lands).
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION x_news_queue(p_limit int DEFAULT 1)
RETURNS int LANGUAGE plpgsql AS $$
DECLARE
  r RECORD; v_req_id bigint; v_count int := 0;
  v_key text; v_query text; v_url text;
BEGIN
  -- Key gate: exception-safe so this also no-ops if the whitelist migration
  -- (20260706113000) hasn't been applied yet.
  BEGIN
    v_key := get_app_secret('TWITTERAPI_IO_KEY');
  EXCEPTION WHEN others THEN
    v_key := NULL;
  END;
  IF v_key IS NULL OR btrim(v_key) = '' THEN
    RETURN 0;  -- no key → no spend, no requests
  END IF;

  FOR r IN
    SELECT s.source_value, s.kind, s.league, s.poll_interval_minutes
    FROM x_news_sources s
    WHERE s.enabled
      AND (s.last_polled_at IS NULL
           OR s.last_polled_at < now() - (s.poll_interval_minutes || ' minutes')::interval)
    ORDER BY
      (s.last_polled_at IS NULL) DESC,                                   -- never-polled first
      CASE WHEN s.last_polled_at IS NULL
           THEN s.poll_interval_minutes END ASC NULLS LAST,              -- ...tightest tier first
      (EXTRACT(EPOCH FROM (now() - s.last_polled_at)) / 60.0)
        / NULLIF(s.poll_interval_minutes, 0) DESC NULLS LAST,            -- most-overdue-by-ratio
      s.source_value
    LIMIT p_limit
  LOOP
    -- handle rows → the account's own fresh posts, no retweets/replies;
    -- query rows → operator-authored advanced-search string, verbatim.
    v_query := CASE r.kind
      WHEN 'handle' THEN 'from:' || ltrim(btrim(r.source_value), '@')
                         || ' -filter:retweets -filter:replies'
      ELSE r.source_value
    END;

    v_url := 'https://api.twitterapi.io/twitter/tweet/advanced_search'
          || '?queryType=Latest&query=' || x_news_urlencode(v_query);

    SELECT net.http_get(
      url := v_url,
      headers := jsonb_build_object(
        'X-API-Key', v_key,
        'Accept', 'application/json'),
      timeout_milliseconds := 15000
    ) INTO v_req_id;

    INSERT INTO x_news_pending(source_value, kind, league, request_id, fired_at)
    VALUES (r.source_value, r.kind, r.league, v_req_id, now());

    -- Advance the round-robin cursor so the next tick picks a different source.
    UPDATE x_news_sources SET last_polled_at = now()
    WHERE source_value = r.source_value;
    v_count := v_count + 1;
  END LOOP;
  RETURN v_count;
END; $$;

-- ----------------------------------------------------------------------------
-- (4) Keyword assignment at ingest — match_news_keywords() over the tweet
--     text; {hits, categories, total_weight} stored when anything matched.
-- ----------------------------------------------------------------------------
ALTER TABLE x_news ADD COLUMN IF NOT EXISTS matched_keywords jsonb;

COMMENT ON COLUMN x_news.matched_keywords IS
  'match_news_keywords(title) result {hits, categories, total_weight} captured '
  'at ingest; NULL when no news_keywords matched. Mig 20260707190000.';

CREATE OR REPLACE FUNCTION x_news_process()
RETURNS TABLE(processed int, posts_persisted int) LANGUAGE plpgsql AS $$
DECLARE
  r RECORD; v_json jsonb; v_count int;
  v_processed int := 0; v_persisted int := 0;
BEGIN
  FOR r IN
    SELECT p.id, p.source_value, p.league, p.request_id,
           h.content, h.status_code
    FROM x_news_pending p
    JOIN net._http_response h ON h.id = p.request_id
    WHERE p.resolved_at IS NULL
  LOOP
    v_processed := v_processed + 1;
    v_count := 0;
    IF r.status_code = 200 AND r.content IS NOT NULL THEN
      BEGIN
        v_json := r.content::jsonb;
      EXCEPTION WHEN others THEN
        v_json := NULL;  -- non-JSON body → resolve with 0 rows, don't wedge the queue
      END;
      IF v_json IS NOT NULL AND jsonb_typeof(v_json -> 'tweets') = 'array' THEN
        WITH ins AS (
          INSERT INTO x_news (
            tweet_id, source_value, league, author_handle, author_name,
            title, url, created_utc, matched_keywords
          )
          SELECT
            t ->> 'id',
            r.source_value,
            r.league,
            coalesce(t #>> '{author,userName}', ''),
            t #>> '{author,name}',
            t ->> 'text',
            coalesce(t ->> 'url', 'https://x.com/i/status/' || (t ->> 'id')),
            coalesce(x_news_parse_ts(t ->> 'createdAt'), now()),
            CASE WHEN coalesce((k.mk ->> 'total_weight')::numeric, 0) > 0
                 THEN k.mk ELSE NULL END
          FROM jsonb_array_elements(v_json -> 'tweets') t
          CROSS JOIN LATERAL (SELECT match_news_keywords(t ->> 'text') AS mk) k
          WHERE coalesce(t ->> 'id', '') <> ''
            AND coalesce(t ->> 'text', '') <> ''
          ON CONFLICT (tweet_id) DO NOTHING
          RETURNING 1
        )
        SELECT count(*) INTO v_count FROM ins;
        v_persisted := v_persisted + v_count;
      END IF;
    END IF;

    UPDATE x_news_pending SET resolved_at = now(), rows_persisted = v_count
    WHERE id = r.id;
  END LOOP;
  RETURN QUERY SELECT v_processed, v_persisted;
END; $$;

-- ----------------------------------------------------------------------------
-- (5) Ticker view — expose matched_keywords (appended column; CREATE OR
--     REPLACE VIEW permits trailing additions).
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_x_news_ticker AS
WITH win AS (
  SELECT
    xn.*,
    -- btrim too: whitespace runs collapse to one space but a leading/trailing
    -- space would otherwise survive and split the key (caught in local sim).
    lower(btrim(regexp_replace(xn.title, '\s+', ' ', 'g'))) AS dedupe_key
  FROM x_news xn
  WHERE xn.pulled_at > now() - interval '48 hours'
),
deduped AS (
  -- ASC → keep the FIRST (earliest) post carrying this text.
  SELECT DISTINCT ON (dedupe_key)
    tweet_id, source_value, league, author_handle, author_name,
    title, url, created_utc, matched_keywords
  FROM win
  ORDER BY dedupe_key, created_utc ASC NULLS LAST
)
SELECT * FROM deduped
ORDER BY created_utc DESC NULLS LAST;

-- ----------------------------------------------------------------------------
-- (6) get_terminal_news_ticker — restate; the x_posts CTE now carries the
--     matched keyword hits as the row summary ('injury · trade'), which the FE
--     already renders searchable. All other CTEs verbatim from 20260706114500.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_terminal_news_ticker(
  p_window_hours integer DEFAULT 48,
  p_sources text[] DEFAULT NULL::text[],
  p_leagues text[] DEFAULT NULL::text[],
  p_search text DEFAULT NULL::text,
  p_limit integer DEFAULT 100)
 RETURNS TABLE(source text, league text, team text, headline text, summary text, url text, image_url text, item_type text, published_at timestamp with time zone)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  WITH params AS (
    SELECT
      GREATEST(1, LEAST(coalesce(p_window_hours, 48), 720)) AS win_hours,
      GREATEST(1, LEAST(coalesce(p_limit, 100), 300))       AS lim,
      NULLIF(btrim(coalesce(p_search, '')), '')             AS q
  ),
  espn AS (
    SELECT
      'ESPN'::text                             AS source,
      e.espn_league                            AS league,
      coalesce(t.display_name, t.abbreviation) AS team,
      e.headline                               AS headline,
      e.description                            AS summary,
      e.url                                    AS url,
      e.image_url                              AS image_url,
      e.type                                   AS item_type,
      e.published_at                           AS published_at
    FROM public.espn_news e
    LEFT JOIN public.espn_teams_canonical t
      ON t.espn_team_id = e.espn_team_id
     AND t.espn_league  = e.espn_league
    WHERE e.published_at > now() - ((SELECT win_hours FROM params) || ' hours')::interval
      AND (p_sources IS NULL OR 'ESPN' = ANY (p_sources))
  ),
  transactions AS (
    SELECT
      'Transactions'::text                                     AS source,
      tx.espn_league                                           AS league,
      coalesce(c.display_name, c.abbreviation, tx.team_display_name, tx.team_abbr) AS team,
      coalesce(tx.team_display_name || ': ', '') || tx.description                  AS headline,
      NULL::text                                               AS summary,
      coalesce(
        'performer.html?performer=' || (
          SELECT x.tevo_performer_id FROM public.performer_espn_team_xref x
          WHERE x.espn_team_id = tx.espn_team_id AND x.espn_league = tx.espn_league LIMIT 1)::text,
        CASE lower(tx.espn_league)
          WHEN 'nfl'  THEN 'https://www.espn.com/nfl/transactions'
          WHEN 'nba'  THEN 'https://www.espn.com/nba/transactions'
          WHEN 'wnba' THEN 'https://www.espn.com/wnba/transactions'
          WHEN 'mlb'  THEN 'https://www.espn.com/mlb/transactions'
          WHEN 'nhl'  THEN 'https://www.espn.com/nhl/transactions'
          ELSE NULL END)                                       AS url,
      NULL::text                                               AS image_url,
      'transaction'::text                                      AS item_type,
      tx.txn_date                                              AS published_at
    FROM public.espn_transactions tx
    LEFT JOIN public.espn_teams_canonical c
      ON c.espn_team_id = tx.espn_team_id AND c.espn_league = tx.espn_league
    WHERE tx.txn_date > now() - ((SELECT win_hours FROM params) || ' hours')::interval
      AND coalesce(tx.description, '') <> ''
      AND (p_sources IS NULL OR 'Transactions' = ANY (p_sources))
  ),
  injuries AS (
    SELECT
      'Injuries'::text                              AS source,
      max(i.espn_league)                            AS league,
      max(coalesce(t.display_name, t.abbreviation)) AS team,
      max(i.athlete_name)
        || coalesce(' (' || NULLIF(max(i.position), '') || ')', '')
        || coalesce(' — ' || NULLIF(max(i.status), ''), '')
        || CASE WHEN NULLIF(max(i.injury_type), '') IS NOT NULL
                     AND lower(max(i.injury_type)) <> lower(coalesce(max(i.status), ''))
                THEN ' · ' || max(i.injury_type) ELSE '' END   AS headline,
      NULLIF(
        coalesce(NULLIF(max(i.short_comment), ''), NULLIF(max(i.long_comment), ''), '')
        || CASE WHEN max(i.return_date) IS NOT NULL
                THEN ' (est. return ' || to_char(max(i.return_date), 'Mon DD') || ')'
                ELSE '' END,
        '')                                         AS summary,
      coalesce(
        'player.html?player=' || max(i.athlete_id) || '&league=' || max(i.espn_league),
        CASE lower(max(i.espn_league))
          WHEN 'nfl'  THEN 'https://www.espn.com/nfl/injuries'
          WHEN 'nba'  THEN 'https://www.espn.com/nba/injuries'
          WHEN 'wnba' THEN 'https://www.espn.com/wnba/injuries'
          WHEN 'mlb'  THEN 'https://www.espn.com/mlb/injuries'
          WHEN 'nhl'  THEN 'https://www.espn.com/nhl/injuries'
          ELSE NULL END)                            AS url,
      NULL::text                                    AS image_url,
      'injury'::text                                AS item_type,
      min(i.captured_at)                            AS published_at
    FROM public.espn_injuries_snapshots i
    LEFT JOIN public.espn_teams_canonical t
      ON t.espn_team_id = i.espn_team_id
     AND t.espn_league  = i.espn_league
    WHERE coalesce(i.athlete_name, '') <> ''
      AND (p_sources IS NULL OR 'Injuries' = ANY (p_sources))
      AND i.captured_at > now() - (((SELECT win_hours FROM params) + 24) || ' hours')::interval
    GROUP BY i.espn_team_id, i.espn_league,
             lower(i.athlete_name), lower(coalesce(i.status, '')), lower(coalesce(i.injury_type, ''))
    HAVING min(i.captured_at) > now() - ((SELECT win_hours FROM params) || ' hours')::interval
  ),
  scores AS (
    SELECT DISTINCT ON (s.espn_event_id, s.espn_league)
      'Scores'::text                             AS source,
      s.espn_league                              AS league,
      coalesce(ha.display_name, ha.abbreviation) AS team,
      coalesce(aw.display_name, aw.abbreviation, 'Away') || ' ' || coalesce(s.away_score::text, '0')
        || ', ' || coalesce(ha.display_name, ha.abbreviation, 'Home') || ' ' || coalesce(s.home_score::text, '0')
        || coalesce(' · ' || NULLIF(s.status_short, ''), '') AS headline,
      NULL::text                                 AS summary,
      coalesce(
        'performer.html?performer=' || (
          SELECT x.tevo_performer_id FROM public.performer_espn_team_xref x
          WHERE x.espn_team_id = s.home_team_id AND x.espn_league = s.espn_league LIMIT 1)::text,
        CASE lower(s.espn_league)
          WHEN 'nfl'  THEN 'https://www.espn.com/nfl/scoreboard'
          WHEN 'nba'  THEN 'https://www.espn.com/nba/scoreboard'
          WHEN 'wnba' THEN 'https://www.espn.com/wnba/scoreboard'
          WHEN 'mlb'  THEN 'https://www.espn.com/mlb/scoreboard'
          WHEN 'nhl'  THEN 'https://www.espn.com/nhl/scoreboard'
          ELSE NULL END)                         AS url,
      NULL::text                                 AS image_url,
      'score'::text                              AS item_type,
      s.captured_at                              AS published_at
    FROM public.espn_event_snapshots s
    LEFT JOIN public.espn_teams_canonical ha
      ON ha.espn_team_id = s.home_team_id AND ha.espn_league = s.espn_league
    LEFT JOIN public.espn_teams_canonical aw
      ON aw.espn_team_id = s.away_team_id AND aw.espn_league = s.espn_league
    WHERE s.state = 'post'
      AND s.captured_at > now() - ((SELECT win_hours FROM params) || ' hours')::interval
      AND (p_sources IS NULL OR 'Scores' = ANY (p_sources))
    ORDER BY s.espn_event_id, s.espn_league, s.captured_at DESC
  ),
  standings AS (
    SELECT DISTINCT ON (t.espn_team_id, t.espn_league)
      'Standings'::text                        AS source,
      t.espn_league                            AS league,
      coalesce(c.display_name, c.abbreviation) AS team,
      coalesce(c.display_name, c.abbreviation) || ' ' || coalesce(t.record_summary, '')
        || coalesce(' · ' || NULLIF(t.streak, ''), '')
        || coalesce(' · #' || t.playoff_seed || ' seed', '') AS headline,
      NULL::text                               AS summary,
      coalesce(
        'performer.html?performer=' || (
          SELECT x.tevo_performer_id FROM public.performer_espn_team_xref x
          WHERE x.espn_team_id = t.espn_team_id AND x.espn_league = t.espn_league LIMIT 1)::text,
        CASE lower(t.espn_league)
          WHEN 'nfl'  THEN 'https://www.espn.com/nfl/standings'
          WHEN 'nba'  THEN 'https://www.espn.com/nba/standings'
          WHEN 'wnba' THEN 'https://www.espn.com/wnba/standings'
          WHEN 'mlb'  THEN 'https://www.espn.com/mlb/standings'
          WHEN 'nhl'  THEN 'https://www.espn.com/nhl/standings'
          ELSE NULL END)                       AS url,
      NULL::text                               AS image_url,
      'standing'::text                         AS item_type,
      t.captured_at                            AS published_at
    FROM public.espn_team_snapshots t
    LEFT JOIN public.espn_teams_canonical c
      ON c.espn_team_id = t.espn_team_id AND c.espn_league = t.espn_league
    WHERE t.captured_at > now() - ((SELECT win_hours FROM params) || ' hours')::interval
      AND coalesce(t.record_summary, '') <> ''
      AND (p_sources IS NULL OR 'Standings' = ANY (p_sources))
    ORDER BY t.espn_team_id, t.espn_league, t.captured_at DESC
  ),
  reddit AS (
    SELECT
      'Reddit'::text                                   AS source,
      r.league                                         AS league,
      'r/' || r.subreddit                              AS team,
      r.title                                          AS headline,
      NULL::text                                       AS summary,
      coalesce(NULLIF(r.link_url, ''), r.permalink)    AS url,
      NULL::text                                       AS image_url,
      'reddit_news'::text                              AS item_type,
      r.created_utc                                    AS published_at
    FROM public.v_reddit_news_ticker r
    WHERE r.created_utc > now() - ((SELECT win_hours FROM params) || ' hours')::interval
      AND (p_sources IS NULL OR 'Reddit' = ANY (p_sources))
      AND (
        r.link_url IS NULL OR r.link_url = '' OR NOT EXISTS (
          SELECT 1 FROM public.espn_news e
          WHERE e.url IS NOT NULL
            AND e.published_at > now() - ((SELECT win_hours FROM params) || ' hours')::interval
            AND rtrim(lower(regexp_replace(regexp_replace(e.url,    '[#?].*$', ''), '^https?://(www\.)?', '')), '/')
              = rtrim(lower(regexp_replace(regexp_replace(r.link_url,'[#?].*$', ''), '^https?://(www\.)?', '')), '/')
        )
      )
  ),
  bway_current AS (
    SELECT DISTINCT ON (cr.show_slug)
      cr.id AS cast_run_id, cr.show_slug, cr.role, cr.performer_name,
      cr.run_start, cr.last_seen_at
    FROM public.broadway_cast_run cr
    WHERE cr.run_start IS NOT NULL
    ORDER BY cr.show_slug,
      (cr.run_start <= current_date AND (cr.run_end IS NULL OR cr.run_end >= current_date)) DESC,
      cr.run_start DESC NULLS LAST
  ),
  broadway AS (
    SELECT 'Broadway'::text AS source, 'Broadway'::text AS league,
      r.title AS team,
      r.title || ' — ' || bc.performer_name
        || coalesce(' as ' || NULLIF(bc.role, ''), '') AS headline,
      NULLIF(
        coalesce('leading since ' || to_char(bc.run_start, 'Mon DD'), '')
        || coalesce(' · get-in avg $' || round(g.avg_getin)::text, '')
        || coalesce(' · closing $' || round(g.closing_night_getin)::text, ''), '') AS summary,
      'performer.html?performer=' || r.tevo_performer_id::text
        || coalesce('&venue=' || r.tevo_venue_id::text, '') AS url,
      NULL::text AS image_url, 'cast'::text AS item_type,
      coalesce(r.cast_last_polled_at, bc.last_seen_at, bc.run_start::timestamptz) AS published_at
    FROM bway_current bc
    JOIN public.broadway_show_ref r ON r.show_slug = bc.show_slug
    LEFT JOIN public.v_broadway_performer_getin g ON g.cast_run_id = bc.cast_run_id
    WHERE r.tevo_performer_id IS NOT NULL
      AND (p_sources IS NULL OR 'Broadway' = ANY (p_sources))
  ),
  bway_flags AS (
    SELECT 'Broadway'::text AS source, 'Broadway'::text AS league,
      r.title AS team,
      r.title || ' — cast update detected' AS headline,
      'Wikipedia cast section changed — possible lead change; review the cast timeline.'::text AS summary,
      'performer.html?performer=' || r.tevo_performer_id::text
        || coalesce('&venue=' || r.tevo_venue_id::text, '') AS url,
      NULL::text AS image_url, 'cast'::text AS item_type, pl.created_at AS published_at
    FROM public.broadway_cast_pull_log pl
    JOIN public.broadway_show_ref r ON r.show_slug = pl.show_slug
    WHERE (pl.section_changed OR pl.flag_raised)
      AND r.tevo_performer_id IS NOT NULL
      AND pl.created_at > now() - ((SELECT win_hours FROM params) || ' hours')::interval
      AND (p_sources IS NULL OR 'Broadway' = ANY (p_sources))
  ),
  -- Fed / FRED macro releases. One row per enabled FRED series for its latest
  -- reading, surfaced only while that reading is fresh — published_at = when the
  -- value first landed in our store (see mig 20260705120000). Between releases
  -- the row ages out of the window, so the wire flashes the Fed only when it
  -- actually updates.
  macro AS (
    WITH fred_series AS (
      SELECT series_id, display_name, units
      FROM public.macro_series_config
      WHERE enabled = true AND source = 'FRED'
    ),
    -- current vintage value per (series, observation_date): latest realtime_start wins
    vintage AS (
      SELECT DISTINCT ON (mi.series_id, mi.observation_date)
        mi.series_id, mi.observation_date, mi.value
      FROM public.macro_indicators mi
      JOIN fred_series fs ON fs.series_id = mi.series_id
      WHERE mi.value IS NOT NULL
      ORDER BY mi.series_id, mi.observation_date DESC, mi.realtime_start DESC
    ),
    seq AS (
      SELECT v.series_id, v.observation_date, v.value,
             row_number() OVER w AS rn,
             lead(v.value) OVER w AS prior_value
      FROM vintage v
      WINDOW w AS (PARTITION BY v.series_id ORDER BY v.observation_date DESC)
    ),
    latest AS (
      SELECT series_id, observation_date, value, prior_value
      FROM seq WHERE rn = 1
    ),
    -- min(ingested_at) over the current reading = when it first arrived ≈ release
    landed AS (
      SELECT l.series_id, l.observation_date, l.value, l.prior_value,
             min(mi.ingested_at) AS first_seen
      FROM latest l
      JOIN public.macro_indicators mi
        ON mi.series_id = l.series_id
       AND mi.observation_date = l.observation_date
       AND mi.value = l.value
      GROUP BY l.series_id, l.observation_date, l.value, l.prior_value
    )
    SELECT
      'Fed'::text   AS source,
      'MACRO'::text AS league,
      fs.display_name AS team,
      fs.display_name || ' ' || trim(to_char(ld.value, 'FM999990.00'))
        || CASE WHEN fs.units ILIKE '%percent%' THEN '%' ELSE '' END
        || ' (' || to_char(ld.observation_date, 'Mon YYYY') || ')'
        || CASE
             WHEN ld.prior_value IS NULL       THEN ''
             WHEN ld.value > ld.prior_value    THEN ' ▲'
             WHEN ld.value < ld.prior_value    THEN ' ▼'
             ELSE ' —'
           END                                      AS headline,
      NULLIF(
        CASE WHEN ld.prior_value IS NULL THEN ''
             ELSE 'prior ' || trim(to_char(ld.prior_value, 'FM999990.00'))
                  || CASE WHEN fs.units ILIKE '%percent%' THEN '%' ELSE '' END
                  || CASE WHEN ld.value <> ld.prior_value
                          THEN ' ('
                               || CASE WHEN ld.value > ld.prior_value THEN '+' ELSE '' END
                               || trim(to_char(ld.value - ld.prior_value, 'FM999990.00')) || ')'
                          ELSE ' (unchanged)' END
        END, '')                                    AS summary,
      'https://fred.stlouisfed.org/series/' || ld.series_id AS url,
      NULL::text    AS image_url,
      'macro'::text AS item_type,
      ld.first_seen AS published_at
    FROM landed ld
    JOIN fred_series fs ON fs.series_id = ld.series_id
    WHERE ld.first_seen > now() - ((SELECT win_hours FROM params) || ' hours')::interval
      AND (p_sources IS NULL OR 'Fed' = ANY (p_sources))
  ),
  -- X (Twitter) posts from the tracked-source roster, via TwitterAPI.io
  -- (x_news_queue/x_news_process, this migration). team = '@<author>' for
  -- attribution (the FE shows it as the source line, like 'r/<sub>' on Reddit
  -- rows). Long premium posts are clipped so one tweet can't swamp the reel.
  x_posts AS (
    SELECT
      'X'::text                                        AS source,
      x.league                                         AS league,
      '@' || x.author_handle                           AS team,
      CASE WHEN length(x.title) > 240
           THEN left(x.title, 237) || '…'
           ELSE x.title END                            AS headline,
      NULLIF(array_to_string(ARRAY(
        SELECT jsonb_array_elements_text(x.matched_keywords -> 'hits')
      ), ' · '), '')                                   AS summary,
      x.url                                            AS url,
      NULL::text                                       AS image_url,
      'x_post'::text                                   AS item_type,
      x.created_utc                                    AS published_at
    FROM public.v_x_news_ticker x
    WHERE x.created_utc > now() - ((SELECT win_hours FROM params) || ' hours')::interval
      AND (p_sources IS NULL OR 'X' = ANY (p_sources))
  ),
  unioned AS (
    SELECT * FROM espn
    UNION ALL SELECT * FROM transactions
    UNION ALL SELECT * FROM injuries
    UNION ALL SELECT * FROM scores
    UNION ALL SELECT * FROM standings
    UNION ALL SELECT * FROM reddit
    UNION ALL SELECT * FROM broadway
    UNION ALL SELECT * FROM bway_flags
    UNION ALL SELECT * FROM macro
    UNION ALL SELECT * FROM x_posts
  )
  SELECT u.source, u.league, u.team, u.headline, u.summary, u.url,
         u.image_url, u.item_type, u.published_at
  FROM unioned u, params
  WHERE (p_leagues IS NULL OR u.league = ANY (p_leagues))
    AND (params.q IS NULL
         OR u.headline ILIKE '%' || params.q || '%'
         OR coalesce(u.summary, '') ILIKE '%' || params.q || '%'
         OR coalesce(u.team, '')    ILIKE '%' || params.q || '%')
  ORDER BY u.published_at DESC NULLS LAST
  LIMIT (SELECT lim FROM params);
$function$;
