-- Cowork migration. Captured into git by code (auditor) on 2026-05-07.
-- Originally applied to prod 2026-05-07 21:53 UTC.
--
-- Roll wiki context + marquee-rivalry flag into get_team_context.
-- Single helper now returns standings + playoff + wiki + recent_news + injuries + roster
-- + a top-level 'next_game_marquee' flag the chatbot can use to elevate matchups.

DROP FUNCTION IF EXISTS get_team_context(bigint);

CREATE OR REPLACE FUNCTION get_team_context(p_performer_id bigint)
RETURNS jsonb
LANGUAGE plpgsql STABLE AS $fn$
DECLARE
  v_playoff jsonb;
  v_next_opponent_id bigint;
  v_marquee jsonb;
BEGIN
  v_playoff := get_team_playoff_context(p_performer_id);

  IF v_playoff -> 'next_game' ->> 'opponent' IS NOT NULL THEN
    SELECT performer_id INTO v_next_opponent_id
    FROM performer_home_venues
    WHERE lower(performer_name) = lower(v_playoff -> 'next_game' ->> 'opponent')
    LIMIT 1;

    IF v_next_opponent_id IS NOT NULL THEN
      v_marquee := is_rivalry_game(p_performer_id, v_next_opponent_id);
    END IF;
  END IF;

  RETURN jsonb_build_object(
    'performer_id', p_performer_id,
    'team', (
      SELECT jsonb_build_object(
        'espn_team_id', espn_team_id, 'espn_league', espn_league,
        'name', COALESCE(espn_display_name, tevo_name), 'abbr', espn_abbr)
      FROM team_xref WHERE tevo_performer_id = p_performer_id LIMIT 1),
    'standing', (
      SELECT jsonb_build_object(
        'record', record_summary, 'win_pct', win_pct, 'games_back', games_back,
        'streak', streak, 'standing_summary', standing_summary,
        'playoff_seed', playoff_seed, 'conference_rank', conference_rank,
        'division_rank', division_rank, 'as_of', captured_at)
      FROM espn_team_snapshots s
      WHERE s.espn_team_id = (SELECT espn_team_id FROM team_xref WHERE tevo_performer_id = p_performer_id LIMIT 1)
      ORDER BY captured_at DESC LIMIT 1),
    'playoff', v_playoff,
    'next_game_marquee', v_marquee,
    'next_opponent_performer_id', v_next_opponent_id,
    'wiki', get_wiki_context(p_performer_id),
    'recent_news', (
      SELECT jsonb_agg(jsonb_build_object('headline', headline, 'published_at', published_at, 'url', url))
      FROM (SELECT headline, published_at, url FROM espn_news n
            WHERE n.espn_team_id = (SELECT espn_team_id FROM team_xref WHERE tevo_performer_id = p_performer_id LIMIT 1)
            ORDER BY published_at DESC NULLS LAST LIMIT 5) recent),
    'open_injuries_14d', (
      SELECT count(*) FROM espn_injuries_snapshots i
      WHERE i.espn_team_id = (SELECT espn_team_id FROM team_xref WHERE tevo_performer_id = p_performer_id LIMIT 1)
        AND i.captured_at >= now() - interval '14 days'),
    'roster_size', (
      SELECT count(*)::int FROM espn_athletes a
      WHERE a.espn_team_id = (SELECT espn_team_id FROM team_xref WHERE tevo_performer_id = p_performer_id LIMIT 1)
        AND a.status = 'active')
  );
END
$fn$;

COMMENT ON FUNCTION get_team_context IS
  'Full team context: standings + playoff series + wiki summary + active rivalries + marquee-game flag for next opponent + recent news + injury count + roster. Single shared helper for both broker terminal and retail chatbot.';
