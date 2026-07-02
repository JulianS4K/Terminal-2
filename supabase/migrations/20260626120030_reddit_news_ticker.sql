-- ============================================================================
-- Migration 20260626120030 — Reddit news ticker (flair-filtered sports news)
--
-- Lane:     xref+macro (A1 data plane — same owner as the dormant reddit_* set)
-- Touches:  reddit_news (W), reddit_news_pending (W), reddit_news_flairs (W),
--           general_subreddits (R), v_reddit_news_ticker (W/view)
-- Pre-reqs: 20260509420000 (general_subreddits seed),
--           20260512100000 (trg_set_updated_at),
--           external: old.reddit.com reachable from pg_net
--
-- Operator directive (2026-06-26, extended 2026-07-02): add Reddit as a
-- PURE-NEWS source — a news ticker filtered to news-flair posts, title-only,
-- 48h retention, external links deduped on a FIRST-POST-SHOWS basis, source
-- subreddit surfaced for attribution. Polled on a ~5-min staggered cadence.
--
-- WHY A NEW PIPELINE (not a revival of reddit_queue/reddit_process):
--   The dormant pipeline (mig 20260509410000, paused 20260513002000) pulls the
--   per-sub Atom feed (old.reddit.com/r/<sub>/.rss). That feed carries NO post
--   flair, so it cannot be filtered to "news". The JSON API that *does* expose
--   link_flair_text returns 403+HTML to non-browser User-Agents (documented in
--   mig 20260509410000 lines 17-20; re-verified live 2026-07-02: www.reddit.com
--   /r/<sub>/new.json → 403 + block-page HTML from the pg_net datacenter IP) —
--   so reading flair per post off the JSON listing is not a free/unauth path.
--
--   This pipeline instead uses Reddit's SEARCH RSS endpoint with a server-side
--   flair filter:
--     old.reddit.com/r/<sub>/search.rss?q=flair:"News"&restrict_sr=on&sort=new
--   The flair filter is applied by Reddit, so every Atom entry returned is
--   already a news-flaired post — we never need the (absent) flair field on the
--   entry. Stays on the UA-friendly RSS path the repo already proved works.
--
--   ✓ VERIFIED LIVE 2026-07-02 (pg_net from prod):
--     * The operator is `flair:` — NOT `flair_name:`. flair_name:"News" returns
--       200 + 0 entries on r/nba; flair:"News" returns the real news posts
--       (Charania trade/injury headlines). The wrong token ships an EMPTY ticker.
--     * Subs with a WORKING News flair (10 real entries each): nba, Broadway,
--       musicals, Music (+ the other major sports subs by the same convention).
--     * Subs with NO News flair (200 + 0): Festivals, LiveMusic, StubHub,
--       Ticketmaster — NOT seeded. Pruned mis-fits: nbadiscussion (curated),
--       F1Technical (technical), formuladank (memes), mlbthebigshow (a video-game
--       sub, not baseball).
--     * Rate limit: old.reddit throttles hard (~2-3 rapid requests then 429).
--       The queue therefore fires ONE sub per tick on a ~30s stagger (see §4/§8),
--       giving each enabled sub a poll ~every 5 min. Do NOT batch-fire subs.
--   Fallback if flair search is ever unavailable: broad keyword search (q=trade
--   etc.) also works; match_news_keywords() over a plain feed remains the backup.
--
-- DESIGN to spec:
--   * Title only         — store title + clickable link; NO body/selftext.
--   * 48h retention       — reddit_news_sweep() deletes rows older than 48h.
--   * Dedupe links        — v_reddit_news_ticker collapses the same external URL
--                           (falling back to normalized title) to the FIRST post
--                           that carried it (earliest created_utc wins → stable
--                           attribution to the sub that broke the story).
--   * Source attribution  — the view exposes subreddit; the D0 NEWS WIRE shows it.
--   * Sports + arts       — seeded from general_subreddits (sports) PLUS the three
--                           arts subs with a verified News flair (Broadway/musicals
--                           /Music). Team subs ship disabled (opt-in).
-- ============================================================================

-- ----------------------------------------------------------------------------
-- (1) Flair config — which flair name counts as "news" per subreddit.
--     Flair taxonomy varies per sub; default 'News', tunable without code.
--     last_polled_at drives the round-robin stagger in reddit_news_queue().
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS reddit_news_flairs (
  subreddit      text PRIMARY KEY,
  league         text,
  flair_query    text NOT NULL DEFAULT 'News',  -- exact flair value (search `flair:`)
  enabled        boolean NOT NULL DEFAULT true,
  last_polled_at timestamptz,                    -- round-robin cursor (queue stagger)
  notes          text,
  created_at     timestamptz NOT NULL DEFAULT now(),
  updated_at     timestamptz NOT NULL DEFAULT now()
);

-- Idempotent add for envs where the table pre-dates last_polled_at.
ALTER TABLE reddit_news_flairs ADD COLUMN IF NOT EXISTS last_polled_at timestamptz;

COMMENT ON TABLE reddit_news_flairs IS
  'Per-subreddit news-flair config for the Reddit news ticker. flair_query is '
  'the exact Reddit flair value matched by the search operator `flair:"<value>"` '
  '(default ''News''). enabled gates whether reddit_news_queue() pulls it; '
  'last_polled_at is the round-robin cursor so the queue staggers one sub per '
  'tick (old.reddit rate-limits bursts). Team subs seed disabled (opt-in).';

DROP TRIGGER IF EXISTS reddit_news_flairs_updated_at ON reddit_news_flairs;
CREATE TRIGGER reddit_news_flairs_updated_at
  BEFORE UPDATE ON reddit_news_flairs
  FOR EACH ROW EXECUTE FUNCTION trg_set_updated_at();

-- Seed: general league subs that are SPORTS (Broadway/Concerts handled below).
-- Enabled. Team subs added disabled below.
-- EXCLUDED (verified 2026-07-02, live probe): subs with no working News flair —
--   nbadiscussion  (curated discussion sub, no News flair → 0 entries),
--   F1Technical    (technical Q&A sub, no News flair),
--   formuladank    (meme sub — Shitpost/Meme flairs only),
--   mlbthebigshow  (MLB The Show *video game* sub, not baseball news).
-- A blanket flair:"News" pull on these returns nothing, so they are not seeded.
INSERT INTO reddit_news_flairs (subreddit, league, flair_query, enabled, notes)
SELECT gs.subreddit, gs.league, 'News', true, 'general league sub'
FROM general_subreddits gs
WHERE gs.league NOT IN ('Broadway', 'Concerts')
  AND gs.subreddit NOT IN ('nbadiscussion', 'F1Technical', 'formuladank', 'mlbthebigshow')
ON CONFLICT (subreddit) DO NOTHING;

-- Arts/culture subs with a VERIFIED working News flair (live probe 2026-07-02:
-- 10 real news entries each). The remaining Broadway/Concerts subs (Festivals,
-- LiveMusic) returned 200 + 0 entries — no News flair — so they stay excluded.
INSERT INTO reddit_news_flairs (subreddit, league, flair_query, enabled, notes)
VALUES
  ('Broadway', 'Broadway', 'News', true, 'theatre news — verified flair:"News"'),
  ('musicals', 'Broadway', 'News', true, 'theatre news — verified flair:"News"'),
  ('Music',    'Concerts', 'News', true, 'music news — verified flair:"News"')
ON CONFLICT (subreddit) DO NOTHING;

-- Team subs: seeded DISABLED. Operator flips enabled=true to widen coverage.
-- (Most NFL/NBA/etc. team subs carry a News flair too — verify per-sub on enable.)
INSERT INTO reddit_news_flairs (subreddit, league, flair_query, enabled, notes)
SELECT DISTINCT ps.subreddit, NULL, 'News', false, 'team sub — opt-in'
FROM performer_subreddits ps
ON CONFLICT (subreddit) DO NOTHING;

-- ----------------------------------------------------------------------------
-- (2) Storage — title-only news rows. 48h retention enforced by sweep.
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
  'Flair-filtered Reddit news for the D0 NEWS WIRE ticker. Title-only; populated '
  'from search.rss?q=flair:"News". 48h retention (reddit_news_sweep). Dedupe '
  'happens at read time in v_reddit_news_ticker (first-post-shows). Separate from '
  'the dormant reddit_posts (append-only sentiment) by design — different shape.';

DROP TRIGGER IF EXISTS reddit_news_updated_at ON reddit_news;
CREATE TRIGGER reddit_news_updated_at
  BEFORE UPDATE ON reddit_news
  FOR EACH ROW EXECUTE FUNCTION trg_set_updated_at();

-- RLS: deny-by-default (service_role bypasses; the terminal reads via the
-- SECURITY DEFINER get_terminal_news_ticker RPC). Matches RLS-hardening posture.
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
-- (4) Queue — fire ONE search.rss request for the least-recently-polled enabled
--     sub, on each ~30s cron tick (§8). One-per-tick is deliberate: old.reddit
--     429s bursts (verified 2026-07-02). With ~13 enabled subs and a 30s tick,
--     each sub is polled roughly every 5 min. A 4-min floor stops any sub being
--     hit too often when few are enabled.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION reddit_news_queue(p_limit int DEFAULT 1)
RETURNS int LANGUAGE plpgsql AS $$
DECLARE
  r RECORD; v_req_id bigint; v_count int := 0; v_url text;
BEGIN
  FOR r IN
    SELECT f.subreddit, f.league, f.flair_query
    FROM reddit_news_flairs f
    WHERE f.enabled
      AND (f.last_polled_at IS NULL
           OR f.last_polled_at < now() - interval '4 minutes')
    ORDER BY f.last_polled_at ASC NULLS FIRST, f.subreddit
    LIMIT p_limit
  LOOP
    -- Server-side flair filter: every returned entry is already news-flaired.
    -- restrict_sr=on keeps it within the sub; sort=new for freshness. The sweep
    -- (48h) + view window handle retention, so no &t= time-clamp on the query.
    -- NOTE: the search operator is `flair:` — NOT `flair_name:` (see header).
    v_url := 'https://old.reddit.com/r/' || r.subreddit
          || '/search.rss?q=flair%3A%22'
          || replace(r.flair_query, ' ', '%20')
          || '%22&restrict_sr=on&sort=new&limit=25';

    SELECT net.http_get(
      url := v_url,
      headers := jsonb_build_object(
        'User-Agent', 'Terminal2-S4K-RSS/1.0',
        'Accept', 'application/rss+xml, application/xml'),
      timeout_milliseconds := 12000
    ) INTO v_req_id;

    INSERT INTO reddit_news_pending(subreddit, league, flair_query, request_id, fired_at)
    VALUES (r.subreddit, r.league, r.flair_query, v_req_id, now());

    -- Advance the round-robin cursor so the next tick picks a different sub.
    UPDATE reddit_news_flairs SET last_polled_at = now() WHERE subreddit = r.subreddit;
    v_count := v_count + 1;
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
-- (6) Sweep — enforce 48h retention on news rows + clean resolved pendings.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION reddit_news_sweep()
RETURNS int LANGUAGE plpgsql AS $$
DECLARE v_n int;
BEGIN
  DELETE FROM reddit_news WHERE pulled_at < now() - interval '48 hours';
  GET DIAGNOSTICS v_n = ROW_COUNT;
  DELETE FROM reddit_news_pending
  WHERE resolved_at IS NOT NULL AND resolved_at < now() - interval '6 hours';
  RETURN v_n;
END; $$;

-- ----------------------------------------------------------------------------
-- (7) Ticker view — newest-first, deduped by external URL (else title) on a
--     FIRST-POST-SHOWS basis: when the same story appears more than once (a
--     cross-post, or the same article link posted to several subs), the EARLIEST
--     post wins, so the row is attributed to the sub that broke it and its
--     position in the ticker is stable (a later repost doesn't bump it to top).
--     `subreddit` is exposed so the UI can show which sub the story came from.
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
  WHERE rn.pulled_at > now() - interval '48 hours'
),
deduped AS (
  -- ASC → keep the FIRST (earliest) post carrying this URL/title.
  SELECT DISTINCT ON (dedupe_key)
    reddit_post_id, subreddit, league, title, permalink, link_url,
    link_flair_text, created_utc
  FROM win
  ORDER BY dedupe_key, created_utc ASC NULLS LAST
)
SELECT * FROM deduped
ORDER BY created_utc DESC NULLS LAST;

COMMENT ON VIEW v_reddit_news_ticker IS
  'Newest-first Reddit news ticker, last 48h, deduped by external link (falling '
  'back to normalized title) on a first-post-shows basis so a story cross-posted '
  'to multiple subs shows once, attributed to the sub that posted it first. '
  'Title-only. subreddit exposed for source attribution. Source: news-flaired '
  'posts via search.rss?q=flair:"News".';

-- ----------------------------------------------------------------------------
-- (8) Crons (applied by A1 on merge). New names — no collision with the
--     unscheduled reddit_queue_30min / reddit_process_30min / sweep.
--     Queue: ~30s stagger, ONE sub/tick (rate-limit-safe; ~13 subs → each sub
--            polled ~every 5-6 min). One request per invocation is deliberate:
--            a plpgsql fn is a single txn, so pg_net requests enqueued in a loop
--            all COMMIT together and the worker bursts them (→ old.reddit 429).
--            Firing exactly one per tick puts each request in its own txn, so the
--            worker sends it alone. In-loop pg_sleep does NOT stagger sends.
--     Process: every 1 min (pg_net responses land within seconds).
--     Sweep: every 30 min (48h retention + resolved-pending cleanup).
--
--     ⚠ pg_cron 1.5+ (Supabase 1.6) required for the '30 seconds' sub-minute
--       cadence — the only in-repo use of seconds-granularity cron. If the target
--       rejects it (older pg_cron), fall back to '* * * * *' (1 sub/min → each
--       sub ~every 13 min) and/or trim the enabled set; the queue logic is
--       cadence-agnostic (it fires the oldest due sub whenever called).
-- ----------------------------------------------------------------------------
SELECT cron.unschedule('reddit_news_queue_30min')   WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'reddit_news_queue_30min');
SELECT cron.unschedule('reddit_news_process_30min') WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'reddit_news_process_30min');
SELECT cron.unschedule('reddit_news_sweep_hourly')  WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'reddit_news_sweep_hourly');

SELECT cron.schedule(
  'reddit_news_queue_30s',
  '30 seconds',
  $$ SELECT reddit_news_queue(1); $$
);

SELECT cron.schedule(
  'reddit_news_process_1min',
  '* * * * *',
  $$ SELECT reddit_news_process(); $$
);

SELECT cron.schedule(
  'reddit_news_sweep_30min',
  '*/30 * * * *',
  $$ SELECT reddit_news_sweep(); $$
);
