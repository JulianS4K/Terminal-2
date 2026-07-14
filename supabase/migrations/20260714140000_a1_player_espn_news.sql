-- ============================================================================
-- Migration 20260714140000 — Player ESPN-news feed for the player page
--
-- Lane:     A1 data plane (read RPC over the existing espn_news wire table)
-- Touches:  get_player_espn_news (W: new player-page RPC), espn_news (R)
-- Pre-reqs: 20260702220000 (espn_news + the 5-min league-level news cron),
--           20260704080000 (player page / get_broker_player_page)
--
-- WHY: "plug in LeBron ESPN news." ESPN news is already collected league-level
--   into espn_news (headline/description/image/url, every 5 min). Rather than a
--   per-athlete ingest, the player's ESPN feed is a NAME FILTER over that table —
--   same zero-new-ingest pattern as get_player_social (mig 20260714120000). ESPN
--   league news routinely features star players by name (verified live: LeBron
--   has fresh rows — "LeBron to the Warriors buzz", "Rich Paul on LeBron's next
--   team", etc.). Editorial headlines with a summary + thumbnail, so it gets its
--   own panel rather than folding into the X/Reddit BUZZ panel.
--
-- Email-gated (@s4kent.com) SECDEF, mirroring the player-page RPC posture.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.get_player_espn_news(
  p_name   text,
  p_league text DEFAULT NULL,
  p_limit  int  DEFAULT 20)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $func$
DECLARE
  v_email text;
  v_q     text := nullif(btrim(coalesce(p_name,'')), '');
  v_lim   int  := greatest(1, least(coalesce(p_limit, 20), 50));
  -- Distinctive first name (>=5 alpha chars, followed by a space) — catches the
  -- many ESPN headlines that use only the first name ("...for LeBron") which a
  -- full-name filter misses. The length+word-boundary guard keeps it from
  -- matching a different player who merely shares a common surname.
  v_first text;
  v_rows  jsonb;
BEGIN
  v_email := coalesce(auth.jwt()->>'email', '');
  IF v_email NOT LIKE '%@s4kent.com' THEN
    RAISE EXCEPTION 'forbidden: % is not an @s4kent.com email', v_email USING ERRCODE = '42501';
  END IF;
  IF v_q IS NULL THEN
    RETURN jsonb_build_object('items', '[]'::jsonb);
  END IF;
  v_first := (regexp_match(v_q, '^([A-Za-z]{5,})\s'))[1];

  SELECT coalesce(jsonb_agg(to_jsonb(n) ORDER BY n.published_at DESC NULLS LAST), '[]'::jsonb)
  INTO v_rows FROM (
    SELECT DISTINCT ON (e.headline)
           e.headline, e.description AS summary, e.url, e.image_url,
           e.espn_league AS league, e.type, e.published_at
    FROM espn_news e
    WHERE (
            e.headline ILIKE '%'||v_q||'%' OR e.description ILIKE '%'||v_q||'%'
            OR (v_first IS NOT NULL
                AND (e.headline ~* ('\m'||v_first||'\M') OR e.description ~* ('\m'||v_first||'\M')))
          )
      AND (p_league IS NULL OR e.espn_league = p_league)
      AND e.published_at > now() - interval '30 days'
    ORDER BY e.headline, e.published_at DESC
  ) n;

  -- DISTINCT ON dedupes re-published headlines; re-sort the aggregate by recency.
  SELECT coalesce(jsonb_agg(x ORDER BY (x->>'published_at') DESC NULLS LAST), '[]'::jsonb)
  INTO v_rows
  FROM (SELECT x FROM jsonb_array_elements(v_rows) x LIMIT v_lim) s;

  RETURN jsonb_build_object(
    'generated_at', to_char(now() AT TIME ZONE 'UTC','YYYY-MM-DD"T"HH24:MI:SS"Z"'),
    'items', coalesce(v_rows, '[]'::jsonb));
END $func$;

REVOKE ALL ON FUNCTION public.get_player_espn_news(text, text, int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_player_espn_news(text, text, int) TO authenticated, service_role;
COMMENT ON FUNCTION public.get_player_espn_news(text, text, int) IS
  'Player ESPN-news feed for the player page: espn_news rows whose headline/'
  'description mention the player (last 30d), newest first, headline-deduped. '
  'Name filter over the existing espn_news wire (no per-athlete ingest). '
  'Email-gated (@s4kent.com). Mig 20260714140000.';
