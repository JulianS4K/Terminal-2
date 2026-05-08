-- Cowork migration. Captured into git by code (auditor) on 2026-05-07.
-- Originally applied to prod 2026-05-07 21:14 UTC.
--
-- Creates espn_athletes (full roster) + espn_athlete_team_history (segments
-- with trade/release detection). Plus get_team_context, get_player_info,
-- get_team_roster, get_recent_team_changes RPCs that the chat fn + broker
-- terminal call. RPCs reference team_xref — see compat-view migration for
-- compatibility after team_xref was dropped.

CREATE TABLE IF NOT EXISTS espn_athletes (
  espn_athlete_id   text PRIMARY KEY,
  full_name         text,
  display_name      text,
  short_name        text,
  jersey            text,
  position          text,
  position_abbr     text,
  height_inches     integer,
  weight_lbs        integer,
  birth_date        date,
  age               integer,
  espn_team_id      text,
  espn_league       text,
  status            text,
  experience_years  integer,
  headshot_url      text,
  meta              jsonb DEFAULT '{}'::jsonb,
  first_seen_at     timestamptz NOT NULL DEFAULT now(),
  last_seen_at      timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS espn_athletes_team_idx   ON espn_athletes (espn_team_id);
CREATE INDEX IF NOT EXISTS espn_athletes_league_idx ON espn_athletes (espn_league);
CREATE INDEX IF NOT EXISTS espn_athletes_name_idx   ON espn_athletes (lower(full_name));
CREATE INDEX IF NOT EXISTS espn_athletes_disp_name_idx ON espn_athletes (lower(display_name));

CREATE TABLE IF NOT EXISTS espn_athlete_team_history (
  id                bigserial PRIMARY KEY,
  espn_athlete_id   text NOT NULL,
  espn_team_id      text,
  espn_league       text,
  start_date        date NOT NULL DEFAULT current_date,
  end_date          date,
  transaction_type  text,
  prior_team_id     text,
  notes             text,
  detected_at       timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS espn_athlete_team_history_athlete_idx ON espn_athlete_team_history (espn_athlete_id, detected_at DESC);
CREATE INDEX IF NOT EXISTS espn_athlete_team_history_team_idx    ON espn_athlete_team_history (espn_team_id);
CREATE INDEX IF NOT EXISTS espn_athlete_team_history_open_idx    ON espn_athlete_team_history (espn_athlete_id) WHERE end_date IS NULL;

CREATE OR REPLACE FUNCTION get_team_context(p_performer_id bigint)
RETURNS jsonb
LANGUAGE sql STABLE AS $fn$
  WITH x AS (
    SELECT espn_team_id, espn_league, espn_slug, tevo_name, espn_display_name, espn_abbr
    FROM team_xref WHERE tevo_performer_id = p_performer_id LIMIT 1
  ),
  latest_snap AS (
    SELECT s.* FROM espn_team_snapshots s, x
    WHERE s.espn_team_id = x.espn_team_id
    ORDER BY s.captured_at DESC LIMIT 1
  ),
  inj_open AS (
    SELECT count(*) AS n FROM espn_injuries_snapshots i, x
    WHERE i.espn_team_id = x.espn_team_id
      AND i.captured_at >= now() - interval '14 days'
  ),
  recent_news AS (
    SELECT jsonb_agg(jsonb_build_object('headline', headline, 'published_at', published_at, 'url', url)) AS items
    FROM (
      SELECT n.headline, n.published_at, n.url FROM espn_news n, x
      WHERE n.espn_team_id = x.espn_team_id ORDER BY n.published_at DESC NULLS LAST LIMIT 5
    ) recent
  ),
  roster_size AS (
    SELECT count(*)::int AS n FROM espn_athletes a, x
    WHERE a.espn_team_id = x.espn_team_id
  )
  SELECT jsonb_build_object(
    'performer_id', p_performer_id,
    'team', (SELECT jsonb_build_object('espn_team_id', espn_team_id, 'espn_league', espn_league, 'name', COALESCE(espn_display_name, tevo_name), 'abbr', espn_abbr) FROM x),
    'standing', (SELECT jsonb_build_object('record', record_summary, 'win_pct', win_pct, 'games_back', games_back, 'streak', streak, 'standing_summary', standing_summary, 'playoff_seed', playoff_seed, 'as_of', captured_at) FROM latest_snap),
    'recent_news', (SELECT items FROM recent_news),
    'open_injuries_14d', (SELECT n FROM inj_open),
    'roster_size', (SELECT n FROM roster_size)
  );
$fn$;

CREATE OR REPLACE FUNCTION get_player_info(p_query text, p_limit int DEFAULT 5)
RETURNS jsonb
LANGUAGE sql STABLE AS $fn$
  SELECT COALESCE(jsonb_agg(to_jsonb(r) ORDER BY r.match_strength DESC), '[]'::jsonb)
  FROM (
    SELECT
      a.espn_athlete_id,
      a.full_name,
      a.display_name,
      a.position_abbr,
      a.jersey,
      a.status,
      a.espn_league,
      a.espn_team_id,
      x.espn_display_name AS team_name,
      x.tevo_performer_id AS performer_id,
      (SELECT jsonb_build_object('status', i.status, 'injury_type', i.injury_type, 'short_comment', i.short_comment, 'captured_at', i.captured_at)
         FROM espn_injuries_snapshots i WHERE i.athlete_id = a.espn_athlete_id ORDER BY i.captured_at DESC LIMIT 1) AS latest_injury,
      (SELECT jsonb_agg(jsonb_build_object(
                'team_id', h.espn_team_id, 'transaction', h.transaction_type,
                'prior_team_id', h.prior_team_id, 'detected_at', h.detected_at, 'notes', h.notes))
         FROM (SELECT * FROM espn_athlete_team_history WHERE espn_athlete_id = a.espn_athlete_id ORDER BY detected_at DESC LIMIT 3) h) AS recent_history,
      CASE
        WHEN lower(a.full_name) = lower(p_query) THEN 100
        WHEN lower(a.display_name) = lower(p_query) THEN 95
        WHEN lower(a.full_name) LIKE lower(p_query) || '%' THEN 80
        WHEN lower(a.display_name) LIKE lower(p_query) || '%' THEN 75
        WHEN lower(a.full_name) LIKE '%' || lower(p_query) || '%' THEN 60
        WHEN lower(a.display_name) LIKE '%' || lower(p_query) || '%' THEN 55
        ELSE 0
      END AS match_strength
    FROM espn_athletes a
    LEFT JOIN team_xref x ON x.espn_team_id = a.espn_team_id
    WHERE lower(a.full_name) LIKE '%' || lower(p_query) || '%'
       OR lower(a.display_name) LIKE '%' || lower(p_query) || '%'
       OR lower(COALESCE(a.short_name, '')) LIKE '%' || lower(p_query) || '%'
    ORDER BY match_strength DESC, a.last_seen_at DESC
    LIMIT p_limit
  ) r;
$fn$;

CREATE OR REPLACE FUNCTION get_team_roster(p_performer_id bigint)
RETURNS jsonb
LANGUAGE sql STABLE AS $fn$
  SELECT COALESCE(jsonb_agg(to_jsonb(r) ORDER BY r.position_abbr, r.full_name), '[]'::jsonb)
  FROM (
    SELECT
      a.espn_athlete_id, a.full_name, a.display_name,
      a.position_abbr, a.jersey, a.status, a.height_inches, a.weight_lbs, a.age,
      a.espn_team_id, a.espn_league
    FROM team_xref x
    JOIN espn_athletes a ON a.espn_team_id = x.espn_team_id
    WHERE x.tevo_performer_id = p_performer_id
  ) r;
$fn$;

CREATE OR REPLACE FUNCTION get_recent_team_changes(p_since timestamptz DEFAULT now() - interval '30 days', p_limit int DEFAULT 100)
RETURNS jsonb
LANGUAGE sql STABLE AS $fn$
  SELECT COALESCE(jsonb_agg(to_jsonb(r) ORDER BY r.detected_at DESC), '[]'::jsonb)
  FROM (
    SELECT h.detected_at, h.transaction_type, h.notes,
           a.full_name AS athlete, a.position_abbr,
           h.espn_athlete_id, h.espn_team_id AS new_team, h.prior_team_id AS old_team,
           xn.espn_display_name AS new_team_name, xo.espn_display_name AS old_team_name,
           h.espn_league
    FROM espn_athlete_team_history h
    LEFT JOIN espn_athletes a ON a.espn_athlete_id = h.espn_athlete_id
    LEFT JOIN team_xref xn ON xn.espn_team_id = h.espn_team_id
    LEFT JOIN team_xref xo ON xo.espn_team_id = h.prior_team_id
    WHERE h.detected_at >= p_since
      AND h.transaction_type <> 'initial_seen'
    ORDER BY h.detected_at DESC
    LIMIT p_limit
  ) r;
$fn$;
