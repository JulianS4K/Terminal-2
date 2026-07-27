-- ============================================================================
-- Migration 20260706114500 — X (Twitter) news ticker via TwitterAPI.io
--
-- Lane:     xref+macro (A1 data plane — same owner as the reddit_news set)
-- Touches:  x_news_sources (W), x_news (W), x_news_pending (W),
--           important_x_accounts (R), retention_policy (W),
--           v_x_news_ticker (W/view), get_terminal_news_ticker (W/function)
-- Pre-reqs: 20260509420000 (important_x_accounts seed),
--           20260512100000 (trg_set_updated_at),
--           20260705120000 (get_terminal_news_ticker body restated here),
--           20260705153000 (retention_policy engine),
--           20260706113000 (get_app_secret whitelists TWITTERAPI_IO_KEY),
--           vault.TWITTERAPI_IO_KEY (operator creates; queue NO-OPS until set),
--           external: api.twitterapi.io reachable from pg_net
--
-- Operator directive (2026-07-06): surface X posts on the D0 NEWS WIRE with the
-- SAME MECHANICS AS REDDIT (mig 20260626120030) — a sources roster, a pg_net
-- GET queue polling one source per tick, a JSON processor, 48h read window,
-- read-time dedupe, source attribution, unioned into get_terminal_news_ticker.
-- Operator provides the sources + the API key; until both exist this pipeline
-- is INERT (roster ships disabled-only, queue no-ops without the vault key).
--
-- WHY TwitterAPI.io: X has no free read API (documented in mig 20260509420000 —
-- important_x_accounts was seeded as context-only because handles could not be
-- pulled). TwitterAPI.io is a paid READ gateway to X search:
--   GET https://api.twitterapi.io/twitter/tweet/advanced_search
--       ?queryType=Latest&query=<advanced search query>
--   header X-API-Key: <key>   → {"tweets":[...], "has_next_page", "next_cursor"}
-- Read-only (RULE 2): this pipeline only ever issues net.http_get; the host is
-- also registered in scripts/check_readonly.py FORBIDDEN_HOSTS so any future
-- write path to twitterapi.io fails CI.
--
-- COST CONTROL (paid API — differs from free old.reddit only in the knobs):
--   * roster rows are enabled=false by default; the seed (high-priority
--     insiders from important_x_accounts) ships DISABLED — operator opt-in.
--   * per-source poll_interval_minutes (default 15) floors how often any
--     source is polled; the queue fires ONE source per cron tick (1/min), so
--     N enabled sources ≈ N calls per poll_interval. ~4 calls/hr per source.
--   * one page per poll (~20 newest tweets), no cursor walking; tweet_id PK
--     dedupes overlap between polls.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- (1) Sources roster — WHAT to poll. kind='handle' rows poll the account's
--     own tweets (from:<handle> -filter:retweets -filter:replies); kind='query'
--     rows pass source_value verbatim as an X advanced-search query, so the
--     operator can track keywords/phrases too ("injury min_faves:100", etc.).
--     last_polled_at drives the same round-robin stagger as reddit_news_flairs.
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS x_news_sources (
  source_value          text PRIMARY KEY,   -- '@handle' | raw advanced-search query
  kind                  text NOT NULL DEFAULT 'handle' CHECK (kind IN ('handle', 'query')),
  league                text,               -- denormalized for ticker filters
  enabled               boolean NOT NULL DEFAULT false,  -- PAID API → opt-in
  poll_interval_minutes integer NOT NULL DEFAULT 15 CHECK (poll_interval_minutes >= 2),
  last_polled_at        timestamptz,        -- round-robin cursor (queue stagger)
  notes                 text,
  created_at            timestamptz NOT NULL DEFAULT now(),
  updated_at            timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE x_news_sources IS
  'Roster of X (Twitter) sources for the NEWS WIRE, polled via TwitterAPI.io '
  'advanced search (x_news_queue). kind=handle → from:<handle> query; '
  'kind=query → source_value verbatim. enabled defaults FALSE (paid API — '
  'operator opt-in); poll_interval_minutes floors per-source spend. Seeded '
  'DISABLED from important_x_accounts high-priority insiders; the operator '
  'enables rows / adds their own.';

DROP TRIGGER IF EXISTS x_news_sources_updated_at ON x_news_sources;
CREATE TRIGGER x_news_sources_updated_at
  BEFORE UPDATE ON x_news_sources
  FOR EACH ROW EXECUTE FUNCTION trg_set_updated_at();

-- Seed: the high-priority insider handles already curated in
-- important_x_accounts (mig 20260509420000). DISABLED — flipping enabled=true
-- (and creating the vault key) is the operator's explicit opt-in to spend.
INSERT INTO x_news_sources (source_value, kind, league, enabled, notes)
SELECT xa.handle, 'handle', xa.league, false,
       'seed: ' || xa.name || ' (' || xa.account_type || ') — opt-in'
FROM important_x_accounts xa
WHERE xa.priority = 'high' AND xa.account_type = 'insider'
ON CONFLICT (source_value) DO NOTHING;

-- ----------------------------------------------------------------------------
-- (2) Storage — tweet text as the headline. Retention via retention_policy
--     (engine, mig 20260705153000) — NOT a bespoke sweep cron; the ticker view
--     windows at 48h so the 3-day TTL floor is invisible to the wire.
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS x_news (
  tweet_id      text PRIMARY KEY,
  source_value  text NOT NULL,             -- roster row that pulled it (attribution/debug)
  league        text,                      -- denormalized from the roster row
  author_handle text NOT NULL,             -- tweet author (no '@'; may differ from source on kind=query)
  author_name   text,
  title         text NOT NULL,             -- tweet text (the headline)
  url           text,                      -- canonical tweet URL
  created_utc   timestamptz,               -- tweet createdAt
  pulled_at     timestamptz NOT NULL DEFAULT now(),
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS x_news_recent_idx ON x_news(created_utc DESC);
CREATE INDEX IF NOT EXISTS x_news_pulled_idx ON x_news(pulled_at);
CREATE INDEX IF NOT EXISTS x_news_league_idx ON x_news(league, created_utc DESC);

COMMENT ON TABLE x_news IS
  'X (Twitter) posts for the D0 NEWS WIRE, pulled from TwitterAPI.io advanced '
  'search (x_news_queue/x_news_process — reddit_news mechanics). Tweet text '
  'only. TTL via retention_policy (3d floor; wire reads 48h). Read-time dedupe '
  'in v_x_news_ticker (first-post-shows). ON CONFLICT DO NOTHING on re-pull: '
  'first pull wins so published ordering stays stable.';

DROP TRIGGER IF EXISTS x_news_updated_at ON x_news;
CREATE TRIGGER x_news_updated_at
  BEFORE UPDATE ON x_news
  FOR EACH ROW EXECUTE FUNCTION trg_set_updated_at();

-- RLS: deny-by-default (service_role bypasses; the terminal reads via the
-- SECURITY DEFINER get_terminal_news_ticker RPC). Matches reddit_news posture.
ALTER TABLE x_news         ENABLE ROW LEVEL SECURITY;
ALTER TABLE x_news_sources ENABLE ROW LEVEL SECURITY;

-- ----------------------------------------------------------------------------
-- (3) Async pull queue (same pg_net pattern as reddit_news_pending).
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS x_news_pending (
  id             bigserial PRIMARY KEY,
  source_value   text NOT NULL,
  kind           text,
  league         text,
  request_id     bigint NOT NULL,
  fired_at       timestamptz NOT NULL DEFAULT now(),
  resolved_at    timestamptz,
  rows_persisted int
);

CREATE INDEX IF NOT EXISTS x_news_pending_unresolved_idx
  ON x_news_pending(fired_at) WHERE resolved_at IS NULL;

ALTER TABLE x_news_pending ENABLE ROW LEVEL SECURITY;

-- ----------------------------------------------------------------------------
-- (4) Helpers — percent-encoder for the query param + tolerant createdAt parse.
-- ----------------------------------------------------------------------------

-- Generic RFC-3986 percent-encoder (unreserved chars pass through; everything
-- else — including UTF-8 multibyte — becomes %XX per byte). Needed because
-- advanced-search queries carry spaces/colons/quotes/@ and Postgres has no
-- built-in urlencode.
CREATE OR REPLACE FUNCTION x_news_urlencode(p_text text)
RETURNS text LANGUAGE sql IMMUTABLE STRICT AS $$
  SELECT coalesce(string_agg(
    CASE WHEN t.c ~ '^[A-Za-z0-9_.~-]$' THEN t.c
         ELSE regexp_replace(upper(encode(convert_to(t.c, 'UTF8'), 'hex')),
                             '(..)', '%\1', 'g')
    END, '' ORDER BY t.i), '')
  FROM regexp_split_to_table(p_text, '') WITH ORDINALITY AS t(c, i);
$$;

-- TwitterAPI.io tweets carry Twitter's classic timestamp format
-- ('Tue Dec 10 07:00:30 +0000 2024'); tolerate ISO-8601 too, NULL on garbage.
CREATE OR REPLACE FUNCTION x_news_parse_ts(p_raw text)
RETURNS timestamptz LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
  IF p_raw IS NULL OR btrim(p_raw) = '' THEN RETURN NULL; END IF;
  BEGIN
    RETURN to_timestamp(p_raw, 'Dy Mon DD HH24:MI:SS TZHTZM YYYY');
  EXCEPTION WHEN others THEN NULL;
  END;
  BEGIN
    RETURN p_raw::timestamptz;
  EXCEPTION WHEN others THEN RETURN NULL;
  END;
END; $$;

-- ----------------------------------------------------------------------------
-- (5) Queue — fire ONE advanced-search GET for the least-recently-polled
--     enabled source per cron tick. One-per-tick keeps each pg_net request in
--     its own txn (same rationale as reddit_news_queue) and makes spend
--     linear + predictable. NO-OPS (returns 0) until the operator has created
--     vault.TWITTERAPI_IO_KEY — safe to apply before the key exists.
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
    ORDER BY s.last_polled_at ASC NULLS FIRST, s.source_value
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
-- (6) Process — parse the JSON page ({"tweets":[...]}) into x_news rows.
-- ----------------------------------------------------------------------------
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
            title, url, created_utc
          )
          SELECT
            t ->> 'id',
            r.source_value,
            r.league,
            coalesce(t #>> '{author,userName}', ''),
            t #>> '{author,name}',
            t ->> 'text',
            coalesce(t ->> 'url', 'https://x.com/i/status/' || (t ->> 'id')),
            coalesce(x_news_parse_ts(t ->> 'createdAt'), now())
          FROM jsonb_array_elements(v_json -> 'tweets') t
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
-- (7) Retention — engine rows (mig 20260705153000), not bespoke sweep crons.
--     keep_days floor is 3; the ticker view reads only the last 48h anyway.
-- ----------------------------------------------------------------------------
INSERT INTO retention_policy (table_name, ts_column, keep_days, notes)
VALUES
  ('x_news',         'pulled_at', 3, 'X news wire rows — view windows 48h; 3d = engine floor. Mig 20260706114500.'),
  ('x_news_pending', 'fired_at',  3, 'X news pg_net queue bookkeeping. Mig 20260706114500.')
ON CONFLICT (table_name) DO NOTHING;

-- ----------------------------------------------------------------------------
-- (8) Ticker view — newest-first, 48h, deduped on normalized tweet text on a
--     FIRST-POST-SHOWS basis (same wire copy tweeted by several tracked
--     accounts shows once, attributed to whoever posted it first). tweet_id PK
--     already collapses the same tweet arriving via multiple roster queries.
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
    title, url, created_utc
  FROM win
  ORDER BY dedupe_key, created_utc ASC NULLS LAST
)
SELECT * FROM deduped
ORDER BY created_utc DESC NULLS LAST;

COMMENT ON VIEW v_x_news_ticker IS
  'Newest-first X (Twitter) ticker, last 48h, deduped on normalized tweet text '
  'first-post-shows (mirror of v_reddit_news_ticker). author_handle exposed for '
  'source attribution. Source: TwitterAPI.io advanced search via x_news_queue.';

-- ----------------------------------------------------------------------------
-- (9) get_terminal_news_ticker — restate (CREATE OR REPLACE replaces the whole
--     body) all 9 sources from 20260705120000 verbatim and append `x_posts`
--     (source='X', item_type='x_post', team='@<author>'). Idempotent.
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
      NULL::text                                       AS summary,
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

-- ----------------------------------------------------------------------------
-- (10) Crons (applied with the migration; safe pre-key — the queue no-ops).
--     Queue: 1/min tick, ONE source per fire (per-request txn isolation, same
--            rationale as reddit_news_queue_30s; paid API → the per-source
--            poll_interval_minutes floor, default 15, bounds spend).
--     Process: every 1 min (pg_net responses land within seconds).
--     Both wrapped in the cron_should_fire() gate + BEGIN/SET LOCAL/COMMIT
--     (RESOURCES_BIBLE §5 new-cron rule; the §3 pooled-connection SET landmine).
--     work_check_sql keeps the bodies from firing at all while the roster is
--     disabled / the queue is empty — the shipped state.
--     No sweep cron — retention_policy rows (§7) handle TTL via retention_tick.
-- ----------------------------------------------------------------------------
SELECT cron.unschedule('x_news_queue_1min')   WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'x_news_queue_1min');
SELECT cron.unschedule('x_news_process_1min') WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'x_news_process_1min');

SELECT cron.schedule(
  'x_news_queue_1min',
  '* * * * *',
  $cron$BEGIN; SET LOCAL statement_timeout='60s'; DO $b$ BEGIN
    IF NOT public.cron_should_fire('x_news_queue_1min') THEN RETURN; END IF;
    PERFORM public.x_news_queue(1);
  END $b$; COMMIT;$cron$
);

SELECT cron.schedule(
  'x_news_process_1min',
  '* * * * *',
  $cron$BEGIN; SET LOCAL statement_timeout='120s'; DO $b$ BEGIN
    IF NOT public.cron_should_fire('x_news_process_1min') THEN RETURN; END IF;
    PERFORM public.x_news_process();
  END $b$; COMMIT;$cron$
);

INSERT INTO public.cron_policy (jobname, peak_hours_et, peak_min_interval_min,
  offpeak_min_interval_min, daily_max_fires, work_check_sql, enabled, notes)
VALUES
  ('x_news_queue_1min', ARRAY[]::int[], 1, 1, NULL,
   'SELECT EXISTS (SELECT 1 FROM public.x_news_sources s WHERE s.enabled AND (s.last_polled_at IS NULL OR s.last_polled_at < now() - (s.poll_interval_minutes || '' minutes'')::interval) LIMIT 1)',
   true,
   'X news wire — TwitterAPI.io advanced-search puller (1 source/fire; per-source poll_interval_minutes floors spend; fn also no-ops without vault TWITTERAPI_IO_KEY). Mig 20260706114500.'),
  ('x_news_process_1min', ARRAY[]::int[], 1, 1, NULL,
   'SELECT EXISTS (SELECT 1 FROM public.x_news_pending p WHERE p.resolved_at IS NULL LIMIT 1)',
   true,
   'X news wire — parse TwitterAPI.io JSON responses into x_news. Mig 20260706114500.')
ON CONFLICT (jobname) DO UPDATE
  SET peak_hours_et = EXCLUDED.peak_hours_et,
      peak_min_interval_min = EXCLUDED.peak_min_interval_min,
      offpeak_min_interval_min = EXCLUDED.offpeak_min_interval_min,
      daily_max_fires = EXCLUDED.daily_max_fires,
      work_check_sql = EXCLUDED.work_check_sql,
      enabled = EXCLUDED.enabled,
      notes = EXCLUDED.notes,
      updated_at = now();
