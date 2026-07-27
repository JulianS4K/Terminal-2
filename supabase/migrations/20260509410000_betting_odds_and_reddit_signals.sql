-- ============================================================================
-- Migration 20260509410000 — Phase 1 final: betting odds + social signals
--
-- Two product directives:
--   "need a way to get x.com twitter feed for free"
--   "and betting odds for performers for free"
--
-- HONEST READ ON X/TWITTER FREE ACCESS:
--   Post-Musk, X's API has no free tier for READING tweets — the free tier
--   is write-only (can post, can't read). Public Nitter instances have
--   been rate-limited or shut down by X. Web scraping is captcha-blocked
--   and against ToS. There is no clean free path to X/Twitter content.
--
--   Substitute for sports performer sentiment: REDDIT (via RSS).
--   - Each major team has an active subreddit (r/nyknicks, r/lakers,
--     r/yankees, r/dallascowboys, r/leafs, etc.).
--   - Reddit's JSON API now returns 403+HTML challenge to non-browser
--     User-Agents (verified live 2026-05-09). The /.rss endpoint
--     returns 200 + Atom XML to the same UA. Workable substitute,
--     trades score/num_comments visibility for unauth-friendly access.
--   - Atom feed gives us title + body (HTML) + author + permalink +
--     timestamp. That's enough for "did breaking news drop?" /
--     "is this team being talked about?" signals.
--   - Score / comment-count would require Reddit OAuth2 — kanban'd
--     for Phase 2.
--
--   Future Phase 2: Google News RSS, Mastodon public, Bluesky AT — all free.
--
-- BETTING ODDS:
--   Already pulling. ESPN scoreboard returns spread / over_under / home_ml /
--   away_ml / home_win_prob (DraftKings-sourced) embedded in
--   espn_event_snapshots. 598 of 669 snapshots have odds across 23 events.
--   This migration surfaces them as canonical views + adds a line-movement
--   alert rule. No new pulls needed for sports.
--
--   Coverage gap: concerts have no odds (not bettable). For non-sports,
--   the "performer momentum" signal lives in Reddit + Wikipedia + price
--   action.
-- ============================================================================

-- ============================================================================
-- (A) BETTING ODDS — surface what ESPN already gives us
-- ============================================================================

CREATE OR REPLACE VIEW v_event_betting_odds_latest AS
SELECT
  x.tevo_event_id,
  ee.espn_event_id,
  ee.captured_at,
  ee.state,
  ee.status_short,
  ee.home_team_id,
  ee.away_team_id,
  ee.spread,
  ee.over_under,
  ee.home_ml,
  ee.away_ml,
  ee.home_win_prob,
  CASE WHEN ee.home_win_prob IS NOT NULL
    THEN round((1 - ee.home_win_prob)::numeric, 3)
    END AS away_win_prob,
  ee.odds_provider
FROM event_xref x
JOIN LATERAL (
  SELECT * FROM espn_event_snapshots ees
  WHERE ees.espn_event_id = x.espn_event_id
    AND (ees.spread IS NOT NULL OR ees.home_ml IS NOT NULL)
  ORDER BY ees.captured_at DESC
  LIMIT 1
) ee ON true;

COMMENT ON VIEW v_event_betting_odds_latest IS
  'Latest betting odds per TEvo event from ESPN scoreboard (DraftKings-sourced). '
  'Free path: ESPN exposes odds in their public scoreboard JSON. Sports only — '
  'concerts have no odds. Use v_event_line_movement for deltas.';

CREATE OR REPLACE VIEW v_event_line_movement AS
WITH latest AS (
  SELECT DISTINCT ON (x.tevo_event_id)
    x.tevo_event_id, x.espn_event_id, ee.captured_at AS now_at,
    ee.spread, ee.over_under, ee.home_ml, ee.away_ml, ee.home_win_prob
  FROM event_xref x
  JOIN espn_event_snapshots ee ON ee.espn_event_id = x.espn_event_id
  WHERE ee.spread IS NOT NULL OR ee.home_ml IS NOT NULL
  ORDER BY x.tevo_event_id, ee.captured_at DESC
)
SELECT
  l.tevo_event_id, l.espn_event_id, l.now_at,
  l.spread        AS spread_now,
  l.over_under    AS ou_now,
  l.home_ml       AS home_ml_now,
  l.away_ml       AS away_ml_now,
  l.home_win_prob AS home_winp_now,
  -- 1h ago
  (SELECT spread FROM espn_event_snapshots ee
    WHERE ee.espn_event_id = l.espn_event_id AND ee.captured_at <= l.now_at - interval '1 hour'
    ORDER BY ee.captured_at DESC LIMIT 1) AS spread_1h_ago,
  (SELECT home_ml FROM espn_event_snapshots ee
    WHERE ee.espn_event_id = l.espn_event_id AND ee.captured_at <= l.now_at - interval '1 hour'
    ORDER BY ee.captured_at DESC LIMIT 1) AS home_ml_1h_ago,
  (SELECT home_win_prob FROM espn_event_snapshots ee
    WHERE ee.espn_event_id = l.espn_event_id AND ee.captured_at <= l.now_at - interval '1 hour'
    ORDER BY ee.captured_at DESC LIMIT 1) AS home_winp_1h_ago,
  -- 24h ago
  (SELECT spread FROM espn_event_snapshots ee
    WHERE ee.espn_event_id = l.espn_event_id AND ee.captured_at <= l.now_at - interval '24 hours'
    ORDER BY ee.captured_at DESC LIMIT 1) AS spread_24h_ago,
  (SELECT home_ml FROM espn_event_snapshots ee
    WHERE ee.espn_event_id = l.espn_event_id AND ee.captured_at <= l.now_at - interval '24 hours'
    ORDER BY ee.captured_at DESC LIMIT 1) AS home_ml_24h_ago,
  (SELECT home_win_prob FROM espn_event_snapshots ee
    WHERE ee.espn_event_id = l.espn_event_id AND ee.captured_at <= l.now_at - interval '24 hours'
    ORDER BY ee.captured_at DESC LIMIT 1) AS home_winp_24h_ago
FROM latest l;

COMMENT ON VIEW v_event_line_movement IS
  'Per-event spread / ML / win-prob now vs 1h ago vs 24h ago. Drives the '
  'line_movement alert rule. NULL fields mean we did not have a snapshot '
  'in that window.';

-- Add line-movement alert rule to compute_alerts_tick
CREATE OR REPLACE FUNCTION compute_alerts_tick()
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE v_fired jsonb := '{}'::jsonb; v_n int;
BEGIN
  -- Existing rules (1-6) — unchanged from mig 390000
  INSERT INTO event_alerts(rule_key, tevo_event_id, severity, message, payload)
  SELECT 'tevo_getin_drop_1h', vw.tevo_event_id, 'warn',
    format('Get-in dropped %s%% in last hour ($%s -> $%s)',
      vw.tevo_getin_d1h_pct, (vw.tevo_getin_now - vw.tevo_getin_d1h)::int, vw.tevo_getin_now::int),
    jsonb_build_object('getin_now', vw.tevo_getin_now, 'd1h', vw.tevo_getin_d1h,
      'd1h_pct', vw.tevo_getin_d1h_pct, 'tevo_now_at', vw.tevo_now_at)
  FROM v_event_velocity_windows vw
  WHERE vw.tevo_getin_d1h_pct IS NOT NULL AND vw.tevo_getin_d1h_pct <= -10
    AND vw.tevo_getin_now > 0
    AND _alert_dedupe_ok('tevo_getin_drop_1h', vw.tevo_event_id);
  GET DIAGNOSTICS v_n = ROW_COUNT;
  v_fired := v_fired || jsonb_build_object('tevo_getin_drop_1h', v_n);

  INSERT INTO event_alerts(rule_key, tevo_event_id, severity, message, payload)
  SELECT 'tevo_getin_surge_1h', vw.tevo_event_id, 'info',
    format('Get-in surged %s%% in last hour ($%s -> $%s)',
      vw.tevo_getin_d1h_pct, (vw.tevo_getin_now - vw.tevo_getin_d1h)::int, vw.tevo_getin_now::int),
    jsonb_build_object('getin_now', vw.tevo_getin_now, 'd1h', vw.tevo_getin_d1h,
      'd1h_pct', vw.tevo_getin_d1h_pct, 'tevo_now_at', vw.tevo_now_at)
  FROM v_event_velocity_windows vw
  WHERE vw.tevo_getin_d1h_pct IS NOT NULL AND vw.tevo_getin_d1h_pct >= 10
    AND vw.tevo_getin_now > 0
    AND _alert_dedupe_ok('tevo_getin_surge_1h', vw.tevo_event_id);
  GET DIAGNOSTICS v_n = ROW_COUNT;
  v_fired := v_fired || jsonb_build_object('tevo_getin_surge_1h', v_n);

  INSERT INTO event_alerts(rule_key, tevo_event_id, severity, message, payload)
  SELECT 'tevo_inventory_low_48h', e.id, 'warn',
    format('Inventory low: %s tickets, event in %s hours',
      lem.tickets_count, round(extract(epoch from (e.occurs_at_local::timestamptz - now()))/3600)),
    jsonb_build_object('tickets', lem.tickets_count, 'occurs_at', e.occurs_at_local)
  FROM events e
  JOIN latest_event_metrics lem ON lem.event_id = e.id
  WHERE e.occurs_at_local::timestamptz BETWEEN now() AND now() + interval '48 hours'
    AND lem.tickets_count < 25 AND lem.tickets_count > 0
    AND _alert_dedupe_ok('tevo_inventory_low_48h', e.id);
  GET DIAGNOSTICS v_n = ROW_COUNT;
  v_fired := v_fired || jsonb_build_object('tevo_inventory_low_48h', v_n);

  INSERT INTO event_alerts(rule_key, tevo_event_id, severity, message, payload)
  SELECT 'arbitrage_opportunity', ao.tevo_event_id, 'info',
    format('Arb in section %s: SG vs TEvo gap %s%% (TEvo $%s, SG $%s)',
      ao.section, ao.sg_vs_tevo_gap_pct, ao.tevo_retail_median::int, ao.sg_retail_median::int),
    jsonb_build_object('section', ao.section, 'gap_pct', ao.sg_vs_tevo_gap_pct,
      'tevo_median', ao.tevo_retail_median, 'sg_median', ao.sg_retail_median)
  FROM v_arbitrage_opportunities ao
  WHERE abs(ao.sg_vs_tevo_gap_pct) >= 15
    AND _alert_dedupe_ok('arbitrage_opportunity', ao.tevo_event_id);
  GET DIAGNOSTICS v_n = ROW_COUNT;
  v_fired := v_fired || jsonb_build_object('arbitrage_opportunity', v_n);

  INSERT INTO event_alerts(rule_key, tevo_event_id, severity, message, payload)
  SELECT 'espn_status_change', x.tevo_event_id, 'critical',
    format('ESPN status: %s', ee.status_short),
    jsonb_build_object('espn_status', ee.status_short, 'state', ee.state, 'captured_at', ee.captured_at)
  FROM event_xref x
  JOIN LATERAL (
    SELECT * FROM espn_event_snapshots ee
    WHERE ee.espn_event_id = x.espn_event_id ORDER BY captured_at DESC LIMIT 1
  ) ee ON true
  WHERE lower(ee.status_short) IN ('postponed','delayed','canceled','cancelled','suspended')
    AND _alert_dedupe_ok('espn_status_change', x.tevo_event_id);
  GET DIAGNOSTICS v_n = ROW_COUNT;
  v_fired := v_fired || jsonb_build_object('espn_status_change', v_n);

  INSERT INTO event_alerts(rule_key, tevo_event_id, severity, message, payload)
  SELECT 'competing_event_added', ecs.tevo_event_id, 'info',
    format('%s competing event(s) within +/-24h x 20mi', ecs.competitors_count),
    jsonb_build_object('competitors', ecs.competitors)
  FROM event_competitors_snapshot ecs
  WHERE ecs.competitors_count > 0
    AND _alert_dedupe_ok('competing_event_added', ecs.tevo_event_id, interval '24 hours');
  GET DIAGNOSTICS v_n = ROW_COUNT;
  v_fired := v_fired || jsonb_build_object('competing_event_added', v_n);

  -- NEW Rule 7: significant line movement on ML or win-prob (>20% relative move in 24h)
  INSERT INTO event_alerts(rule_key, tevo_event_id, severity, message, payload)
  SELECT 'line_movement_24h', lm.tevo_event_id, 'info',
    format('Line moved: home win-prob %s -> %s (%s pts)',
      round(lm.home_winp_24h_ago::numeric, 3),
      round(lm.home_winp_now::numeric, 3),
      round((lm.home_winp_now - lm.home_winp_24h_ago)::numeric, 3)),
    jsonb_build_object(
      'home_winp_now', lm.home_winp_now,
      'home_winp_24h_ago', lm.home_winp_24h_ago,
      'spread_now', lm.spread_now,
      'spread_24h_ago', lm.spread_24h_ago)
  FROM v_event_line_movement lm
  WHERE lm.home_winp_24h_ago IS NOT NULL
    AND lm.home_winp_now IS NOT NULL
    AND abs(lm.home_winp_now - lm.home_winp_24h_ago) >= 0.10
    AND _alert_dedupe_ok('line_movement_24h', lm.tevo_event_id);
  GET DIAGNOSTICS v_n = ROW_COUNT;
  v_fired := v_fired || jsonb_build_object('line_movement_24h', v_n);

  RETURN jsonb_build_object('fired_counts', v_fired, 'ran_at', now());
END; $$;

-- ============================================================================
-- (B) REDDIT SOCIAL SIGNALS — substitute for X/Twitter
-- ============================================================================

-- Performer -> subreddit mapping. One-to-many (a team can have multiple subs).
CREATE TABLE IF NOT EXISTS performer_subreddits (
  tevo_performer_id  bigint NOT NULL,
  subreddit          text   NOT NULL,
  weight             numeric(3,2) DEFAULT 1.0,  -- relative signal weight
  is_primary         boolean DEFAULT true,
  notes              text,
  PRIMARY KEY (tevo_performer_id, subreddit)
);

COMMENT ON TABLE performer_subreddits IS
  'Maps TEvo performers to their subreddit(s). Drives the Reddit social-signal '
  'pipeline. Seed with major team subs; add manually as new performers land. '
  'Multiple subs per performer allowed (e.g. /r/nyk + /r/nyknicks).';

-- Storage for fetched posts. Append-only; sweep policy in phase2 kanban.
CREATE TABLE IF NOT EXISTS reddit_posts (
  reddit_post_id     text PRIMARY KEY,         -- 't3_xxx' from API
  subreddit          text NOT NULL,
  tevo_performer_id  bigint,                   -- joined via performer_subreddits
  title              text,
  body               text,
  author             text,
  url                text,
  score              int,                      -- net upvotes
  num_comments       int,
  created_utc        timestamptz,
  pulled_at          timestamptz DEFAULT now(),
  raw                jsonb
);

CREATE INDEX IF NOT EXISTS reddit_posts_perf_recent_idx
  ON reddit_posts(tevo_performer_id, created_utc DESC);
CREATE INDEX IF NOT EXISTS reddit_posts_sub_idx
  ON reddit_posts(subreddit, pulled_at DESC);

COMMENT ON TABLE reddit_posts IS
  'Reddit /hot.json posts, keyed by reddit post id. Free public API, no auth, '
  'UA required. Game-day post volume + score is the signal — a +500-comment '
  'thread at tipoff is real-time demand pressure.';

-- Async pull pipeline (same pattern as wiki/weather/sg)
CREATE TABLE IF NOT EXISTS reddit_pending (
  id              bigserial PRIMARY KEY,
  subreddit       text NOT NULL,
  request_id      bigint NOT NULL,
  fired_at        timestamptz DEFAULT now(),
  resolved_at     timestamptz,
  rows_persisted  int
);

CREATE INDEX IF NOT EXISTS reddit_pending_unresolved_idx
  ON reddit_pending(fired_at) WHERE resolved_at IS NULL;

CREATE OR REPLACE FUNCTION reddit_queue(p_limit int DEFAULT 30)
RETURNS int LANGUAGE plpgsql AS $$
DECLARE
  r RECORD; v_req_id bigint; v_count int := 0;
BEGIN
  -- Iterate distinct subreddits we haven't pulled in the last 30min.
  -- Use old.reddit.com /.rss (Atom XML, returns 200 to UA-only auth).
  -- The www.reddit.com /.json endpoint returns 403+HTML to pg_net.
  FOR r IN
    SELECT DISTINCT ps.subreddit
    FROM performer_subreddits ps
    LEFT JOIN reddit_pending p ON p.subreddit = ps.subreddit
        AND p.fired_at > now() - interval '30 minutes'
    WHERE p.id IS NULL
    ORDER BY ps.subreddit
    LIMIT p_limit
  LOOP
    SELECT net.http_get(
      url := 'https://old.reddit.com/r/' || r.subreddit || '/.rss',
      headers := jsonb_build_object(
        'User-Agent', 'Terminal2-S4K-RSS/1.0',
        'Accept', 'application/rss+xml, application/xml'),
      timeout_milliseconds := 12000
    ) INTO v_req_id;

    INSERT INTO reddit_pending(subreddit, request_id, fired_at)
    VALUES (r.subreddit, v_req_id, now());
    v_count := v_count + 1;
    PERFORM pg_sleep(0.6);
  END LOOP;
  RETURN v_count;
END; $$;

CREATE OR REPLACE FUNCTION reddit_process()
RETURNS TABLE(processed int, posts_persisted int) LANGUAGE plpgsql AS $$
DECLARE
  r RECORD; v_xml text; v_count int;
  v_processed int := 0; v_persisted int := 0;
BEGIN
  FOR r IN
    SELECT p.id, p.subreddit, p.request_id, h.content, h.status_code
    FROM reddit_pending p
    JOIN net._http_response h ON h.id = p.request_id
    WHERE p.resolved_at IS NULL
  LOOP
    v_processed := v_processed + 1;
    IF r.status_code = 200 AND r.content IS NOT NULL THEN
      v_xml := r.content;
      -- Regex-extract Atom <entry> elements. Each entry contains:
      --   <id>t3_xxx</id>
      --   <title>...</title>
      --   <link href="..."/>
      --   <author><name>/u/x</name></author>
      --   <updated>2026-...</updated>
      --   <content type="html">...</content>  (HTML-escaped body)
      WITH entries AS (
        SELECT (regexp_matches(v_xml,
          '<entry>(.*?)</entry>',
          'g'))[1] AS entry
      ),
      parsed AS (
        SELECT
          (regexp_match(e.entry, '<id>(t3_[^<]+)</id>'))[1] AS reddit_post_id,
          (regexp_match(e.entry, '<title>([^<]*)</title>'))[1] AS title,
          (regexp_match(e.entry, '<link\s+href=\"([^\"]+)\"'))[1] AS url,
          (regexp_match(e.entry, '<author><name>([^<]+)</name>'))[1] AS author,
          (regexp_match(e.entry, '<updated>([^<]+)</updated>'))[1] AS updated_str,
          left(COALESCE((regexp_match(e.entry, '<content type="html">(.+?)</content>'))[1], ''), 400) AS body_first400
        FROM entries e
      ),
      ins AS (
        INSERT INTO reddit_posts (
          reddit_post_id, subreddit, tevo_performer_id,
          title, body, author, url, score, num_comments, created_utc, raw
        )
        SELECT
          p.reddit_post_id, r.subreddit,
          (SELECT min(tevo_performer_id) FROM performer_subreddits WHERE subreddit = r.subreddit),
          p.title, p.body_first400, p.author, p.url,
          NULL::int, NULL::int,                              -- not in RSS
          NULLIF(p.updated_str,'')::timestamptz,
          jsonb_build_object('source','rss','updated_str', p.updated_str)
        FROM parsed p
        WHERE p.reddit_post_id IS NOT NULL
        ON CONFLICT (reddit_post_id) DO UPDATE SET
          title       = EXCLUDED.title,
          body        = EXCLUDED.body,
          author      = EXCLUDED.author,
          url         = EXCLUDED.url,
          created_utc = EXCLUDED.created_utc,
          pulled_at   = now()
        RETURNING 1
      )
      SELECT count(*) INTO v_count FROM ins;
      v_persisted := v_persisted + v_count;
    END IF;

    UPDATE reddit_pending SET resolved_at = now(), rows_persisted = v_persisted
    WHERE id = r.id;
  END LOOP;
  RETURN QUERY SELECT v_processed, v_persisted;
END; $$;

CREATE OR REPLACE FUNCTION reddit_pending_sweep()
RETURNS int LANGUAGE plpgsql AS $$
DECLARE v_n int;
BEGIN
  DELETE FROM reddit_pending
  WHERE resolved_at IS NOT NULL AND resolved_at < now() - interval '24 hours';
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n;
END; $$;

-- Per-performer rollup view
CREATE OR REPLACE VIEW v_performer_reddit_pulse AS
SELECT
  ps.tevo_performer_id,
  count(DISTINCT rp.reddit_post_id) FILTER (WHERE rp.created_utc > now() - interval '24 hours') AS posts_24h,
  count(DISTINCT rp.reddit_post_id) FILTER (WHERE rp.created_utc > now() - interval '7 days')   AS posts_7d,
  sum(rp.score)        FILTER (WHERE rp.created_utc > now() - interval '24 hours') AS score_24h,
  sum(rp.num_comments) FILTER (WHERE rp.created_utc > now() - interval '24 hours') AS comments_24h,
  max(rp.created_utc)                                                              AS latest_post_at,
  string_agg(DISTINCT ps.subreddit, ',')                                           AS subreddits
FROM performer_subreddits ps
LEFT JOIN reddit_posts rp ON rp.subreddit = ps.subreddit
GROUP BY ps.tevo_performer_id;

COMMENT ON VIEW v_performer_reddit_pulse IS
  'Per-performer Reddit activity rollup. posts_24h + comments_24h spike on '
  'game days / breaking news. Substitute for X/Twitter sentiment since X has '
  'no free read API.';

-- ============================================================================
-- Seed the major-league team subreddits
-- ============================================================================

INSERT INTO performer_subreddits(tevo_performer_id, subreddit, is_primary, notes)
SELECT pm.performer_id, subs.sub, true, 'auto-seeded from team name'
FROM performer_metadata pm
CROSS JOIN LATERAL (VALUES
  -- NBA
  ('New York Knicks', 'NYKnicks'),
  ('Los Angeles Lakers', 'lakers'),
  ('Boston Celtics', 'bostonceltics'),
  ('Golden State Warriors', 'warriors'),
  ('Philadelphia 76ers', 'sixers'),
  ('Brooklyn Nets', 'GoNets'),
  ('Miami Heat', 'heat'),
  ('Chicago Bulls', 'chicagobulls'),
  ('Dallas Mavericks', 'Mavericks'),
  ('Denver Nuggets', 'denvernuggets'),
  ('Milwaukee Bucks', 'MkeBucks'),
  ('Phoenix Suns', 'suns'),
  ('Cleveland Cavaliers', 'clevelandcavs'),
  ('Atlanta Hawks', 'AtlantaHawks'),
  ('Oklahoma City Thunder', 'Thunder'),
  ('Minnesota Timberwolves', 'timberwolves'),
  ('Detroit Pistons', 'DetroitPistons'),
  -- NFL
  ('New York Giants', 'NYGiants'),
  ('New York Jets', 'nyjets'),
  ('Dallas Cowboys', 'cowboys'),
  ('New England Patriots', 'Patriots'),
  ('Green Bay Packers', 'GreenBayPackers'),
  ('Kansas City Chiefs', 'KansasCityChiefs'),
  ('Buffalo Bills', 'buffalobills'),
  ('Philadelphia Eagles', 'eagles'),
  ('Pittsburgh Steelers', 'steelers'),
  -- MLB
  ('New York Yankees', 'NYYankees'),
  ('New York Mets', 'NewYorkMets'),
  ('Boston Red Sox', 'redsox'),
  ('Los Angeles Dodgers', 'Dodgers'),
  ('Chicago Cubs', 'CHICubs'),
  ('Atlanta Braves', 'Braves'),
  ('Houston Astros', 'Astros'),
  ('Toronto Blue Jays', 'Torontobluejays'),
  ('Philadelphia Phillies', 'phillies'),
  -- NHL
  ('New York Rangers', 'rangers'),
  ('Toronto Maple Leafs', 'leafs'),
  ('Boston Bruins', 'BostonBruins'),
  ('Montreal Canadiens', 'Habs'),
  ('Buffalo Sabres', 'sabres'),
  ('Edmonton Oilers', 'EdmontonOilers')
) AS subs(team_name, sub)
WHERE pm.name = subs.team_name
ON CONFLICT (tevo_performer_id, subreddit) DO NOTHING;

-- ============================================================================
-- Crons
-- ============================================================================

SELECT cron.schedule(
  'reddit_queue_30min',
  '*/30 * * * *',
  $$ SELECT reddit_queue(30); $$
);

SELECT cron.schedule(
  'reddit_process_30min',
  '5-59/30 * * * *',
  $$ SELECT reddit_process(); $$
);

SELECT cron.schedule(
  'reddit_pending_sweep_daily',
  '40 3 * * *',
  $$ SELECT reddit_pending_sweep(); $$
);

-- ============================================================================
-- Extend get_event_context with odds + Reddit pulse
-- ============================================================================

CREATE OR REPLACE FUNCTION get_event_context(p_event_id bigint)
RETURNS jsonb LANGUAGE plpgsql STABLE AS $$
DECLARE
  v_event jsonb; v_pricing jsonb; v_espn jsonb; v_performer jsonb;
  v_weather jsonb; v_competitors jsonb; v_orders jsonb;
  v_odds jsonb; v_reddit jsonb;
BEGIN
  SELECT to_jsonb(e) - 'performer_ids' INTO v_event FROM events e WHERE id = p_event_id;
  IF v_event IS NULL THEN
    RETURN jsonb_build_object('error', 'event_not_found', 'tevo_event_id', p_event_id);
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

  -- NEW: betting odds (sports only)
  SELECT to_jsonb(bo) INTO v_odds FROM v_event_betting_odds_latest bo WHERE bo.tevo_event_id = p_event_id;

  -- NEW: Reddit pulse for primary performer
  SELECT to_jsonb(rp) INTO v_reddit
  FROM v_performer_reddit_pulse rp
  JOIN events e ON e.primary_performer_id = rp.tevo_performer_id
  WHERE e.id = p_event_id;

  RETURN jsonb_build_object(
    'tevo_event_id', p_event_id,
    'event', v_event,
    'pricing', COALESCE(v_pricing, '{}'::jsonb),
    'espn', COALESCE(v_espn, jsonb_build_object('present', false)),
    'odds', COALESCE(v_odds, jsonb_build_object('present', false)),
    'performer', COALESCE(v_performer, jsonb_build_object('present', false)),
    'weather', COALESCE(v_weather, jsonb_build_object('present', false)),
    'competitors', COALESCE(v_competitors, '[]'::jsonb),
    'reddit', COALESCE(v_reddit, jsonb_build_object('present', false)),
    'our_orders', COALESCE(v_orders, jsonb_build_object('present', false)),
    'generated_at', now()
  );
END; $$;
