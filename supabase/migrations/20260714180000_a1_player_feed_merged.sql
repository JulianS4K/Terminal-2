-- ============================================================================
-- Migration 20260714180000 — Merged live player feed (one stream, all sources)
--
-- Lane:     A1 data plane (unified read RPC over the existing wire tables)
-- Touches:  get_player_feed (W: new RPC), espn_news + reddit_news + x_news +
--           espn_transactions + player_prediction_markets (R)
-- Pre-reqs: 20260702220000 (espn_news), 20260626120030 (reddit_news),
--           20260706114500 (x_news), 20260704000000 (espn_transactions),
--           20260714120000 (player_prediction_markets)
--
-- WHY: operator wants ONE live, merged feed on the player page instead of the
--   separate ESPN-news / transactions / social panels. This unions every wire
--   source (name-filtered to the athlete) plus a market pulse into a single
--   newest-first stream the frontend polls (~30s) for a live feed. Zero new
--   ingest — a read over data already collected.
--
-- NAME MATCH: full name OR distinctive first name (>=5 chars, word-bounded),
--   league-scoped, so ESPN's first-name headlines are caught without false
--   matches from a shared surname / another league.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.get_player_feed(
  p_athlete_id   text,
  p_name         text,
  p_league       text DEFAULT NULL,
  p_window_hours int  DEFAULT 72,
  p_limit        int  DEFAULT 40)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $func$
DECLARE
  v_email text;
  v_q     text := nullif(btrim(coalesce(p_name,'')), '');
  v_first text;
  v_win   int  := greatest(1, least(coalesce(p_window_hours, 72), 336));
  v_lim   int  := greatest(1, least(coalesce(p_limit, 40), 100));
  v_since timestamptz;
  v_items jsonb;
BEGIN
  v_email := coalesce(auth.jwt()->>'email', '');
  IF v_email NOT LIKE '%@s4kent.com' THEN
    RAISE EXCEPTION 'forbidden: % is not an @s4kent.com email', v_email USING ERRCODE = '42501';
  END IF;
  IF v_q IS NULL THEN
    RETURN jsonb_build_object('items', '[]'::jsonb);
  END IF;
  v_first := (regexp_match(v_q, '^([A-Za-z]{5,})\s'))[1];
  v_since := now() - (v_win || ' hours')::interval;

  WITH news AS (
    SELECT 'ESPN'::text AS source, 'news'::text AS item_type,
           e.headline AS title, e.description AS summary, e.url, e.image_url,
           coalesce(e.espn_league,'ESPN') AS handle, e.published_at
    FROM espn_news e
    WHERE e.published_at > v_since
      AND (p_league IS NULL OR e.espn_league = p_league)
      AND ( e.headline ILIKE '%'||v_q||'%' OR e.description ILIKE '%'||v_q||'%'
            OR (v_first IS NOT NULL AND (e.headline ~* ('\m'||v_first||'\M') OR e.description ~* ('\m'||v_first||'\M'))) )
  ),
  reddit AS (
    SELECT 'Reddit'::text, 'reddit'::text, r.title, NULL::text,
           coalesce(nullif(r.link_url,''), r.permalink), NULL::text,
           'r/'||r.subreddit, r.created_utc
    FROM reddit_news r
    WHERE r.pulled_at > v_since
      AND ( r.title ILIKE '%'||v_q||'%'
            OR (v_first IS NOT NULL AND r.title ~* ('\m'||v_first||'\M')) )
  ),
  xposts AS (
    SELECT 'X'::text, 'x'::text,
           CASE WHEN length(x.title) > 260 THEN left(x.title,257)||'…' ELSE x.title END,
           NULL::text, x.url, NULL::text, '@'||x.author_handle, x.created_utc
    FROM x_news x
    WHERE x.pulled_at > v_since
      AND ( x.title ILIKE '%'||v_q||'%'
            OR (v_first IS NOT NULL AND x.title ~* ('\m'||v_first||'\M')) )
  ),
  txn AS (
    SELECT 'Transaction'::text, 'transaction'::text,
           coalesce(t.team_display_name||': ', '')||t.description, NULL::text,
           NULL::text, NULL::text, coalesce(t.team_display_name, t.team_abbr, 'ESPN'), t.txn_date
    FROM espn_transactions t
    WHERE t.txn_date > v_since
      AND (p_league IS NULL OR t.espn_league = p_league)
      AND coalesce(t.description,'') <> ''
      AND ( t.description ILIKE '%'||v_q||'%'
            OR (v_first IS NOT NULL AND t.description ~* ('\m'||v_first||'\M')) )
  ),
  market AS (
    -- market pulse: current Kalshi next-team leaders (top 3), timestamped by the
    -- last refresh so genuine odds moves surface in the stream without flooding.
    SELECT 'Market'::text, 'market'::text,
           'Transfer market · '||m.dest_team_name||' '||round(m.yes_price*100)::int||'%',
           NULL::text, m.url, NULL::text, coalesce(m.source,'Kalshi'), m.updated_at
    FROM (
      SELECT dest_team_name, yes_price, url, source, updated_at
      FROM player_prediction_markets
      WHERE espn_athlete_id = p_athlete_id AND espn_league = p_league
        AND coalesce(status,'') NOT IN ('closed','settled','inactive') AND yes_price IS NOT NULL
      ORDER BY yes_price DESC NULLS LAST LIMIT 3
    ) m
  ),
  unioned AS (
    SELECT * FROM news
    UNION ALL SELECT * FROM reddit
    UNION ALL SELECT * FROM xposts
    UNION ALL SELECT * FROM txn
    UNION ALL SELECT * FROM market
  )
  SELECT coalesce(jsonb_agg(to_jsonb(u) ORDER BY u.published_at DESC NULLS LAST), '[]'::jsonb)
  INTO v_items
  FROM (SELECT * FROM unioned ORDER BY published_at DESC NULLS LAST LIMIT v_lim) u;

  RETURN jsonb_build_object(
    'generated_at', to_char(now() AT TIME ZONE 'UTC','YYYY-MM-DD"T"HH24:MI:SS"Z"'),
    'items', coalesce(v_items, '[]'::jsonb));
END $func$;

REVOKE ALL ON FUNCTION public.get_player_feed(text, text, text, int, int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_player_feed(text, text, text, int, int) TO authenticated, service_role;
COMMENT ON FUNCTION public.get_player_feed(text, text, text, int, int) IS
  'Merged live player feed: ESPN news + Reddit + X + transactions + market pulse '
  '(name-filtered to the athlete), newest-first, one unified stream for the player '
  'page (polled ~30s). Zero new ingest. Email-gated. Mig 20260714180000.';
