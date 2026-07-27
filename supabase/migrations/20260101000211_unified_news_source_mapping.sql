-- ============================================================================
-- Migration 20260509430000 — Unified news-source mapping (X + Reddit + perfs)
--
-- Per directive: "map those twitter/reddit subs to performers, leagues,
-- categories, sports for easier data gathering and sorting."
--
-- Adds sortable fields to important_x_accounts and performer_subreddits,
-- fills the gaps the prior migration left (28 insiders had NULL league,
-- 44 subs had no per-row league marker), and exposes three unified views
-- for AI/RAG and future UI to query without knowing the schema:
--
--   v_x_accounts_unified       — handle + category + sport + league + perf
--   v_subreddits_unified       — performer-pinned + leaguewide subs
--   v_performer_news_sources   — every news source per performer (jsonb)
-- ============================================================================

-- (1) Add sortable columns
ALTER TABLE important_x_accounts
  ADD COLUMN IF NOT EXISTS sport text,
  ADD COLUMN IF NOT EXISTS category text;

ALTER TABLE performer_subreddits
  ADD COLUMN IF NOT EXISTS league text;

-- (2) Backfill performer_subreddits.league from auto-seed notes
UPDATE performer_subreddits
SET league = trim(replace(notes, 'auto-seeded ', ''))
WHERE notes LIKE 'auto-seeded %' AND league IS NULL;

-- (3) Map national insiders to their primary beat
UPDATE important_x_accounts SET league='NBA',     sport='NBA'
  WHERE handle IN ('@wojespn','@ShamsCharania','@WindhorstESPN','@TheSteinLine');
UPDATE important_x_accounts SET league='NFL',     sport='NFL'
  WHERE handle IN ('@AdamSchefter','@RapSheet','@TomPelissero','@MikeGarafolo','@FieldYates','@DMRussini');
UPDATE important_x_accounts SET league='MLB',     sport='MLB'
  WHERE handle IN ('@JeffPassan','@Ken_Rosenthal','@JonHeyman','@BNightengale','@Joelsherman1','@JesseRogersESPN');
UPDATE important_x_accounts SET league='NHL',     sport='NHL'
  WHERE handle IN ('@FriedgeHNIC','@PierreVLeBrun','@frank_seravalli','@KevinWeekes');
UPDATE important_x_accounts SET league='NCAA-FB', sport='NCAA-FB'
  WHERE handle IN ('@PeteThamel','@Brett_McMurphy','@Andy_Staples','@slmandel','@RossDellenger');
UPDATE important_x_accounts SET league='NCAA',    sport='NCAA'
  WHERE handle = '@NicoleAuerbach';
UPDATE important_x_accounts SET league='Soccer',  sport='Soccer'
  WHERE handle = '@FabrizioRomano';
UPDATE important_x_accounts SET league='UFC',     sport='MMA'
  WHERE handle = '@arielhelwani';

-- (4) Mirror sport from league for all sports rows where sport is still NULL
UPDATE important_x_accounts SET sport = league
WHERE sport IS NULL AND league IN (
  'NBA','NFL','MLB','NHL','MLS','WNBA','NCAA','NCAA-FB','F1','UFC','MMA','Soccer',
  'Premier League','La Liga','PGA Tour','LIV Golf','ATP Tour','WTA','NASCAR',
  'IndyCar','Formula 1','Olympics','FIFA','UEFA','WWE'
);

-- (5) Categorize: sports vs entertainment_broadway vs entertainment_concerts
UPDATE important_x_accounts SET category = CASE
  WHEN account_type IN ('insider','beat_reporter','team_official','league_official') THEN 'sports'
  WHEN account_type LIKE 'broadway_%' THEN 'entertainment_broadway'
  WHEN account_type LIKE 'concert_%'  THEN 'entertainment_concerts'
  ELSE 'other'
END
WHERE category IS NULL;

CREATE INDEX IF NOT EXISTS important_x_accounts_sport_idx    ON important_x_accounts(sport);
CREATE INDEX IF NOT EXISTS important_x_accounts_category_idx ON important_x_accounts(category);
CREATE INDEX IF NOT EXISTS performer_subreddits_league_idx   ON performer_subreddits(league);

-- ============================================================================
-- (6) Unified X-accounts view — sortable + linked to TEvo performer
-- ============================================================================

CREATE OR REPLACE VIEW v_x_accounts_unified AS
SELECT
  xa.handle, xa.name, xa.account_type, xa.category, xa.sport, xa.league,
  xa.team_name, xa.priority,
  pm.performer_id      AS tevo_performer_id,
  pm.top_category_name AS tevo_top_category,
  xa.added_at
FROM important_x_accounts xa
LEFT JOIN performer_metadata pm ON pm.name = xa.team_name;

COMMENT ON VIEW v_x_accounts_unified IS
  'X-account roster with category/sport/league/team_name + best-effort '
  'tevo_performer_id link. Filter by category (sports / entertainment_broadway '
  '/ entertainment_concerts) for top-level slicing; filter by sport (NBA/NFL/'
  'MLB/NHL/F1/etc.) for league-level.';

-- ============================================================================
-- (7) Unified Reddit subs — performer-pinned + leaguewide in one feed
-- ============================================================================

CREATE OR REPLACE VIEW v_subreddits_unified AS
SELECT
  ps.subreddit,
  'performer_pinned'::text AS scope,
  ps.tevo_performer_id,
  pm.name AS performer_name,
  ps.league,
  CASE
    WHEN ps.league IN ('NBA','NFL','MLB','NHL','MLS','WNBA','F1','NCAA','NCAA-FB') THEN 'sports'
    ELSE 'other'
  END AS category,
  ps.is_primary,
  ps.notes
FROM performer_subreddits ps
LEFT JOIN performer_metadata pm ON pm.performer_id = ps.tevo_performer_id
UNION ALL
SELECT
  gs.subreddit,
  'leaguewide'::text AS scope,
  NULL::bigint AS tevo_performer_id,
  NULL::text   AS performer_name,
  gs.league,
  CASE
    WHEN gs.league IN ('NBA','NFL','MLB','NHL','MLS','WNBA','F1','NCAA','NCAA-MBB','NCAA-FB') THEN 'sports'
    WHEN gs.league = 'Broadway' THEN 'entertainment_broadway'
    WHEN gs.league = 'Concerts' THEN 'entertainment_concerts'
    ELSE 'other'
  END AS category,
  true AS is_primary,
  gs.notes
FROM general_subreddits gs;

COMMENT ON VIEW v_subreddits_unified IS
  'Reddit subs combined: performer-pinned + leaguewide. scope tells you '
  'which. Filter by category=sports + league=NBA to get all NBA-related '
  'subs in one query.';

-- ============================================================================
-- (8) Per-performer news source roster — for AI/RAG prompt building
-- ============================================================================

CREATE OR REPLACE VIEW v_performer_news_sources AS
WITH x_handles AS (
  SELECT
    pm.performer_id AS tevo_performer_id,
    jsonb_agg(jsonb_build_object(
      'handle', xa.handle, 'name', xa.name, 'type', xa.account_type,
      'priority', xa.priority
    ) ORDER BY xa.priority DESC, xa.handle) AS x_accounts
  FROM performer_metadata pm
  JOIN important_x_accounts xa ON xa.team_name = pm.name
  GROUP BY pm.performer_id
),
subs AS (
  SELECT
    ps.tevo_performer_id,
    jsonb_agg(jsonb_build_object(
      'subreddit', ps.subreddit, 'league', ps.league, 'is_primary', ps.is_primary
    )) AS subreddits
  FROM performer_subreddits ps
  GROUP BY ps.tevo_performer_id
)
SELECT
  pm.performer_id   AS tevo_performer_id,
  pm.name           AS performer_name,
  pm.top_category_name AS tevo_top_category,
  pm.what_event_type,
  pm.genre,
  COALESCE(
    (SELECT max(ps.league) FROM performer_subreddits ps
       WHERE ps.tevo_performer_id = pm.performer_id),
    (SELECT max(xa.league) FROM important_x_accounts xa
       WHERE xa.team_name = pm.name)
  ) AS league,
  COALESCE(x.x_accounts, '[]'::jsonb)  AS x_accounts,
  COALESCE(s.subreddits, '[]'::jsonb)  AS subreddits
FROM performer_metadata pm
LEFT JOIN x_handles x ON x.tevo_performer_id = pm.performer_id
LEFT JOIN subs    s ON s.tevo_performer_id = pm.performer_id
WHERE x.tevo_performer_id IS NOT NULL OR s.tevo_performer_id IS NOT NULL;

COMMENT ON VIEW v_performer_news_sources IS
  'Per-performer roster of all known news sources (X handles + subreddits). '
  'AI/RAG consumer reads this to know "who covers this team" before '
  'composing a prompt. Sample call: SELECT * FROM v_performer_news_sources '
  'WHERE performer_name = ''New York Knicks'';';
