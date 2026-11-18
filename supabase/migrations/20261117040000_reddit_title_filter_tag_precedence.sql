-- Migration 20261117040000 · level:data-collection · lane:A1 (operator-routed, "fix the reddit pull") · writes:reddit_title_is_news()(new signature),reddit_news_process() · reads:reddit_news_flairs,broadway_show_ref,net._http_response,news_keywords · pre:20261117030000
--
-- Reddit news title filter: a non-news tag always wins. First cycles of 20261117030000 on prod kept
-- "[Highlight] Compilation of 7 … penalties" (the news_keywords hit on "penalties" was OR-ed in
-- after the tag test) and "[Mic'd Up] …" video posts. Now:
--   * reddit_title_is_news(title, keyword_hit) — the keyword hit is decided inside the function,
--     after the tag test: an excluded tag ([Highlight], threads, spoilers, OC, Mic'd Up, …) is never
--     news, even on a keyword hit; a short [Reporter] tag is news; otherwise news wording or the
--     keyword hit.
--   * reddit_news_process passes the keyword hit in instead of OR-ing it outside.
-- The one-argument reddit_title_is_news(text) is replaced (dropped). Recording + function change only.

BEGIN;
SET LOCAL lock_timeout = '10s';

DROP FUNCTION IF EXISTS public.reddit_title_is_news(text);

CREATE OR REPLACE FUNCTION public.reddit_title_is_news(p_title text, p_keyword_hit boolean DEFAULT false)
RETURNS boolean LANGUAGE sql IMMUTABLE AS $$
  WITH t AS (
    SELECT replace(replace(replace(replace(replace(coalesce(p_title, ''),
             '&amp;', '&'), '&#39;', ''''), '&quot;', '"'), '&lt;', '<'), '&gt;', '>') AS s),
  tag AS (
    SELECT t.s, btrim((regexp_match(t.s, '^\s*\[([^\]]{1,40})\]'))[1]) AS tg FROM t)
  SELECT CASE
    -- a tag that marks a non-news post type: never news, whatever else matches
    WHEN tg ~* '(highlight|thread|spoiler|^oc$|meme|shitpost|^meta$|^daily|^weekly|request|^poll$|^video$|^image$|^pic$|^photo$|^gif$|humor|^misc$|question|^rant$|art$|^help$|^ama$|^live$|^hype$|fantasy|off[ -]?topic|^ot$|throwback|appreciation|^serious$|discussion|game ?day|^stats?$|mic''?d up|^film|breakdown|^recap)'
      THEN false
    -- a short [Reporter] / [Outlet] tag: news
    WHEN tg IS NOT NULL
         AND tg !~ '\d{4}|\d{1,2}/\d{1,2}'
         AND array_length(regexp_split_to_array(tg, '\s+'), 1) <= 4
      THEN true
    ELSE coalesce(p_keyword_hit, false)
      OR s ~* '(\msources?:|\msource says|\mper sources|\mreportedly\M|\mreport:|\mbreaking\M|\magree[sd]? to\M|\msigns?\M|\msigned\M|\msigning\M|\mre-signs?\M|\mtraded?\M|\mtrades\M|\macquir(e|es|ed)\M|\mwaive[sd]?\M|\mwaivers\M|\mreleased\M|\mreleases\M|\msuspend(ed|s)?\M|\msuspension\M|\mplaced on\M|\mactivated\M|\mruled out\M|\mout for the season\M|\minjur(y|ed|ies)\M|\mtorn\M|\msurgery\M|\mextension\M|\mfire[sd]?\M|\mhire[sd]?\M|\mpart(s)? ways\M|\mretir(e|es|ed|ement)\M|\mdie[sd]\M|\mpassed away\M|\marrested\M|\mcleared\M)'
  END
  FROM tag
$$;

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
                    ELSE public.reddit_title_is_news(
                           p.title,
                           coalesce((public.match_news_keywords(p.title)->>'total_weight')::numeric, 0) > 0)
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

REVOKE ALL ON FUNCTION public.reddit_title_is_news(text, boolean) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.reddit_title_is_news(text, boolean) TO service_role;

-- the posts the first cycles kept under a non-news tag
-- (a leading tag that the filter now rejects even with a keyword hit; subs with their own
--  search terms and Broadway rows are left alone)
DELETE FROM public.reddit_news
 WHERE link_flair_text = 'News'
   AND title ~ '^\s*\['
   AND NOT public.reddit_title_is_news(title, true);

COMMIT;

-- VERIFY: SELECT count(*) FROM reddit_news WHERE title ~* '^\s*\[(highlight|mic''?d up)';   -- 0
