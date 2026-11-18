-- Migration 20261117030040 · level:data-collection · lane:A1 (operator-routed, "fix the reddit pull") · writes:reddit_title_is_news()(new),reddit_title_matches_terms()(new),reddit_news_queue(),reddit_news_process(),broadway_social_poll() · reads:reddit_news_flairs,broadway_show_ref,net._http_response,news_keywords · pre:20261006200000
--
-- Reddit news wire: read each subreddit's /new.rss and filter titles here, because reddit now
-- refuses search (operator 2026-11-17: "fix the reddit pull").
--
-- WHY. reddit_news has been empty since ~2026-11-12. Both pullers ask reddit's search:
-- reddit_news_queue (r/<sub>/search.rss?q=flair:"News" or the sub's search terms) and
-- broadway_social_poll (site-wide search.rss?q="<show>" Broadway). Every search.rss request now
-- answers 403 with an empty Atom feed (prod net._http_response: 117 × 403 in 2 h; probed again
-- 2026-11-17 from another cloud host: search.rss 403, new.json 403, r/<sub>/new.rss 200 with the
-- full feed). Reddit's plain listing feed is the one unauthenticated route still open.
--
-- WHAT CHANGES
--   * reddit_news_queue fires r/<sub>/new.rss?limit=50 (same cadence: one sub a minute, each sub
--     at most every 4 min). The listing feed has no flair, so reddit_news_process filters titles:
--       - a sub with search_query keeps titles matching any of its terms (the same terms the old
--         search used: `a OR b OR "c d"`, case-insensitive, whole words);
--       - every other sub (flair "News") keeps titles that read as news:
--         reddit_title_is_news() — a leading [Reporter]/[Outlet] tag (the sports-sub convention
--         for news posts; tags such as [Highlight], [Post Game Thread], [OC], spoilers, dates or
--         long series labels are not news), or news wording (signs/traded/waived/ruled out/
--         fired/part ways/…), or a hit on the existing news_keywords list (match_news_keywords).
--       Checked on live feeds 2026-11-17 (r/nfl, r/hockey, r/formula1, r/baseball, r/CFB): keeps
--       the [Garafolo]/[Dreger]/[MLBTR]-style reports, signings, injuries and firings; drops game
--       threads, highlights and discussion.
--   * broadway_social_poll fetches one shared feed, r/Broadway+musicals+theatre/new.rss, at most
--     every 15 min (was: one site-wide search per show, 8 shows), and reddit_news_process keeps the
--     posts whose title names a watched show, stored as before (subreddit 'bway:<slug>', league
--     'Broadway', flair text = the show title). Reddit load drops to ~1.1 requests a minute.
--   * Nothing else: same tables, same ticker view, same 48 h sweep. Read-only GETs (RULE 2).

BEGIN;
SET LOCAL lock_timeout = '10s';

-- true when a reddit title reads as news (see header)
CREATE OR REPLACE FUNCTION public.reddit_title_is_news(p_title text)
RETURNS boolean LANGUAGE sql IMMUTABLE AS $$
  WITH t AS (
    SELECT replace(replace(replace(replace(replace(coalesce(p_title, ''),
             '&amp;', '&'), '&#39;', ''''), '&quot;', '"'), '&lt;', '<'), '&gt;', '>') AS s),
  tag AS (
    SELECT t.s, btrim((regexp_match(t.s, '^\s*\[([^\]]{1,40})\]'))[1]) AS tg FROM t)
  SELECT CASE
    -- a tag that marks a non-news post type: never news
    WHEN tg ~* '(highlight|thread|spoiler|^oc$|meme|shitpost|^meta$|^daily|^weekly|request|^poll$|^video$|^image$|^pic$|^photo$|^gif$|humor|^misc$|question|^rant$|art$|^help$|^ama$|^live$|^hype$|fantasy|off[ -]?topic|^ot$|throwback|appreciation|^serious$|discussion|game ?day|^stats?$)'
      THEN false
    -- a short [Reporter] / [Outlet] tag: news
    WHEN tg IS NOT NULL
         AND tg !~ '\d{4}|\d{1,2}/\d{1,2}'
         AND array_length(regexp_split_to_array(tg, '\s+'), 1) <= 4
      THEN true
    ELSE s ~* '(\msources?:|\msource says|\mper sources|\mreportedly\M|\mreport:|\mbreaking\M|\magree[sd]? to\M|\msigns?\M|\msigned\M|\msigning\M|\mre-signs?\M|\mtraded?\M|\mtrades\M|\macquir(e|es|ed)\M|\mwaive[sd]?\M|\mwaivers\M|\mreleased\M|\mreleases\M|\msuspend(ed|s)?\M|\msuspension\M|\mplaced on\M|\mactivated\M|\mruled out\M|\mout for the season\M|\minjur(y|ed|ies)\M|\mtorn\M|\msurgery\M|\mextension\M|\mfire[sd]?\M|\mhire[sd]?\M|\mpart(s)? ways\M|\mretir(e|es|ed|ement)\M|\mdie[sd]\M|\mpassed away\M|\marrested\M|\mcleared\M)'
  END
  FROM tag
$$;

-- true when a title matches any term of a reddit-style query: a OR b OR "c d"
CREATE OR REPLACE FUNCTION public.reddit_title_matches_terms(p_title text, p_query text)
RETURNS boolean LANGUAGE sql IMMUTABLE AS $$
  SELECT EXISTS (
    SELECT 1
      FROM regexp_matches(coalesce(p_query, ''), '"([^"]+)"|(\S+)', 'g') m,
           LATERAL (SELECT btrim(coalesce(m[1], m[2])) AS term) x
     WHERE x.term <> '' AND upper(x.term) <> 'OR'
       AND replace(coalesce(p_title, ''), '&#39;', '''')
           ~* ('\m' || regexp_replace(x.term, '([.^$|()\[\]{}*+?\\-])', '\\\1', 'g') || '\M'))
$$;

CREATE OR REPLACE FUNCTION public.reddit_news_queue(p_limit integer DEFAULT 1)
RETURNS integer LANGUAGE plpgsql AS $function$
DECLARE
  r RECORD; v_req_id bigint; v_count int := 0;
BEGIN
  FOR r IN
    SELECT f.subreddit, f.league, f.flair_query, f.search_query
      FROM reddit_news_flairs f
     WHERE f.enabled
       AND (f.last_polled_at IS NULL OR f.last_polled_at < now() - interval '4 minutes')
     ORDER BY f.last_polled_at ASC NULLS FIRST, f.subreddit
     LIMIT p_limit
  LOOP
    -- the listing feed (search.rss answers 403 since ~2026-11-12); titles are filtered in
    -- reddit_news_process by the sub's search_query, else by reddit_title_is_news()
    SELECT net.http_get(
      url := 'https://www.reddit.com/r/' || r.subreddit || '/new.rss?limit=50',
      headers := jsonb_build_object(
        'User-Agent', 'Terminal2-S4K-RSS/1.0',
        'Accept', 'application/rss+xml, application/xml'),
      timeout_milliseconds := 12000
    ) INTO v_req_id;

    INSERT INTO reddit_news_pending(subreddit, league, flair_query, request_id, fired_at)
    VALUES (r.subreddit, r.league, coalesce(r.search_query, r.flair_query), v_req_id, now());

    UPDATE reddit_news_flairs SET last_polled_at = now() WHERE subreddit = r.subreddit;
    v_count := v_count + 1;
  END LOOP;
  RETURN v_count;
END; $function$;

-- Broadway: one shared listing feed for every watched show, at most every 15 min
CREATE OR REPLACE FUNCTION public.broadway_social_poll(p_limit integer DEFAULT 1)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE
  v_req bigint;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM broadway_show_ref
                  WHERE watch AND coalesce(title, '') <> ''
                    AND (social_last_polled_at IS NULL OR social_last_polled_at < now() - interval '15 minutes')) THEN
    RETURN 0;
  END IF;
  SELECT net.http_get(
    url := 'https://www.reddit.com/r/Broadway+musicals+theatre/new.rss?limit=100',
    headers := jsonb_build_object('User-Agent', 'Terminal2-S4K-RSS/1.0',
                                  'Accept', 'application/rss+xml, application/xml'),
    timeout_milliseconds := 12000
  ) INTO v_req;
  INSERT INTO reddit_news_pending(subreddit, league, flair_query, request_id, fired_at)
  VALUES ('bway:*', 'Broadway', 'watched shows (r/Broadway+musicals+theatre)', v_req, now());
  UPDATE broadway_show_ref SET social_last_polled_at = now()
   WHERE watch AND coalesce(title, '') <> '';
  RETURN 1;
END $function$;

CREATE OR REPLACE FUNCTION public.reddit_news_process()
RETURNS TABLE(processed integer, posts_persisted integer) LANGUAGE plpgsql AS $function$
DECLARE
  r RECORD; v_xml text; v_count int; v_terms text;
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
      v_terms := CASE WHEN r.subreddit NOT LIKE 'bway:%'
                      THEN (SELECT nullif(btrim(f.search_query), '') FROM reddit_news_flairs f
                             WHERE f.subreddit = r.subreddit) END;
      WITH entries AS (
        SELECT (regexp_matches(v_xml, '<entry>(.*?)</entry>', 'g'))[1] AS entry
      ),
      parsed AS (
        SELECT
          (regexp_match(e.entry, '(t3_[a-z0-9]+)'))[1]                     AS reddit_post_id,
          (regexp_match(e.entry, '<title>([^<]*)</title>'))[1]             AS title,
          (regexp_match(e.entry, '<link\s+href="([^"]+)"'))[1]             AS permalink,
          (regexp_match(e.entry, '<updated>([^<]+)</updated>'))[1]         AS updated_str,
          (regexp_match(e.entry,
            'href="(https?://(?!(?:[^"/]*\.)?(?:reddit\.com|redd\.it))[^"]+)"'))[1] AS link_url
        FROM entries e
      ),
      kept AS (
        -- Broadway feed: posts naming a watched show
        SELECT p.*, 'bway:' || left(s.show_slug, 18) AS sub, 'Broadway'::text AS lg, s.title AS flair
          FROM parsed p
          JOIN broadway_show_ref s
            ON s.watch AND coalesce(s.title, '') <> ''
           AND lower(regexp_replace(replace(p.title, '&#39;', ''''), '[^[:alnum:]]+', ' ', 'g'))
               LIKE '%' || btrim(lower(regexp_replace(s.title, '[^[:alnum:]]+', ' ', 'g'))) || '%'
         WHERE r.subreddit LIKE 'bway:%'
        UNION ALL
        -- subreddit feeds: the sub's own search terms, else titles that read as news
        SELECT p.*, r.subreddit, r.league, r.flair_query
          FROM parsed p
         WHERE r.subreddit NOT LIKE 'bway:%'
           AND CASE WHEN v_terms IS NOT NULL THEN public.reddit_title_matches_terms(p.title, v_terms)
                    ELSE public.reddit_title_is_news(p.title)
                         OR coalesce((public.match_news_keywords(p.title)->>'total_weight')::numeric, 0) > 0
               END
      ),
      ins AS (
        INSERT INTO reddit_news (
          reddit_post_id, subreddit, league, title, permalink, link_url,
          link_flair_text, created_utc
        )
        SELECT k.reddit_post_id, k.sub, k.lg, k.title, k.permalink, k.link_url, k.flair,
               NULLIF(k.updated_str, '')::timestamptz
          FROM (SELECT DISTINCT ON (reddit_post_id) *
                  FROM kept
                 WHERE reddit_post_id IS NOT NULL AND COALESCE(title, '') <> ''
                 ORDER BY reddit_post_id, updated_str DESC NULLS LAST) k
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
END; $function$;

REVOKE ALL ON FUNCTION public.reddit_title_is_news(text), public.reddit_title_matches_terms(text, text)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.reddit_title_is_news(text), public.reddit_title_matches_terms(text, text)
  TO service_role;
REVOKE ALL ON FUNCTION public.broadway_social_poll(integer) FROM PUBLIC, anon, authenticated;

COMMIT;

-- VERIFY (after ~10 min):
--   SELECT h.status_code, count(*) FROM reddit_news_pending p JOIN net._http_response h ON h.id = p.request_id
--    WHERE p.fired_at > now() - interval '15 minutes' GROUP BY 1;            -- 200s, not 403
--   SELECT league, count(*) FROM reddit_news GROUP BY 1;                     -- rows arriving
--   SELECT count(*) FROM v_reddit_news_ticker;
-- ROLLBACK: re-apply 20261006200000's reddit_news_queue / broadway_social_poll and
--   20260626120030's reddit_news_process (search.rss — but those URLs answer 403 now);
--   DROP FUNCTION reddit_title_is_news(text), reddit_title_matches_terms(text, text).
