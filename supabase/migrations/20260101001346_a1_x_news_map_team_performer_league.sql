-- ============================================================================
-- Migration 20260707200000 — map X (Twitter) news to team/performer/league
--
-- Lane:     A1 (data plane) — read surface for the D0 terminal news wire
-- Touches:  v_x_news_ticker (REPLACE, W), important_x_accounts (R),
--           performer_metadata (R)
-- Pre-reqs: 20260707190000 (x_news_roster_import — the LATEST prior definition of
--           v_x_news_ticker; this MUST run after it, else that plain view def
--           clobbers this enrichment), 20260707130000 (X category RPC),
--           get_terminal_news_ticker.x_posts CTE reads this view's league + url
--
-- WHAT (operator-directed 2026-07-07): make X posts first-class in the news wire
-- the way ESPN / Broadway / Reddit items are — mapped to their team, performer,
-- and league (category is already handled by get_x_news_categories). Achieved by
-- enriching v_x_news_ticker so the columns the RPC already reads (league, url)
-- carry the mapped values — the 200-line get_terminal_news_ticker is untouched.
--
--   * LEAGUE — coalesce(x_news.league, roster.league), lower-cased to ESPN's
--     vocab (nfl/mlb/nba/nhl/mls/ufc/…). Before: only ~40/620 live posts had a
--     league; after: 620/620, sharing the SAME league chips as ESPN so an X post
--     about the Yankees buckets under 'mlb' exactly like an ESPN row.
--   * TEAM / PERFORMER — the tracked-account roster carries the team the account
--     covers (team_official + beat_reporter = 199 accts, team_name populated) or,
--     for concert_artist accounts, the artist itself. Resolve that name to the
--     canonical tevo_performer_id (performer_metadata, popularity-ranked) and
--     point the headline url at performer.html?performer=<id> — the same internal
--     deep-link ESPN's mapped rows + Broadway use. Resolution: 196/199 teams,
--     17/40 artists; ~200/620 live posts deep-link, the rest (league officials,
--     insiders with no single team) keep the source tweet url.
--
-- Resolution is done live in the view (not frozen into a column) so newly-added
-- roster accounts map automatically. CREATE OR REPLACE keeps the existing 9
-- columns / names / types / order (only the league + url expressions change), so
-- the dependent get_terminal_news_ticker keeps working with no signature change.
-- ============================================================================

CREATE OR REPLACE VIEW public.v_x_news_ticker AS
WITH win AS (
  SELECT
    xn.tweet_id, xn.source_value, xn.league, xn.author_handle, xn.author_name,
    xn.title, xn.url, xn.created_utc, xn.matched_keywords,
    lower(btrim(regexp_replace(xn.title, '\s+', ' ', 'g'))) AS dedupe_key
  FROM public.x_news xn
  WHERE xn.pulled_at > (now() - '48:00:00'::interval)
),
deduped AS (
  -- first-post-shows: earliest created_utc per normalized title
  SELECT DISTINCT ON (win.dedupe_key)
    win.tweet_id, win.source_value, win.league, win.author_handle, win.author_name,
    win.title, win.url, win.created_utc, win.matched_keywords
  FROM win
  ORDER BY win.dedupe_key, win.created_utc
),
acct AS (
  -- one row per normalized handle: the covered team/performer + roster league.
  -- team_name (team_official/beat_reporter) resolves to the team's performer;
  -- concert_artist falls back to the account name (the artist).
  SELECT DISTINCT ON (s.h) s.h, s.acct_league, s.performer_id
  FROM (
    SELECT
      lower(regexp_replace(a.handle, '^@', '')) AS h,
      lower(NULLIF(a.league, ''))               AS acct_league,
      coalesce(
        (SELECT pm.performer_id FROM public.performer_metadata pm
          WHERE lower(pm.name) = lower(a.team_name)
          ORDER BY pm.popularity_score DESC NULLS LAST, pm.performer_id LIMIT 1),
        CASE WHEN a.account_type = 'concert_artist'
             THEN (SELECT pm.performer_id FROM public.performer_metadata pm
                    WHERE lower(pm.name) = lower(a.name)
                    ORDER BY pm.popularity_score DESC NULLS LAST, pm.performer_id LIMIT 1)
        END
      )                                          AS performer_id
    FROM public.important_x_accounts a
    WHERE a.handle IS NOT NULL AND btrim(a.handle) <> ''
  ) s
  ORDER BY s.h, (s.performer_id IS NULL)
)
SELECT
  d.tweet_id,
  d.source_value,
  lower(coalesce(NULLIF(d.league, ''), ac.acct_league))              AS league,
  d.author_handle,
  d.author_name,
  d.title,
  coalesce('performer.html?performer=' || ac.performer_id::text, d.url) AS url,
  d.created_utc,
  d.matched_keywords
FROM deduped d
LEFT JOIN acct ac ON ac.h = lower(regexp_replace(d.author_handle, '^@', ''))
ORDER BY d.created_utc DESC NULLS LAST;

COMMENT ON VIEW public.v_x_news_ticker IS
  'X (Twitter) news for the D0 NEWS WIRE (48h, deduped first-post-shows). Mapped '
  'to the tracked-account roster (important_x_accounts): league backfilled to '
  'ESPN vocab, and url pointed at performer.html?performer=<id> when the account '
  'resolves to a team/performer (team_name or artist name -> performer_metadata), '
  'else the source tweet. Feeds get_terminal_news_ticker.x_posts; category facet '
  'is served separately by get_x_news_categories().';
