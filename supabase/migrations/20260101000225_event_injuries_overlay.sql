-- ============================================================================
-- Migration 20260510000000 — #6 Event injuries overlay (ESPN-driven)
--
-- Per directive (2026-05-09): "skip [Reddit parser] for now... unless ESPN
-- itself provides that data".  ESPN does — we already pull
-- espn_injuries_snapshots (4,464 rows / 2,060 athletes / 130 teams across
-- MLB+NHL+NFL+NBA+WNBA, refreshed every few minutes).  This migration
-- wires that existing data to upcoming events.
--
-- ----------------------------------------------------------------------------
-- DATA-DICTIONARY MAP — ESPN field → existing schema usage
-- ----------------------------------------------------------------------------
--   espn_injuries_snapshots.espn_team_id  ──┐
--                                            ├─►  (matched via)
--   espn_event_snapshots.home_team_id /     │
--                       .away_team_id       │
--                                            │
--   espn_event_snapshots.espn_event_id  ◄────┤
--                                            │
--   event_xref.espn_event_id            ◄────┤
--   event_xref.tevo_event_id            ◄────┤
--                                            │
--   events.id                            ◄───┘
--
-- Field-by-field — every ESPN injury column kept verbatim, plus one derived
-- impact_tier:
--
--   athlete_id, athlete_name, position, status, injury_type, short_comment,
--   long_comment, return_date, last_seen_at  ──► passthrough
--   espn_team_id                              ──► passthrough + side classifier
--   status                                     ──► derived impact_tier
--                                                  ('out_long' | 'out_short'
--                                                  | 'uncertain' | filtered)
--
-- ----------------------------------------------------------------------------
-- FILTERS APPLIED
-- ----------------------------------------------------------------------------
--   Exclude status ILIKE 'active'      — NFL has 788 healthy roster rows
--   Exclude status ILIKE 'bereavement' — non-injury absence
--   last_seen_at > now() - 14 days     — drop entries ESPN has dropped
--   events.event_type = 'game'         — only sports games (not concerts etc.)
--   events.occurs_at_local > now() - 1d — forward-looking only
--
-- ----------------------------------------------------------------------------
-- TWO BUGS FOUND DURING VERIFICATION (FIXED INLINE)
-- ----------------------------------------------------------------------------
--   1. Cross-league join: espn_team_id is NOT unique across leagues.
--      Diamondbacks=29 in MLB, but Memphis Grizzlies=29 in NBA. Fix: join
--      on (espn_team_id, espn_league) together.
--   2. Same-player multi-id: ESPN sometimes emits multiple athlete_ids
--      over time for one human (negative stub IDs like -191277, NULLs,
--      then canonical positive IDs like 989688). Fix: dedup by
--      (team, league, lower(trim(athlete_name))) keeping freshest +
--      preferring non-NULL/positive athlete_ids on ties.
--
-- ----------------------------------------------------------------------------
-- WHAT THIS MIGRATION DOES NOT TOUCH
-- ----------------------------------------------------------------------------
--   - espn_injuries_snapshots (existing pipeline owns it)
--   - event_xref / espn_event_snapshots (existing pipeline owns them)
--   - reddit_posts / performer_subreddits (Reddit parser was the original
--     plan; scrapped per directive — too noisy without an LLM bot)
-- ============================================================================

-- ============================================================================
-- (1) v_event_injuries — joined view per upcoming game
-- ============================================================================

CREATE OR REPLACE VIEW v_event_injuries AS
WITH latest_xref AS (
  SELECT DISTINCT ON (tevo_event_id)
    tevo_event_id, espn_event_id, espn_league
  FROM event_xref
  ORDER BY tevo_event_id, matched_at DESC
),
latest_event_teams AS (
  SELECT DISTINCT ON (es.espn_event_id)
    es.espn_event_id, es.espn_league,
    es.home_team_id, es.away_team_id
  FROM espn_event_snapshots es
  ORDER BY es.espn_event_id, es.captured_at DESC
),
-- Dedup by (team, league, athlete_name) — same player can carry multiple
-- athlete_ids over time (negative stub IDs, NULLs, then canonical IDs).
-- Pick the most recent snapshot per name; prefer rows with a non-NULL,
-- positive athlete_id when last_seen_at ties.
ranked_injuries AS (
  SELECT
    espn_team_id, espn_league,
    athlete_id, athlete_name, position,
    status, injury_type, short_comment, long_comment, return_date,
    captured_at, last_seen_at,
    row_number() OVER (
      PARTITION BY espn_team_id, espn_league, lower(trim(athlete_name))
      ORDER BY last_seen_at DESC,
               (athlete_id IS NOT NULL AND athlete_id !~ '^-') DESC,
               captured_at DESC
    ) AS rn
  FROM espn_injuries_snapshots
  WHERE status IS NOT NULL
    AND status NOT ILIKE 'active'
    AND status NOT ILIKE 'bereavement'
    AND athlete_name IS NOT NULL
    AND last_seen_at > now() - interval '14 days'
),
latest_per_athlete AS (
  SELECT * FROM ranked_injuries WHERE rn = 1
)
SELECT
  e.id          AS tevo_event_id,
  e.name        AS event_name,
  e.occurs_at_local,
  e.event_type,
  let.espn_league,
  let.home_team_id,
  let.away_team_id,
  inj.espn_team_id,
  CASE
    WHEN inj.espn_team_id = let.home_team_id THEN 'home'
    WHEN inj.espn_team_id = let.away_team_id THEN 'away'
  END AS side,
  inj.athlete_id,
  inj.athlete_name,
  inj.position,
  inj.status,
  inj.injury_type,
  inj.short_comment,
  inj.long_comment,
  inj.return_date,
  CASE
    WHEN inj.status ~* '(60-day|injured reserve|suspension)' THEN 'out_long'
    WHEN inj.status ~* '(10-day|15-day|7-day|^out$)'         THEN 'out_short'
    WHEN inj.status ~* '(day-to-day|questionable|doubtful)'  THEN 'uncertain'
    ELSE 'info'
  END AS impact_tier,
  inj.last_seen_at AS injury_last_seen_at
FROM events e
JOIN latest_xref         lx  ON lx.tevo_event_id = e.id
JOIN latest_event_teams  let ON let.espn_event_id = lx.espn_event_id
                            AND let.espn_league   = lx.espn_league
JOIN latest_per_athlete  inj ON inj.espn_league   = let.espn_league
                            AND inj.espn_team_id IN (let.home_team_id, let.away_team_id)
WHERE e.occurs_at_local::timestamptz > now() - interval '1 day'
  AND e.event_type = 'game';

COMMENT ON VIEW v_event_injuries IS
  'Per-event ESPN injury overlay. Joins events -> event_xref -> '
  'espn_event_snapshots -> espn_injuries_snapshots on (espn_team_id, '
  'espn_league) since espn_team_id is NOT unique across leagues. '
  'Dedups by (team, league, athlete_name) since ESPN sometimes emits '
  'multiple athlete_ids over time for the same player.';

-- ============================================================================
-- (2) get_event_context() gains 17th key: injuries
--     Returns {home: {tier→[athletes]}, away: {…}, total, as_of}
-- ============================================================================

CREATE OR REPLACE FUNCTION get_event_context(p_event_id bigint)
RETURNS jsonb LANGUAGE plpgsql STABLE AS $$
DECLARE
  v_event jsonb; v_pricing jsonb; v_espn jsonb; v_performer jsonb;
  v_weather jsonb; v_competitors jsonb; v_orders jsonb;
  v_odds jsonb; v_reddit jsonb; v_news jsonb; v_x jsonb; v_rivalry jsonb;
  v_calendar jsonb; v_alerts jsonb; v_injuries jsonb;
BEGIN
  SELECT to_jsonb(e) - 'performer_ids' INTO v_event FROM events e WHERE id = p_event_id;
  IF v_event IS NULL THEN
    RETURN jsonb_build_object('error','event_not_found','tevo_event_id',p_event_id);
  END IF;
  SELECT to_jsonb(ef) INTO v_pricing FROM v_event_full_v2 ef WHERE ef.tevo_event_id = p_event_id;
  SELECT jsonb_build_object(
    'espn_event_id', x.espn_event_id,
    'latest_state',  (SELECT state FROM espn_event_snapshots ee WHERE ee.espn_event_id = x.espn_event_id ORDER BY captured_at DESC LIMIT 1),
    'latest_status', (SELECT status_short FROM espn_event_snapshots ee WHERE ee.espn_event_id = x.espn_event_id ORDER BY captured_at DESC LIMIT 1),
    'latest_score',  (SELECT home_score::text || '-' || away_score::text FROM espn_event_snapshots ee WHERE ee.espn_event_id = x.espn_event_id ORDER BY captured_at DESC LIMIT 1)
  ) INTO v_espn FROM event_xref x WHERE x.tevo_event_id = p_event_id LIMIT 1;
  SELECT jsonb_build_object(
    'tevo_performer_id', pw.tevo_performer_id, 'wiki_title', pw.wiki_title,
    'wiki_url', pw.wiki_url, 'description', pw.description,
    'extract', pw.extract, 'image_url', pw.image_url
  ) INTO v_performer FROM performer_wikipedia pw
  JOIN events e ON e.primary_performer_id = pw.tevo_performer_id
  WHERE e.id = p_event_id AND NOT pw.is_rejected LIMIT 1;
  SELECT to_jsonb(w) INTO v_weather FROM v_event_weather_with_fallback w WHERE w.tevo_event_id = p_event_id;
  SELECT competitors INTO v_competitors FROM event_competitors_snapshot WHERE tevo_event_id = p_event_id;
  SELECT to_jsonb(o) INTO v_orders FROM our_orders_by_event o WHERE o.tevo_event_id = p_event_id;
  SELECT to_jsonb(bo) INTO v_odds FROM v_event_betting_odds_latest bo WHERE bo.tevo_event_id = p_event_id;
  SELECT to_jsonb(rp) INTO v_reddit FROM v_performer_reddit_pulse rp
    JOIN events e ON e.primary_performer_id = rp.tevo_performer_id WHERE e.id = p_event_id;

  SELECT jsonb_agg(jsonb_build_object(
           'title', vn.title, 'subreddit', vn.subreddit,
           'created_utc', vn.created_utc, 'url', vn.url,
           'matched', vn.keyword_match->'hits',
           'categories', vn.keyword_match->'categories'
         ) ORDER BY vn.created_utc DESC) INTO v_news
  FROM (SELECT * FROM v_reddit_important_recent ORDER BY created_utc DESC LIMIT 10) vn
  JOIN events e ON e.primary_performer_id = vn.tevo_performer_id
  WHERE e.id = p_event_id;

  SELECT jsonb_build_object(
           'team_known', count(*) FILTER (WHERE account_type = 'team_official'),
           'beat_reporters_known', count(*) FILTER (WHERE account_type = 'beat_reporter'),
           'league_known', count(*) FILTER (WHERE account_type = 'league_official'),
           'insiders_total', (SELECT count(*) FROM important_x_accounts WHERE account_type = 'insider')
         ) INTO v_x
  FROM important_x_accounts xa
  JOIN events e ON e.primary_performer_name = xa.team_name WHERE e.id = p_event_id;

  SELECT jsonb_build_object(
           'rivalry_name', re.rivalry_name, 'league', re.league,
           'is_branded', re.is_branded, 'rivalry_intensity', re.rivalry_intensity,
           'wikipedia_url', re.wikipedia_url, 'notes', re.notes
         ) INTO v_rivalry
  FROM v_rivalry_events re
  WHERE re.tevo_event_id = p_event_id LIMIT 1;

  SELECT jsonb_build_object(
           'country', cc.inferred_country, 'state', cc.inferred_state, 'city', cc.inferred_city,
           'is_holiday', cc.is_holiday, 'within_holiday_window', cc.within_holiday_window,
           'school_break_active', cc.school_break_active,
           'holidays_today', COALESCE(cc.holidays_today, '[]'::json),
           'holidays_nearby', COALESCE(cc.holidays_nearby, '[]'::json),
           'school_breaks_active', COALESCE(cc.school_breaks_active, '[]'::json)
         ) INTO v_calendar
  FROM v_event_calendar_context cc
  WHERE cc.tevo_event_id = p_event_id;

  SELECT jsonb_agg(jsonb_build_object(
           'alert_id', wa.alert_id, 'event', wa.event,
           'severity', wa.severity, 'urgency', wa.urgency, 'certainty', wa.certainty,
           'impact_tier', wa.impact_tier,
           'effective_at', wa.effective_at, 'expires_at', wa.expires_at,
           'headline', wa.headline, 'instruction', wa.instruction,
           'sender_name', wa.sender_name,
           'max_wind_gust_mph', wa.max_wind_gust_mph,
           'max_hail_size_in',  wa.max_hail_size_in)
         ORDER BY
           CASE wa.severity WHEN 'Extreme' THEN 0 WHEN 'Severe' THEN 1
             WHEN 'Moderate' THEN 2 WHEN 'Minor' THEN 3 ELSE 4 END) INTO v_alerts
  FROM v_event_active_weather_alerts wa
  WHERE wa.tevo_event_id = p_event_id;

  -- NEW: ESPN injuries split by side + impact tier
  WITH inj AS (
    SELECT * FROM v_event_injuries WHERE tevo_event_id = p_event_id
  ),
  by_side AS (
    SELECT
      side,
      jsonb_agg(jsonb_build_object(
        'athlete_id', athlete_id, 'name', athlete_name, 'position', position,
        'status', status, 'injury_type', injury_type,
        'return_date', return_date, 'short_comment', short_comment,
        'impact_tier', impact_tier, 'last_seen_at', injury_last_seen_at
      ) ORDER BY
        CASE impact_tier
          WHEN 'out_long' THEN 0 WHEN 'out_short' THEN 1
          WHEN 'uncertain' THEN 2 ELSE 3 END,
        athlete_name) AS rows,
      max(espn_team_id) AS team_espn_id,
      count(*) AS total_count
    FROM inj
    WHERE side IN ('home','away')
    GROUP BY side
  )
  SELECT jsonb_build_object(
    'home', COALESCE((SELECT jsonb_build_object(
                'team_espn_id', team_espn_id,
                'rows', rows,
                'total', total_count) FROM by_side WHERE side='home'),
            jsonb_build_object('total', 0, 'rows', '[]'::jsonb)),
    'away', COALESCE((SELECT jsonb_build_object(
                'team_espn_id', team_espn_id,
                'rows', rows,
                'total', total_count) FROM by_side WHERE side='away'),
            jsonb_build_object('total', 0, 'rows', '[]'::jsonb)),
    'total', (SELECT count(*) FROM inj),
    'as_of', (SELECT max(injury_last_seen_at) FROM inj)
  ) INTO v_injuries;

  RETURN jsonb_build_object(
    'tevo_event_id', p_event_id, 'event', v_event,
    'pricing', COALESCE(v_pricing, '{}'::jsonb),
    'espn', COALESCE(v_espn, jsonb_build_object('present', false)),
    'odds', COALESCE(v_odds, jsonb_build_object('present', false)),
    'performer', COALESCE(v_performer, jsonb_build_object('present', false)),
    'weather', COALESCE(v_weather, jsonb_build_object('present', false)),
    'weather_alerts', COALESCE(v_alerts, '[]'::jsonb),
    'injuries', COALESCE(v_injuries, jsonb_build_object('present', false)),
    'competitors', COALESCE(v_competitors, '[]'::jsonb),
    'reddit', COALESCE(v_reddit, jsonb_build_object('present', false)),
    'important_news', COALESCE(v_news, '[]'::jsonb),
    'x_accounts_known', COALESCE(v_x, jsonb_build_object('team_known', 0)),
    'rivalry', COALESCE(v_rivalry, jsonb_build_object('present', false)),
    'calendar', COALESCE(v_calendar, jsonb_build_object('present', false)),
    'our_orders', COALESCE(v_orders, jsonb_build_object('present', false)),
    'generated_at', now()
  );
END $$;

COMMENT ON FUNCTION get_event_context(bigint) IS
  'Single-row jsonb summary of every context dimension we have for one event. '
  'Now 17 keys including injuries (ESPN data, split by home/away + 4-tier '
  'impact_tier). See QUERY_CATALOG.md for a full schema breakdown.';
