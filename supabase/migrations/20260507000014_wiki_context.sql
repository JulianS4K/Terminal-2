-- Cowork migration. Captured into git by code (auditor) on 2026-05-07.
-- Originally applied to prod 2026-05-07 21:50 UTC.
--
-- Wikipedia performer context layer.
-- Both products consume via get_wiki_context() / get_team_context().
-- Rivalries enable "marquee game" screen recommendations (Lakers-Celtics,
-- Yankees-Red Sox, etc.) — bot can elevate these in retail UI when present.

CREATE TABLE IF NOT EXISTS wiki_summary (
  performer_id      bigint PRIMARY KEY,
  wiki_title        text NOT NULL,
  wiki_url          text,
  description       text,
  extract           text,
  thumbnail_url     text,
  founded_year      integer,
  championships     integer,
  meta              jsonb DEFAULT '{}'::jsonb,
  fetched_at        timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS wiki_summary_title_idx ON wiki_summary (wiki_title);

CREATE TABLE IF NOT EXISTS wiki_seasons (
  performer_id      bigint NOT NULL,
  season_label      text NOT NULL,
  wins              integer,
  losses            integer,
  ties              integer,
  finish            text,
  postseason_result text,
  head_coach        text,
  notable_players   text[],
  meta              jsonb DEFAULT '{}'::jsonb,
  fetched_at        timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (performer_id, season_label)
);

CREATE TABLE IF NOT EXISTS wiki_rivalries (
  id                bigserial PRIMARY KEY,
  league            text NOT NULL,
  performer_a_id    bigint NOT NULL,
  performer_b_id    bigint NOT NULL,
  rivalry_name      text NOT NULL,
  wiki_title        text,
  description       text,
  intensity         integer NOT NULL DEFAULT 5 CHECK (intensity BETWEEN 1 AND 10),
  all_time_summary  text,
  notable_moments   text[],
  fetched_at        timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS wiki_rivalries_a_idx ON wiki_rivalries (performer_a_id);
CREATE INDEX IF NOT EXISTS wiki_rivalries_b_idx ON wiki_rivalries (performer_b_id);
CREATE UNIQUE INDEX IF NOT EXISTS wiki_rivalries_pair_idx ON wiki_rivalries (LEAST(performer_a_id, performer_b_id), GREATEST(performer_a_id, performer_b_id));

CREATE OR REPLACE FUNCTION get_wiki_context(p_performer_id bigint)
RETURNS jsonb
LANGUAGE sql STABLE AS $fn$
  SELECT jsonb_build_object(
    'summary', (SELECT jsonb_build_object(
        'title', wiki_title, 'url', wiki_url,
        'description', description, 'extract', extract,
        'founded_year', founded_year, 'championships', championships,
        'thumbnail_url', thumbnail_url, 'fetched_at', fetched_at)
      FROM wiki_summary WHERE performer_id = p_performer_id),
    'recent_seasons', (SELECT COALESCE(jsonb_agg(to_jsonb(s.*) ORDER BY s.season_label DESC), '[]'::jsonb)
      FROM (SELECT * FROM wiki_seasons WHERE performer_id = p_performer_id
            ORDER BY season_label DESC LIMIT 5) s),
    'rivalries', (SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'rivalry_name', rivalry_name, 'opponent_id', other_performer_id,
        'intensity', intensity, 'all_time_summary', all_time_summary,
        'description', description, 'wiki_title', wiki_title) ORDER BY intensity DESC), '[]'::jsonb)
      FROM (
        SELECT r.rivalry_name, r.intensity, r.all_time_summary, r.description, r.wiki_title,
               CASE WHEN r.performer_a_id = p_performer_id THEN r.performer_b_id ELSE r.performer_a_id END AS other_performer_id
        FROM wiki_rivalries r
        WHERE r.performer_a_id = p_performer_id OR r.performer_b_id = p_performer_id
      ) sub)
  );
$fn$;

CREATE OR REPLACE FUNCTION is_rivalry_game(p_performer_a bigint, p_performer_b bigint)
RETURNS jsonb
LANGUAGE sql STABLE AS $fn$
  SELECT jsonb_build_object(
    'is_rivalry', count(*) > 0,
    'is_marquee', count(*) FILTER (WHERE intensity >= 7) > 0,
    'rivalry_name', max(rivalry_name) FILTER (WHERE intensity >= 5),
    'intensity', max(intensity),
    'all_time_summary', max(all_time_summary)
  )
  FROM wiki_rivalries
  WHERE (performer_a_id = p_performer_a AND performer_b_id = p_performer_b)
     OR (performer_a_id = p_performer_b AND performer_b_id = p_performer_a);
$fn$;

WITH rivalry_seed (league, team_a, team_b, name, intensity, summary) AS (
  VALUES
  ('NBA', 'Boston Celtics', 'Los Angeles Lakers', 'Celtics–Lakers rivalry', 10, 'Most-decorated rivalry in NBA history; 12 NBA Finals matchups'),
  ('NBA', 'New York Knicks', 'Boston Celtics', 'Celtics–Knicks rivalry', 7, 'Atlantic Division foes; Eastern Conference rivalry'),
  ('NBA', 'New York Knicks', 'Brooklyn Nets', 'Knicks–Nets rivalry', 6, 'NYC borough rivalry'),
  ('NBA', 'Los Angeles Lakers', 'LA Clippers', 'Lakers–Clippers rivalry', 6, 'Crosstown LA rivalry'),
  ('NBA', 'Boston Celtics', 'Philadelphia 76ers', 'Celtics–76ers rivalry', 7, 'Historic Eastern Conference rivalry; 21 playoff series'),
  ('NBA', 'Chicago Bulls', 'Detroit Pistons', 'Bulls–Pistons rivalry', 7, 'Bad Boys-era and Jordan-era rivalry'),
  ('NBA', 'Golden State Warriors', 'Cleveland Cavaliers', 'Cavaliers–Warriors rivalry', 7, 'Four-straight NBA Finals matchups 2015–18'),
  ('NBA', 'Miami Heat', 'Boston Celtics', 'Celtics–Heat rivalry', 7, 'Modern Eastern Conference rivalry'),
  ('NBA', 'New York Knicks', 'Indiana Pacers', 'Knicks–Pacers rivalry', 7, '90s Eastern Conference rivalry'),
  ('NBA', 'San Antonio Spurs', 'Dallas Mavericks', 'Mavericks–Spurs rivalry', 6, 'Texas rivalry'),
  ('NFL', 'Dallas Cowboys', 'Philadelphia Eagles', 'Cowboys–Eagles rivalry', 9, 'NFC East; one of NFL''s most-watched matchups'),
  ('NFL', 'Dallas Cowboys', 'Washington Commanders', 'Commanders–Cowboys rivalry', 8, 'Historic NFC East rivalry'),
  ('NFL', 'Dallas Cowboys', 'New York Giants', 'Cowboys–Giants rivalry', 7, 'NFC East rivalry'),
  ('NFL', 'New England Patriots', 'New York Jets', 'Jets–Patriots rivalry', 7, 'AFC East rivalry'),
  ('NFL', 'Pittsburgh Steelers', 'Baltimore Ravens', 'Ravens–Steelers rivalry', 9, 'AFC North physical rivalry'),
  ('NFL', 'Pittsburgh Steelers', 'Cleveland Browns', 'Browns–Steelers rivalry', 8, 'Oldest AFC North rivalry'),
  ('NFL', 'Green Bay Packers', 'Chicago Bears', 'Bears–Packers rivalry', 10, 'Oldest rivalry in NFL; 200+ meetings'),
  ('NFL', 'Green Bay Packers', 'Minnesota Vikings', 'Packers–Vikings rivalry', 7, 'NFC North rivalry'),
  ('NFL', 'Kansas City Chiefs', 'Las Vegas Raiders', 'Chiefs–Raiders rivalry', 7, 'AFC West rivalry'),
  ('NFL', 'San Francisco 49ers', 'Seattle Seahawks', '49ers–Seahawks rivalry', 7, 'NFC West rivalry'),
  ('MLB', 'New York Yankees', 'Boston Red Sox', 'Yankees–Red Sox rivalry', 10, 'Most storied rivalry in baseball; AL East'),
  ('MLB', 'Chicago Cubs', 'Chicago White Sox', 'Cubs–White Sox rivalry', 7, 'Crosstown Chicago rivalry'),
  ('MLB', 'Los Angeles Dodgers', 'San Francisco Giants', 'Dodgers–Giants rivalry', 9, 'Oldest rivalry in pro sports; 2,500+ games'),
  ('MLB', 'New York Yankees', 'New York Mets', 'Subway Series', 7, 'NYC interleague rivalry'),
  ('MLB', 'St. Louis Cardinals', 'Chicago Cubs', 'Cardinals–Cubs rivalry', 8, 'Oldest NL rivalry'),
  ('MLB', 'Los Angeles Dodgers', 'San Diego Padres', 'Dodgers–Padres rivalry', 6, 'NL West rivalry'),
  ('MLB', 'Houston Astros', 'Texas Rangers', 'Astros–Rangers rivalry', 6, 'Lone Star Series'),
  ('NHL', 'Boston Bruins', 'Montreal Canadiens', 'Canadiens–Bruins rivalry', 10, 'Oldest rivalry in NHL; 950+ meetings'),
  ('NHL', 'New York Rangers', 'New York Islanders', 'Rangers–Islanders rivalry', 8, 'NYC metro rivalry'),
  ('NHL', 'Detroit Red Wings', 'Chicago Blackhawks', 'Blackhawks–Red Wings rivalry', 7, 'Original Six rivalry'),
  ('NHL', 'Edmonton Oilers', 'Calgary Flames', 'Battle of Alberta', 8, 'Provincial rivalry'),
  ('NHL', 'Toronto Maple Leafs', 'Montreal Canadiens', 'Canadiens–Maple Leafs rivalry', 9, 'Original Six; only Canadian Original Six pair'),
  ('NHL', 'Pittsburgh Penguins', 'Philadelphia Flyers', 'Penguins–Flyers rivalry', 8, 'Pennsylvania rivalry'),
  ('NHL', 'New York Rangers', 'New Jersey Devils', 'Devils–Rangers rivalry', 7, 'NJ–NY metro rivalry')
)
INSERT INTO wiki_rivalries (league, performer_a_id, performer_b_id, rivalry_name, intensity, all_time_summary)
SELECT r.league,
       LEAST(pa.performer_id, pb.performer_id),
       GREATEST(pa.performer_id, pb.performer_id),
       r.name, r.intensity, r.summary
FROM rivalry_seed r
JOIN performer_home_venues pa ON pa.performer_name = r.team_a
JOIN performer_home_venues pb ON pb.performer_name = r.team_b
ON CONFLICT DO NOTHING;

COMMENT ON TABLE wiki_summary    IS 'Wikipedia article summary per performer (founded year, championships, extract). Fetched by wiki-collect.';
COMMENT ON TABLE wiki_seasons    IS 'Per-team-per-season records mined from Wikipedia season tables.';
COMMENT ON TABLE wiki_rivalries  IS 'Curated rivalry pairs with intensity score. Used by retail chat to elevate marquee matchups in screen recommendations.';
COMMENT ON FUNCTION get_wiki_context IS 'Wikipedia-derived context for a performer. Used by both products.';
COMMENT ON FUNCTION is_rivalry_game  IS 'Quick check whether a matchup is a rivalry. Returns is_rivalry/is_marquee/intensity.';
