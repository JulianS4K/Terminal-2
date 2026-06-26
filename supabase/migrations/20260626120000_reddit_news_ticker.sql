-- ============================================================================
-- Migration 20260626120000 — Reddit news ticker (flair-filtered sports news)
--
-- Lane:     xref+macro (A1 data plane — same owner as the dormant reddit_* set)
-- Touches:  reddit_news (W), reddit_news_pending (W), reddit_news_flairs (W),
--           general_subreddits (R), v_reddit_news_ticker (W/view)
-- Pre-reqs: 20260509420000 (general_subreddits seed),
--           20260512100000 (trg_set_updated_at),
--           external: old.reddit.com reachable from pg_net
--
-- Operator directive (2026-06-26): add Reddit as a PURE-NEWS source — a news
-- ticker filtered to news-flair posts, title-only, 24h retention, links deduped.
--
-- WHY A NEW PIPELINE (not a revival of reddit_queue/reddit_process):
--   The dormant pipeline (mig 20260509410000, paused 20260513002000) pulls the
--   per-sub Atom feed (old.reddit.com/r/<sub>/.rss). That feed carries NO post
--   flair, so it cannot be filtered to "news". The JSON API that *does* expose
--   link_flair_text returns 403+HTML to non-browser User-Agents (documented in
--   mig 20260509410000 lines 17-20, verified live 2026-05-09) — so reading flair
--   per post off the JSON listing is not a free/unauth path.
--
--   This pipeline instead uses Reddit's SEARCH RSS endpoint with a server-side
--   flair filter:
--     old.reddit.com/r/<sub>/search.rss?q=flair_name:"News"&restrict_sr=on&sort=new
--   The flair filter is applied by Reddit, so every Atom entry returned is
--   already a news-flaired post — we never need the (absent) flair field on the
--   entry. Stays on the UA-friendly RSS path the repo already proved works.
--
--   ⚠ VERIFICATION GATE (A1, on preview branch before merge): confirm the
--   search.rss + flair_name query returns 200 + Atom entries for a sample sub
--   (e.g. r/nba). If Reddit blocks/empties it, fall back to keyword filtering
--   via the existing match_news_keywords() over a plain feed — see Red flags.
--
-- DESIGN to spec:
--   * Title only        — store title + clickable link; NO body/selftext.
--   * 24h retention      — reddit_news_sweep() deletes rows older than 24h.
--   * Dedupe links       — v_reddit_news_ticker collapses the same story posted
--                          across multiple subs (key = external link, else title).
--   * Sports only        — seeded from general_subreddits where league is a sport
--                          (excludes Broadway/Concerts, which lack a News flair).
--
-- COST NOTE: the dormant pipeline was paused for resource pressure (18s/queue
--   call). This one is lighter: seeded with the ~general league subs only
--   (team subs ship disabled, opt-in), p_limit 20, 30-min cadence, ≤25 filtered
--   entries per sub, title-only rows, hourly sweep keeping the table ≤24h small.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- (1) Flair config — which flair name counts as "news" per subreddit.
--     Flair taxonomy varies per sub; default 'News', tunable without code.
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS reddit_news_flairs (
  subreddit    text PRIMARY KEY,
  league       text,
  flair_query  text NOT NULL DEFAULT 'News',  -- exact flair_name to match
  enabled      boolean NOT NULL DEFAULT true,
  notes        text,
  created_at   timestamptz NOT NULL DEFAULT now(),
  updated_at   timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE reddit_news_flairs IS
  'Per-subreddit news-flair config for the Reddit news ticker. flair_query is '
  'the exact Reddit flair_name to filter to (default ''News''). enabled gates '
  'whether reddit_news_queue() pulls it. Team subs seed disabled (opt-in) to '
  'keep the queue light — flip enabled=true to add them.';

DROP TRIGGER IF EXISTS reddit_news_flairs_updated_at ON reddit_news_flairs;
CREATE TRIGGER reddit_news_flairs_updated_at
  BEFORE UPDATE ON reddit_news_flairs
  FOR EACH ROW EXECUTE FUNCTION trg_set_updated_at();

-- Seed: general league subs that are SPORTS (Broadway/Concerts excluded — no
-- reliable News flair). Enabled. Team subs added disabled below.
INSERT INTO reddit_news_flairs (subreddit, league, flair_query, enabled, notes)
SELECT gs.subreddit, gs.league, 'News', true, 'general league sub'
FROM general_subreddits gs
WHERE gs.league NOT IN ('Broadway', 'Concerts')
ON CONFLICT (subreddit) DO NOTHING;

-- Team subs: seeded DISABLED. Operator flips enabled=true to widen coverage.
INSERT INTO reddit_news_flairs (subreddit, league, flair_query, enabled, notes)
SELECT DISTINCT ps.subreddit, NULL, 'News', false, 'team sub — opt-in'
FROM performer_subreddits ps
ON CONFLICT (subreddit) DO NOTHING;

-- ----------------------------------------------------------------------------
-- (2) Storage — title-only news rows. 24h retention enforced by sweep.
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS reddit_news (
  reddit_post_id   text PRIMARY KEY,        -- 't3_xxx'
  subreddit        text NOT NULL,
  league           text,                    -- denormalized for ticker filters
  title            text NOT NULL,           -- TITLE ONLY (no body, per spec)
  permalink        text,                    -- reddit thread link (Atom <link>)
  link_url         text,                    -- external article link if present
  link_flair_text  text,                    -- the news flair this matched
  created_utc      timestamptz,             -- post time (Atom <updated>)
  pulled_at        timestamptz NOT NULL DEFAULT now(),
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS reddit_news_recent_idx ON reddit_news(created_utc DESC);
CREATE INDEX IF NOT EXISTS reddit_news_pulled_idx ON reddit_news(pulled_at);
CREATE INDEX IF NOT EXISTS reddit_news_league_idx ON reddit_news(league, created_utc DESC);

COMMENT ON TABLE reddit_news IS
  'Flair-filtered Reddit sports news for the news ticker. Title-only; populated '
  'from search.rss?q=flair_name:"News". 24h retention (reddit_news_sweep). Dedupe '
  'happens at read time in v_reddit_news_ticker. Separate from the dormant '
  'reddit_posts (append-only sentiment) by design — different shape + retention.';

DROP TRIGGER IF EXISTS reddit_news_updated_at ON reddit_news;
CREATE TRIGGER reddit_news_updated_at
  BEFORE UPDATE ON reddit_news
  FOR EACH ROW EXECUTE FUNCTION trg_set_updated_at();

-- RLS: deny-by-default (service_role bypasses; the broker API reads via service
-- key). Matches recent RLS-hardening posture. A1 may add a read policy if a
-- direct-anon read path is ever needed.
ALTER TABLE reddit_news        ENABLE ROW LEVEL SECURITY;
ALTER TABLE reddit_news_flairs ENABLE ROW LEVEL SECURITY;

-- ----------------------------------------------------------------------------
-- (3) Async pull queue (same pg_net pattern as wiki/weather/reddit_posts).
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS reddit_news_pending (
  id              bigserial PRIMARY KEY,
  subreddit       text NOT NULL,
  league          text,
  flair_query     text,
  request_id      bigint NOT NULL,
  fired_at        timestamptz NOT NULL DEFAULT now(),
  resolved_at     timestamptz,
  rows_persisted  int
);

CREATE INDEX IF NOT EXISTS reddit_news_pending_unresolved_idx
  ON reddit_news_pending(fired_at) WHERE resolved_at IS NULL;

-- ----------------------------------------------------------------------------
-- (4) Queue — fire one search.rss request per enabled sub not pulled in 30min.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION reddit_news_queue(p_limit int DEFAULT 20)
RETURNS int LANGUAGE plpgsql AS $$
DECLARE
  r RECORD; v_req_id bigint; v_count int := 0; v_url text;
BEGIN
  FOR r IN
    SELECT f.subreddit, f.league, f.flair_query
    FROM reddit_news_flairs f
    LEFT JOIN reddit_news_pending p ON p.subreddit = f.subreddit
        AND p.fired_at > now() - interval '30 minutes'
    WHERE f.enabled AND p.id IS NULL
    ORDER BY f.subreddit
    LIMIT p_limit
  LOOP
    -- Server-side flair filter: every returned entry is already news-flaired.
    -- restrict_sr=on keeps it within the sub; sort=new + t=day for freshness.
    v_url := 'https://old.reddit.com/r/' || r.subreddit
          || '/search.rss?q=flair_name%3A%22'
          || replace(r.flair_query, ' ', '%20')
          || '%22&restrict_sr=on&sort=new&limit=25&t=day';

    SELECT net.http_get(
      url := v_url,
      headers := jsonb_build_object(
        'User-Agent', 'Terminal2-S4K-RSS/1.0',
        'Accept', 'application/rss+xml, application/xml'),
      timeout_milliseconds := 12000
    ) INTO v_req_id;

    INSERT INTO reddit_news_pending(subreddit, league, flair_query, request_id, fired_at)
    VALUES (r.subreddit, r.league, r.flair_query, v_req_id, now());
    v_count := v_count + 1;
    PERFORM pg_sleep(0.5);
  END LOOP;
  RETURN v_count;
END; $$;

-- ----------------------------------------------------------------------------
-- (5) Process — parse Atom entries, store title-only news rows.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION reddit_news_process()
RETURNS TABLE(processed int, posts_persisted int) LANGUAGE plpgsql AS $$
DECLARE
  r RECORD; v_xml text; v_count int;
  v_processed int := 0; v_persisted int := 0;
BEGIN
  FOR r IN
    SELECT p.id, p.subreddit, p.league, p.flair_query, p.request_id,
           h.content, h.status_code
    FROM reddit_news_pending p
    JOIN net._http_response h ON h.id = p.request_id
    WHERE p.resolved_at IS NULL
  LOOP
    v_processed := v_processed + 1;
    v_count := 0;
    IF r.status_code = 200 AND r.content IS NOT NULL THEN
      v_xml := r.content;
      WITH entries AS (
        SELECT (regexp_matches(v_xml, '<entry>(.*?)</entry>', 'g'))[1] AS entry
      ),
      parsed AS (
        SELECT
          (regexp_match(e.entry, '(t3_[a-z0-9]+)'))[1]                        AS reddit_post_id,
          (regexp_match(e.entry, '<title>([^<]*)</title>'))[1]                AS title,
          (regexp_match(e.entry, '<link\s+href=\"([^\"]+)\"'))[1]            AS permalink,
          (regexp_match(e.entry, '<updated>([^<]+)</updated>'))[1]            AS updated_str,
          -- best-effort external article link from the content HTML: first
          -- href that is not a reddit.com / redd.it URL. NULL if none.
          (regexp_match(e.entry,
            'href="(https?://(?!(?:[^"/]*\.)?(?:reddit\.com|redd\.it))[^"]+)"'))[1] AS link_url
        FROM entries e
      ),
      ins AS (
        INSERT INTO reddit_news (
          reddit_post_id, subreddit, league, title, permalink, link_url,
          link_flair_text, created_utc
        )
        SELECT
          p.reddit_post_id, r.subreddit, r.league,
          p.title, p.permalink, p.link_url,
          r.flair_query,
          NULLIF(p.updated_str,'')::timestamptz
        FROM parsed p
        WHERE p.reddit_post_id IS NOT NULL AND COALESCE(p.title,'') <> ''
        ON CONFLICT (reddit_post_id) DO UPDATE SET
          title           = EXCLUDED.title,
          permalink       = EXCLUDED.permalink,
          link_url        = EXCLUDED.link_url,
          link_flair_text = EXCLUDED.link_flair_text,
          created_utc     = EXCLUDED.created_utc,
          pulled_at       = now()
        RETURNING 1
      )
      SELECT count(*) INTO v_count FROM ins;
      v_persisted := v_persisted + v_count;
    END IF;

    UPDATE reddit_news_pending SET resolved_at = now(), rows_persisted = v_count
    WHERE id = r.id;
  END LOOP;
  RETURN QUERY SELECT v_processed, v_persisted;
END; $$;

-- ----------------------------------------------------------------------------
-- (6) Sweep — enforce 24h retention on news rows + clean resolved pendings.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION reddit_news_sweep()
RETURNS int LANGUAGE plpgsql AS $$
DECLARE v_n int;
BEGIN
  DELETE FROM reddit_news WHERE pulled_at < now() - interval '24 hours';
  GET DIAGNOSTICS v_n = ROW_COUNT;
  DELETE FROM reddit_news_pending
  WHERE resolved_at IS NOT NULL AND resolved_at < now() - interval '6 hours';
  RETURN v_n;
END; $$;

-- ----------------------------------------------------------------------------
-- (7) Ticker view — newest-first, deduped by link (else title).
--     Same story cross-posted to multiple subs collapses to one row.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_reddit_news_ticker AS
WITH win AS (
  SELECT
    rn.*,
    -- dedupe key: external link when present, else normalized title.
    COALESCE(
      NULLIF(lower(rn.link_url), ''),
      lower(regexp_replace(rn.title, '\s+', ' ', 'g'))
    ) AS dedupe_key
  FROM reddit_news rn
  WHERE rn.pulled_at > now() - interval '24 hours'
),
deduped AS (
  SELECT DISTINCT ON (dedupe_key)
    reddit_post_id, subreddit, league, title, permalink, link_url,
    link_flair_text, created_utc
  FROM win
  ORDER BY dedupe_key, created_utc DESC NULLS LAST
)
SELECT * FROM deduped
ORDER BY created_utc DESC NULLS LAST;

COMMENT ON VIEW v_reddit_news_ticker IS
  'Newest-first Reddit sports news ticker, last 24h, deduped by external link '
  '(falling back to normalized title) so a story cross-posted to multiple subs '
  'shows once. Title-only. Source: news-flaired posts via search.rss.';

-- ----------------------------------------------------------------------------
-- (8) Crons (applied by A1 on merge). New names — no collision with the
--     unscheduled reddit_queue_30min / reddit_process_30min / sweep.
-- ----------------------------------------------------------------------------
SELECT cron.schedule(
  'reddit_news_queue_30min',
  '7-59/30 * * * *',
  $$ SELECT reddit_news_queue(20); $$
);

SELECT cron.schedule(
  'reddit_news_process_30min',
  '12-59/30 * * * *',
  $$ SELECT reddit_news_process(); $$
);

SELECT cron.schedule(
  'reddit_news_sweep_hourly',
  '37 * * * *',
  $$ SELECT reddit_news_sweep(); $$
);
