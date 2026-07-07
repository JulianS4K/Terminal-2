-- ============================================================================
-- Migration 20260707130000 — X-source category facet for the NEWS WIRE
--
-- Lane:     A1 (data plane) — read surface for the D0 terminal news wire
-- Touches:  get_x_news_categories() (NEW fn, W), important_x_accounts (R)
-- Pre-reqs: important_x_accounts (roster; RLS admin_only) + the X source in
--           get_terminal_news_ticker (x_posts CTE, team = '@<author_handle>')
--
-- WHAT (operator-directed 2026-07-07): the news wire's ESPN source reveals a
-- secondary LEAGUE filter; the X (Twitter) source should reveal a secondary
-- CATEGORY filter the same way. The category dimension lives on the tracked-
-- account roster `important_x_accounts.category` (sports / entertainment_concerts
-- / entertainment_broadway), but that table is RLS admin_only (USING(false) for
-- anon/authenticated) so the terminal client can't read it. This adds the one
-- SECURITY DEFINER read path it needs: a normalized handle -> category map the
-- FE joins client-side to each X post (whose `team` field is '@<handle>').
--
-- Normalization: handle is stripped of a leading '@' and lower-cased so it
-- matches x_news.author_handle (bare, lower-case) 1:1 — verified 460/460 on the
-- live 48h window. Where category is NULL (86 roster rows) it is derived from
-- account_type (broadway_* -> broadway, concert_* -> concerts, else sports) so
-- every account buckets into exactly one category.
--
-- Read-only by construction (pure SELECT over an RLS-locked roster). Mirrors the
-- grant surface of get_terminal_news_ticker (anon, authenticated,
-- coworker_readonly). Non-sensitive: exposes only public handles + coarse labels.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.get_x_news_categories()
RETURNS TABLE(handle text, category text, sport text, league text)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT DISTINCT ON (s.handle)
    s.handle, s.category, s.sport, s.league
  FROM (
    SELECT
      lower(regexp_replace(a.handle, '^@', '')) AS handle,
      coalesce(
        a.category,
        CASE
          WHEN a.account_type LIKE 'broadway%' THEN 'entertainment_broadway'
          WHEN a.account_type LIKE 'concert%'  THEN 'entertainment_concerts'
          ELSE 'sports'
        END
      )                                          AS category,
      a.sport                                    AS sport,
      a.league                                   AS league
    FROM public.important_x_accounts a
    WHERE a.handle IS NOT NULL
      AND btrim(a.handle) <> ''
  ) s
  -- On a normalized-handle collision keep the row that carries an explicit
  -- category (non-derived) first, then a non-null sport.
  ORDER BY s.handle, (s.category IS NULL), (s.sport IS NULL);
$function$;

REVOKE ALL ON FUNCTION public.get_x_news_categories() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_x_news_categories()
  TO anon, authenticated, coworker_readonly;

COMMENT ON FUNCTION public.get_x_news_categories() IS
  'D0 terminal NEWS WIRE — X-source CATEGORY facet. Returns the tracked X-account '
  'roster as a normalized (handle -> category/sport/league) map so the client can '
  'facet X posts by category the way ESPN posts facet by league. handle is '
  'lower-cased + de-@''d to match x_news.author_handle; category coalesces '
  'important_x_accounts.category with an account_type-derived fallback '
  '(sports / entertainment_concerts / entertainment_broadway). SECURITY DEFINER '
  'read over the RLS admin_only roster; non-sensitive (public handles + labels).';
