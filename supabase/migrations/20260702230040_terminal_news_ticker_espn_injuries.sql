-- ============================================================================
-- Migration 20260702230040 — NEWS WIRE: add ESPN injury updates as a source
--
-- Lane:     D0 (author) → A1 (apply)   [D0 has no prod-DB apply authority]
-- Touches:  get_terminal_news_ticker (W, CREATE OR REPLACE)
--           espn_news (R), espn_teams_canonical (R), v_reddit_news_ticker (R),
--           espn_injuries_snapshots (R)  ← NEW read surface
-- Pre-reqs: 20260702210000 (get_terminal_news_ticker v2 — Reddit news pipeline)
--           20260507000013 (espn_injuries_snapshots)
--           20260507000017 (change-only ESPN ingest → captured_at is the moment
--                           an injury's content last CHANGED, not just re-observed)
--
-- WHY: operator directive 2026-07-02 — surface ESPN injury updates in the D0
--   NEWS WIRE. espn_injuries_snapshots is fed live by espn-collect's `roster`
--   scope (every 10 min, league-wide /injuries pull) via the change-only
--   upsert_espn_injury RPC. Like espn_news, the table's RLS is deny-all for
--   authenticated/anon, so the SECURITY DEFINER ticker RPC is the terminal's
--   only read path.
--
-- INGEST REALITY (verified live 2026-07-02): the change-only upsert only dedups
--   when it can match the prior row by (espn_team_id, athlete_id). For leagues
--   whose ESPN athlete.id is unstable run-to-run, athlete_id churns, the match
--   misses, and the SAME injury is re-inserted as a fresh (is_baseline=true) row
--   every 10-min roster run — ~353 raw rows for ~200 real injuries in 48h, all
--   stamped with a ~now captured_at. So the `injuries` CTE must (a) de-duplicate,
--   or one injury shows dozens of times, and (b) NOT order by captured_at (last
--   insert), or every injury pins to the top of the wire and buries ESPN/Reddit.
--
-- CHANGES vs v2:
--   * NEW `injuries` CTE unions injury updates from espn_injuries_snapshots,
--     GROUPED BY content (team + league + athlete + status + injury_type) with
--     min(captured_at) as the FIRST-SEEN "news" time:
--       - source       = 'Injuries'  (distinct toggle in the FE; also under "All")
--       - league       = espn_league (in the group key — team_id is reused across
--                        leagues, RESOURCES_BIBLE ESPN RULE 1)
--       - team         = display name via espn_teams_canonical (same join as ESPN)
--       - headline     = "<athlete> (<pos>) — <status> · <type>" (type clause
--                        dropped when it merely restates the status)
--       - summary      = short_comment (→ long_comment), + est. return date
--       - url          = ESPN league injuries page where one exists, else NULL
--                        (FE safeHref collapses NULL/unknown to a dead '#')
--       - item_type    = 'injury'    (FE renders an INJ tag)
--       - published_at = min(captured_at) → grouping collapses the re-insert
--                        churn AND a genuine status change (a new content group)
--                        resurfaces at the top, while re-observations of an old
--                        state keep their original first-seen time (do not float).
--     Scan is bounded to (window + 24h) so the aggregate reads only recent rows
--     via idx_espn_inj_team_time (NOT a full scan of the ~627MB table — the
--     RESOURCES_BIBLE landmine; verified ~18ms via bitmap index scan). The +24h
--     buffer lets HAVING drop an injury that already existed just before the
--     window (its churn rows in the buffer pull min(captured_at) below the window
--     start), so a long-standing injury never masquerades as new.
--   * No signature/shape change — RETURNS TABLE columns are identical, so the FE
--     contract is unchanged (it just gains rows with source='Injuries').
--
-- Read-only by construction: pure SELECT over RLS-locked read surfaces. REVOKE
--   PUBLIC + GRANT to the same read roles as v2.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.get_terminal_news_ticker(
  p_window_hours integer DEFAULT 48,
  p_sources      text[]  DEFAULT NULL,
  p_leagues      text[]  DEFAULT NULL,
  p_search       text    DEFAULT NULL,
  p_limit        integer DEFAULT 100
)
RETURNS TABLE(
  source       text,
  league       text,
  team         text,
  headline     text,
  summary      text,
  url          text,
  image_url    text,
  item_type    text,
  published_at timestamptz
)
LANGUAGE sql
STABLE
SECURITY DEFINER
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
  injuries AS (
    -- One row per DISTINCT injury state (team + athlete + status + type), stamped
    -- with its FIRST-SEEN time (min captured_at). Why grouped, not one-row-per-
    -- snapshot: espn_injuries_snapshots is written change-only, but for athletes
    -- whose ESPN athlete.id churns run-to-run the roster cron (every 10 min)
    -- re-inserts the SAME injury as a fresh row. Ungrouped, one injury would
    -- appear dozens of times, and captured_at (last insert) would pin every
    -- injury at ~now — burying ESPN/Reddit. Grouping by content collapses the
    -- churn; min(captured_at) is the moment the injury/status was first observed
    -- = its real "news" time, so a genuine status change (new content group)
    -- resurfaces at the top while re-observations of an old state do not.
    --
    -- Scan is bounded: the WHERE clamps to (window + 24h) so the aggregate reads
    -- only recent rows via idx_espn_inj_team_time (NOT a full scan of the ~627MB
    -- table — the §RESOURCES_BIBLE landmine). The +24h buffer lets HAVING detect
    -- an injury that already existed just before the window (its churn rows in the
    -- buffer pull min(captured_at) below the window start → excluded), so a
    -- long-standing injury never masquerades as new. team_id is reused across
    -- leagues → espn_league is part of the group key AND the team join.
    SELECT
      'Injuries'::text                              AS source,
      max(i.espn_league)                            AS league,
      max(coalesce(t.display_name, t.abbreviation)) AS team,
      -- "<athlete> (<pos>) — <status> · <type>"; drop the type clause when it just
      -- restates the status (ESPN often sets both to the same value).
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
      -- ESPN publishes a league-level injuries page for the major US leagues;
      -- soccer (MLS / World Cup) has none → NULL (FE renders a dead '#').
      CASE lower(max(i.espn_league))
        WHEN 'nfl'  THEN 'https://www.espn.com/nfl/injuries'
        WHEN 'nba'  THEN 'https://www.espn.com/nba/injuries'
        WHEN 'wnba' THEN 'https://www.espn.com/wnba/injuries'
        WHEN 'mlb'  THEN 'https://www.espn.com/mlb/injuries'
        WHEN 'nhl'  THEN 'https://www.espn.com/nhl/injuries'
        ELSE NULL
      END                                           AS url,
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
      -- Cross-source dedup: drop a Reddit row whose EXTERNAL article link points
      -- at the same story ESPN already carries (ESPN is the authoritative
      -- source, so it wins). Match on a normalized URL (strip scheme / www /
      -- query / fragment / trailing slash). Reddit rows with no external link
      -- (link_url NULL → url is the reddit permalink) can never collide, so they
      -- are kept. Scoped to the same window as the espn CTE.
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
  unioned AS (
    SELECT * FROM espn
    UNION ALL
    SELECT * FROM injuries
    UNION ALL
    SELECT * FROM reddit
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

REVOKE ALL ON FUNCTION public.get_terminal_news_ticker(integer, text[], text[], text, integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_terminal_news_ticker(integer, text[], text[], text, integer)
  TO anon, authenticated, coworker_readonly;

COMMENT ON FUNCTION public.get_terminal_news_ticker(integer, text[], text[], text, integer) IS
  'D0 terminal NEWS WIRE feed. Unified, filterable, newest-first headlines from '
  'espn_news (live) + espn_injuries_snapshots (source=''Injuries'', change-only '
  'injury updates, item_type=''injury'') + v_reddit_news_ticker (flair:"News" '
  'pipeline, 48h, deduped first-post-shows; team = ''r/<sub>''). SECURITY DEFINER '
  'read surface for the authenticated terminal client. Params: window hours, '
  'sources[] (ESPN|Injuries|Reddit), leagues[], search, limit.';
